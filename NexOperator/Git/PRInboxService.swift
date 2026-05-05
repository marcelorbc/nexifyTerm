import Foundation

/// Aggregates pull requests across every project in the Cockpit workspace by
/// matching each project's `origin` remote URL with a stored `RemoteAccount`
/// and calling the corresponding `RemoteGitProvider`. Returns one row per
/// PR, regardless of which provider it came from.
@MainActor
final class PRInboxService {
    static let shared = PRInboxService()

    private let oauth = OAuthService.shared

    struct InboxRow: Identifiable, Equatable {
        var id: String { "\(repoPath)#\(pr.id)" }
        let repoPath: String
        let repoName: String
        let providerType: RemoteProviderType
        let pr: RemotePullRequest
    }

    struct LoadResult {
        let rows: [InboxRow]
        let perRepoErrors: [(repoName: String, message: String)]
        /// Repos that have a remote but no matching account were skipped —
        /// surfaced so the UI can suggest "conecte sua conta GitHub para ver
        /// PRs deste repo".
        let skippedNoAccount: [String]
        /// Repos with no recognizable remote (or `notARepo`).
        let skippedNoRemote: [String]
    }

    /// Loads PRs (default: open) from every workspace project that has a
    /// matched provider account. Concurrency capped to keep API rate-limits
    /// happy.
    func loadInbox(
        projects: [WorkspaceProject],
        state: PRStatus? = .open,
        maxConcurrent: Int = 4
    ) async -> LoadResult {
        var skippedNoRemote: [String] = []
        var skippedNoAccount: [String] = []
        var matched: [(project: WorkspaceProject, slug: String, account: RemoteAccount, provider: any RemoteGitProvider)] = []

        for project in projects {
            guard let remoteURL = await resolveOriginURL(at: project.path) else {
                skippedNoRemote.append(project.name)
                continue
            }
            guard let parsed = parseRemote(remoteURL) else {
                skippedNoRemote.append(project.name)
                continue
            }
            // Find the first account that matches provider + (azure: org).
            let candidates = oauth.accounts.filter { account in
                guard account.provider == parsed.provider else { return false }
                if parsed.provider == .azureDevOps {
                    return (account.organization ?? "").lowercased() == parsed.org.lowercased()
                }
                return true
            }
            guard let account = candidates.first,
                  let provider = oauth.provider(for: account)
            else {
                skippedNoAccount.append(project.name)
                continue
            }
            matched.append((project, parsed.slug, account, provider))
        }

        guard !matched.isEmpty else {
            return LoadResult(
                rows: [],
                perRepoErrors: [],
                skippedNoAccount: skippedNoAccount,
                skippedNoRemote: skippedNoRemote
            )
        }

        // Run in parallel with bounded concurrency.
        let limit = max(1, min(maxConcurrent, matched.count))
        var rows: [InboxRow] = []
        var errors: [(String, String)] = []

        await withTaskGroup(of: (Int, [InboxRow], (String, String)?).self) { group in
            var iterator = matched.enumerated().makeIterator()
            var inFlight = 0

            func enqueueNext() {
                guard let next = iterator.next() else { return }
                let m = next.element
                group.addTask {
                    do {
                        let prs = try await m.provider.pullRequests(repo: m.slug, state: state)
                        let mapped = prs.map { pr in
                            InboxRow(
                                repoPath: m.project.path,
                                repoName: m.project.name,
                                providerType: m.account.provider,
                                pr: pr
                            )
                        }
                        return (next.offset, mapped, nil)
                    } catch {
                        return (next.offset, [], (m.project.name, error.localizedDescription))
                    }
                }
                inFlight += 1
            }

            while inFlight < limit { enqueueNext() }
            while let done = await group.next() {
                inFlight -= 1
                rows.append(contentsOf: done.1)
                if let err = done.2 { errors.append(err) }
                enqueueNext()
            }
        }

        return LoadResult(
            rows: rows.sorted { $0.pr.createdAt > $1.pr.createdAt },
            perRepoErrors: errors,
            skippedNoAccount: skippedNoAccount,
            skippedNoRemote: skippedNoRemote
        )
    }

    // MARK: - Remote URL resolution

    private struct ParsedRemote {
        let provider: RemoteProviderType
        let slug: String
        /// Azure organization (empty for GitHub).
        let org: String
    }

    /// `git config --get remote.origin.url` for `path`. Returns nil on error.
    private func resolveOriginURL(at path: String) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = ["config", "--get", "remote.origin.url"]
                process.currentDirectoryURL = URL(fileURLWithPath: path)
                let stdout = Pipe()
                process.standardOutput = stdout
                process.standardError = Pipe()
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                let url = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: (url?.isEmpty ?? true) ? nil : url)
            }
        }
    }

    /// Parses common remote URL shapes into a provider-specific slug.
    /// Accepts:
    ///   - `https://github.com/owner/repo.git`
    ///   - `https://github.com/owner/repo`
    ///   - `git@github.com:owner/repo.git`
    ///   - `https://dev.azure.com/{org}/{project}/_git/{repo}`
    ///   - `git@ssh.dev.azure.com:v3/{org}/{project}/{repo}`
    private func parseRemote(_ url: String) -> ParsedRemote? {
        let normalized = url.hasSuffix(".git") ? String(url.dropLast(4)) : url

        // GitHub
        if let gh = parseGitHub(normalized) {
            return ParsedRemote(provider: .github, slug: gh, org: "")
        }

        // Azure DevOps
        if let azure = parseAzure(normalized) {
            return ParsedRemote(provider: .azureDevOps, slug: azure.slug, org: azure.org)
        }
        return nil
    }

    private func parseGitHub(_ url: String) -> String? {
        // https://github.com/owner/repo
        if let range = url.range(of: "github.com/") ?? url.range(of: "github.com:") {
            let slug = String(url[range.upperBound...])
            // strip query/fragment if any
            let clean = slug.split(separator: "?").first.map(String.init) ?? slug
            // expect "owner/repo"
            let parts = clean.split(separator: "/").map(String.init)
            if parts.count >= 2 {
                return "\(parts[0])/\(parts[1])"
            }
        }
        return nil
    }

    private func parseAzure(_ url: String) -> (slug: String, org: String)? {
        // https://dev.azure.com/{org}/{project}/_git/{repo}
        if let range = url.range(of: "dev.azure.com/") {
            let rest = String(url[range.upperBound...])
            let parts = rest.split(separator: "/").map(String.init)
            // [org, project, "_git", repo]
            if parts.count >= 4, parts[2] == "_git" {
                return (slug: "\(parts[1])/\(parts[3])", org: parts[0])
            }
        }
        // git@ssh.dev.azure.com:v3/{org}/{project}/{repo}
        if let range = url.range(of: "ssh.dev.azure.com:v3/") {
            let rest = String(url[range.upperBound...])
            let parts = rest.split(separator: "/").map(String.init)
            if parts.count >= 3 {
                return (slug: "\(parts[1])/\(parts[2])", org: parts[0])
            }
        }
        return nil
    }
}
