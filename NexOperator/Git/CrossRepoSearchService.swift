import Foundation

/// Searches commits across every project in the Cockpit workspace in
/// parallel. Three modes:
///
///  - `.message`   — `git log --all --grep=<query>`
///  - `.hash`      — `git log <hash>` (validates the hash exists in repo)
///  - `.author`    — `git log --all --author=<query>`
///
/// Bounded concurrency so we don't fork 25 git processes simultaneously.
struct CrossRepoSearchService: Sendable {
    static let shared = CrossRepoSearchService()

    enum Mode: String, CaseIterable, Identifiable {
        case message = "Mensagem"
        case hash    = "Hash"
        case author  = "Autor"
        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .message: return "text.magnifyingglass"
            case .hash:    return "number"
            case .author:  return "person.crop.circle"
            }
        }

        fileprivate var gitArgs: (String) -> [String] {
            switch self {
            case .message:
                return { q in
                    ["log", "--all", "-i", "--grep=\(q)",
                     "-n", "20",
                     "--format=%H|%s|%an|%aI"]
                }
            case .hash:
                return { q in
                    // Single commit lookup — the search query *is* the hash.
                    ["log", "-1", q, "--format=%H|%s|%an|%aI"]
                }
            case .author:
                return { q in
                    ["log", "--all", "-i", "--author=\(q)",
                     "-n", "20",
                     "--format=%H|%s|%an|%aI"]
                }
            }
        }
    }

    struct Hit: Identifiable, Equatable {
        var id: String { "\(repoPath)#\(hash)" }
        let repoPath: String
        let repoName: String
        let hash: String
        let shortHash: String
        let subject: String
        let authorName: String
        let date: Date
    }

    struct RepoResult: Identifiable, Equatable {
        var id: String { repoPath }
        let repoPath: String
        let repoName: String
        let hits: [Hit]
        let error: String?
    }

    /// Runs the search across all projects, returning per-repo results so the
    /// UI can group hits by repo.
    func search(
        mode: Mode,
        query: String,
        projects: [WorkspaceProject],
        maxConcurrent: Int = 6
    ) async -> [RepoResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !projects.isEmpty else { return [] }

        let limit = max(1, min(maxConcurrent, projects.count))

        return await withTaskGroup(of: (Int, RepoResult).self) { group in
            var iterator = projects.enumerated().makeIterator()
            var inFlight = 0

            while inFlight < limit, let next = iterator.next() {
                group.addTask {
                    let r = await searchOne(mode: mode, query: trimmed, project: next.element)
                    return (next.offset, r)
                }
                inFlight += 1
            }

            var collected: [(Int, RepoResult)] = []
            while let done = await group.next() {
                collected.append(done)
                if let next = iterator.next() {
                    group.addTask {
                        let r = await searchOne(mode: mode, query: trimmed, project: next.element)
                        return (next.offset, r)
                    }
                }
            }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func searchOne(
        mode: Mode,
        query: String,
        project: WorkspaceProject
    ) async -> RepoResult {
        let args = mode.gitArgs(query)
        do {
            let raw = try await runGit(args: args, cwd: project.path)
            let hits = parse(output: raw, project: project)
            return RepoResult(
                repoPath: project.path,
                repoName: project.name,
                hits: hits,
                error: nil
            )
        } catch let GitProcessError.failed(stderr) {
            // Hash mode often fails with "bad revision" when the hash isn't
            // in the repo — that's a NORMAL outcome, not an error to surface.
            if mode == .hash && stderr.contains("bad revision") {
                return RepoResult(repoPath: project.path, repoName: project.name, hits: [], error: nil)
            }
            // "not a git repository" can happen if the path moved on disk.
            if stderr.contains("not a git repository") {
                return RepoResult(
                    repoPath: project.path,
                    repoName: project.name,
                    hits: [],
                    error: "não é mais um repo"
                )
            }
            return RepoResult(
                repoPath: project.path,
                repoName: project.name,
                hits: [],
                error: stderr.components(separatedBy: "\n").first
            )
        } catch {
            return RepoResult(
                repoPath: project.path,
                repoName: project.name,
                hits: [],
                error: error.localizedDescription
            )
        }
    }

    private func parse(output: String, project: WorkspaceProject) -> [Hit] {
        guard !output.isEmpty else { return [] }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return output.components(separatedBy: "\n").compactMap { line in
            let parts = line.components(separatedBy: "|")
            guard parts.count >= 4 else { return nil }
            let hash = parts[0]
            let subject = parts[1]
            let author = parts[2]
            let dateStr = parts[3]
            return Hit(
                repoPath: project.path,
                repoName: project.name,
                hash: hash,
                shortHash: String(hash.prefix(7)),
                subject: subject,
                authorName: author,
                date: formatter.date(from: dateStr) ?? Date.distantPast
            )
        }
    }

    // MARK: - Process

    fileprivate enum GitProcessError: Error {
        case failed(String)
    }

    private func runGit(args: [String], cwd: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = args
                process.currentDirectoryURL = URL(fileURLWithPath: cwd)

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                process.waitUntilExit()

                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()

                if process.terminationStatus == 0 {
                    let s = String(data: outData, encoding: .utf8) ?? ""
                    continuation.resume(returning: s.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    let e = String(data: errData, encoding: .utf8) ?? "Unknown git error"
                    continuation.resume(throwing: GitProcessError.failed(
                        e.trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                }
            }
        }
    }
}
