import Foundation

struct DetectedGitAccount: Identifiable, Hashable {
    let id = UUID()
    let provider: RemoteProviderType
    let username: String
    let email: String?
    let token: String?
    let organization: String?
    let source: DetectionSource

    enum DetectionSource: String, Hashable {
        case gitConfig = "Git Config"
        case ghCLI = "GitHub CLI"
        case sshKey = "SSH Key"
        case localRepo = "Repositório Local"

        var icon: String {
            switch self {
            case .gitConfig: return "gearshape"
            case .ghCLI: return "terminal"
            case .sshKey: return "key"
            case .localRepo: return "folder"
            }
        }
    }

    var hasToken: Bool { token != nil && !(token?.isEmpty ?? true) }

    var displaySource: String { source.rawValue }
}

actor GitConfigScanner {
    static let shared = GitConfigScanner()

    func scanAll() async -> [DetectedGitAccount] {
        var accounts: [DetectedGitAccount] = []

        async let ghCLI = scanGitHubCLI()
        async let gitConfig = scanGlobalGitConfig()
        async let localRepos = scanLocalRepositories()

        let results = await (ghCLI, gitConfig, localRepos)

        accounts.append(contentsOf: results.0)
        accounts.append(contentsOf: results.1)
        accounts.append(contentsOf: results.2)

        return dedup(accounts)
    }

    // MARK: - GitHub CLI (~/.config/gh/hosts.yml)

    private func scanGitHubCLI() async -> [DetectedGitAccount] {
        let possiblePaths = [
            NSHomeDirectory() + "/.config/gh/hosts.yml",
            NSHomeDirectory() + "/.config/gh/hosts.yaml"
        ]

        for path in possiblePaths {
            guard FileManager.default.fileExists(atPath: path),
                  let content = try? String(contentsOfFile: path, encoding: .utf8) else {
                continue
            }
            return parseGHHostsYAML(content)
        }
        return []
    }

    private func parseGHHostsYAML(_ content: String) -> [DetectedGitAccount] {
        var accounts: [DetectedGitAccount] = []
        let lines = content.components(separatedBy: "\n")

        var currentHost: String?
        var currentUser: String?
        var currentToken: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if !line.hasPrefix(" ") && !line.hasPrefix("\t") && trimmed.hasSuffix(":") {
                if let host = currentHost, let user = currentUser {
                    let provider: RemoteProviderType = host.contains("github") ? .github : .azureDevOps
                    accounts.append(DetectedGitAccount(
                        provider: provider,
                        username: user,
                        email: nil,
                        token: currentToken,
                        organization: nil,
                        source: .ghCLI
                    ))
                }
                currentHost = trimmed.replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespaces)
                currentUser = nil
                currentToken = nil
            }

            if trimmed.hasPrefix("user:") {
                currentUser = trimmed.replacingOccurrences(of: "user:", with: "").trimmingCharacters(in: .whitespaces)
            }
            if trimmed.hasPrefix("oauth_token:") {
                currentToken = trimmed.replacingOccurrences(of: "oauth_token:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }

        if let host = currentHost, let user = currentUser {
            let provider: RemoteProviderType = host.contains("github") ? .github : .azureDevOps
            accounts.append(DetectedGitAccount(
                provider: provider,
                username: user,
                email: nil,
                token: currentToken,
                organization: nil,
                source: .ghCLI
            ))
        }

        return accounts
    }

    // MARK: - Global Git Config (~/.gitconfig)

    private func scanGlobalGitConfig() async -> [DetectedGitAccount] {
        let possiblePaths = [
            NSHomeDirectory() + "/.gitconfig",
            NSHomeDirectory() + "/.config/git/config"
        ]

        for path in possiblePaths {
            guard FileManager.default.fileExists(atPath: path),
                  let content = try? String(contentsOfFile: path, encoding: .utf8) else {
                continue
            }

            let parsed = parseGitConfig(content)
            guard let name = parsed["user.name"] ?? parsed["user.email"] else { continue }

            let email = parsed["user.email"]
            let provider = guessProvider(email: email, name: name)

            return [DetectedGitAccount(
                provider: provider,
                username: name,
                email: email,
                token: nil,
                organization: nil,
                source: .gitConfig
            )]
        }
        return []
    }

    private func parseGitConfig(_ content: String) -> [String: String] {
        var result = [String: String]()
        var currentSection = ""

        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                currentSection = trimmed
                    .replacingOccurrences(of: "[", with: "")
                    .replacingOccurrences(of: "]", with: "")
                    .trimmingCharacters(in: .whitespaces)
                continue
            }

            if trimmed.contains("=") {
                let parts = trimmed.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    let key = "\(currentSection).\(parts[0].trimmingCharacters(in: .whitespaces))"
                    let value = parts[1].trimmingCharacters(in: .whitespaces)
                    result[key] = value
                }
            }
        }
        return result
    }

    // MARK: - Local Repositories

    private func scanLocalRepositories() async -> [DetectedGitAccount] {
        let searchDirs = [
            NSHomeDirectory() + "/Developer",
            NSHomeDirectory() + "/Projects",
            NSHomeDirectory() + "/dev",
            NSHomeDirectory() + "/repos",
            NSHomeDirectory() + "/workspace",
            NSHomeDirectory() + "/Documents/GitHub"
        ]

        var remoteURLs: Set<String> = []
        let fm = FileManager.default

        for dir in searchDirs {
            guard fm.fileExists(atPath: dir) else { continue }

            guard let contents = try? fm.contentsOfDirectory(atPath: dir) else { continue }

            for item in contents.prefix(50) {
                let gitConfig = "\(dir)/\(item)/.git/config"
                guard fm.fileExists(atPath: gitConfig),
                      let config = try? String(contentsOfFile: gitConfig, encoding: .utf8) else {
                    continue
                }

                for url in extractRemoteURLs(from: config) {
                    remoteURLs.insert(url)
                }
            }
        }

        return accountsFromRemoteURLs(Array(remoteURLs))
    }

    private func extractRemoteURLs(from gitConfig: String) -> [String] {
        var urls: [String] = []
        let lines = gitConfig.components(separatedBy: "\n")
        var inRemote = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[remote ") { inRemote = true; continue }
            if trimmed.hasPrefix("[") { inRemote = false; continue }

            if inRemote && trimmed.hasPrefix("url =") {
                let url = trimmed.replacingOccurrences(of: "url =", with: "").trimmingCharacters(in: .whitespaces)
                urls.append(url)
            }
        }
        return urls
    }

    private func accountsFromRemoteURLs(_ urls: [String]) -> [DetectedGitAccount] {
        var seen: Set<String> = []
        var accounts: [DetectedGitAccount] = []

        for url in urls {
            if let parsed = parseRemoteURL(url), !seen.contains(parsed.key) {
                seen.insert(parsed.key)
                accounts.append(parsed.account)
            }
        }
        return accounts
    }

    private func parseRemoteURL(_ url: String) -> (key: String, account: DetectedGitAccount)? {
        // git@github.com:user/repo.git
        if url.hasPrefix("git@github.com:") {
            let path = url.replacingOccurrences(of: "git@github.com:", with: "")
            let user = path.split(separator: "/").first.map(String.init) ?? ""
            guard !user.isEmpty else { return nil }
            return (
                "github:\(user)",
                DetectedGitAccount(provider: .github, username: user, email: nil, token: nil, organization: nil, source: .localRepo)
            )
        }

        // https://github.com/user/repo.git
        if url.contains("github.com") {
            let cleaned = url.replacingOccurrences(of: "https://github.com/", with: "")
                .replacingOccurrences(of: "http://github.com/", with: "")
            let user = cleaned.split(separator: "/").first.map(String.init) ?? ""
            guard !user.isEmpty else { return nil }
            return (
                "github:\(user)",
                DetectedGitAccount(provider: .github, username: user, email: nil, token: nil, organization: nil, source: .localRepo)
            )
        }

        // https://user@dev.azure.com/org/project/_git/repo
        if url.contains("dev.azure.com") {
            let parts = url.components(separatedBy: "/")
            if let azureIdx = parts.firstIndex(where: { $0.contains("dev.azure.com") }), parts.count > azureIdx + 1 {
                let org = parts[azureIdx + 1]
                let user = org
                return (
                    "azure:\(org)",
                    DetectedGitAccount(provider: .azureDevOps, username: user, email: nil, token: nil, organization: org, source: .localRepo)
                )
            }
        }

        // org@vs-ssh.visualstudio.com / ssh.dev.azure.com
        if url.contains("visualstudio.com") || url.contains("ssh.dev.azure.com") {
            let parts = url.components(separatedBy: "/")
            let org = parts.first(where: { !$0.isEmpty && !$0.contains("@") && !$0.contains("ssh") && !$0.contains("visualstudio") }) ?? ""
            if !org.isEmpty {
                return (
                    "azure:\(org)",
                    DetectedGitAccount(provider: .azureDevOps, username: org, email: nil, token: nil, organization: org, source: .localRepo)
                )
            }
        }

        return nil
    }

    // MARK: - Helpers

    private func guessProvider(email: String?, name: String) -> RemoteProviderType {
        let combined = "\(email ?? "") \(name)".lowercased()
        if combined.contains("azure") || combined.contains("visualstudio") || combined.contains("devops") {
            return .azureDevOps
        }
        return .github
    }

    private func dedup(_ accounts: [DetectedGitAccount]) -> [DetectedGitAccount] {
        var seen: Set<String> = []
        var result: [DetectedGitAccount] = []

        let prioritized = accounts.sorted { a, b in
            if a.hasToken && !b.hasToken { return true }
            if !a.hasToken && b.hasToken { return false }
            return false
        }

        for account in prioritized {
            let key = "\(account.provider.rawValue):\(account.username.lowercased())"
            if seen.contains(key) { continue }
            seen.insert(key)
            result.append(account)
        }
        return result
    }
}
