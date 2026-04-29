import Foundation

struct GitHubProvider: RemoteGitProvider {
    let account: RemoteAccount
    private let token: String
    private let baseURL = "https://api.github.com"

    init(account: RemoteAccount, token: String) {
        self.account = account
        self.token = token
    }

    // MARK: - Repositories

    func repositories(query: String?, page: Int, perPage: Int) async throws -> [RemoteRepository] {
        let url: String
        if let query, !query.isEmpty {
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            let userFilter = "user:\(account.username)"
            url = "\(baseURL)/search/repositories?q=\(encoded)+\(userFilter)&page=\(page)&per_page=\(perPage)&sort=updated"
        } else {
            url = "\(baseURL)/user/repos?page=\(page)&per_page=\(perPage)&sort=updated&affiliation=owner,collaborator,organization_member"
        }

        let (data, _) = try await RemoteHTTP.request(url: url, token: token, provider: .github)

        if query != nil && !query!.isEmpty {
            let result = try JSONDecoder.github.decode(GitHubSearchResult.self, from: data)
            return result.items.map { $0.toRemoteRepository() }
        } else {
            let repos = try JSONDecoder.github.decode([GitHubRepo].self, from: data)
            return repos.map { $0.toRemoteRepository() }
        }
    }

    // MARK: - Branches

    func branches(repo: String) async throws -> [String] {
        let url = "\(baseURL)/repos/\(repo)/branches?per_page=100"
        let (data, _) = try await RemoteHTTP.request(url: url, token: token, provider: .github)
        let branches = try JSONDecoder.github.decode([GitHubBranch].self, from: data)
        return branches.map(\.name)
    }

    // MARK: - File Tree

    func fileTree(repo: String, path: String, ref: String) async throws -> [RemoteFileNode] {
        let safePath = path.isEmpty ? "" : "/\(path)"
        let url = "\(baseURL)/repos/\(repo)/contents\(safePath)?ref=\(ref)"
        let (data, _) = try await RemoteHTTP.request(url: url, token: token, provider: .github)
        let items = try JSONDecoder.github.decode([GitHubContent].self, from: data)
        return items
            .sorted { a, b in
                if a.type == b.type { return a.name < b.name }
                return a.type == "dir"
            }
            .map { $0.toRemoteFileNode() }
    }

    // MARK: - File Content

    func fileContent(repo: String, path: String, ref: String) async throws -> String {
        let url = "\(baseURL)/repos/\(repo)/contents/\(path)?ref=\(ref)"
        let (data, _) = try await RemoteHTTP.request(
            url: url,
            token: token,
            headers: ["Accept": "application/vnd.github.raw+json"],
            provider: .github
        )
        guard let content = String(data: data, encoding: .utf8) else {
            throw RemoteGitError.decodingFailed("Conteúdo não é texto UTF-8")
        }
        return content
    }

    // MARK: - Pull Requests

    func pullRequests(repo: String, state: PRStatus?) async throws -> [RemotePullRequest] {
        let stateParam: String
        switch state {
        case .open: stateParam = "open"
        case .closed, .merged: stateParam = "closed"
        case nil: stateParam = "all"
        }
        let url = "\(baseURL)/repos/\(repo)/pulls?state=\(stateParam)&per_page=30&sort=updated"
        let (data, _) = try await RemoteHTTP.request(url: url, token: token, provider: .github)
        let prs = try JSONDecoder.github.decode([GitHubPR].self, from: data)
        return prs.map { $0.toRemotePR() }
    }

    // MARK: - Issues

    func issues(repo: String, state: IssueState?) async throws -> [RemoteIssue] {
        let stateParam = state == .open ? "open" : state == .closed ? "closed" : "all"
        let url = "\(baseURL)/repos/\(repo)/issues?state=\(stateParam)&per_page=30&sort=updated"
        let (data, _) = try await RemoteHTTP.request(url: url, token: token, provider: .github)
        let issues = try JSONDecoder.github.decode([GitHubIssue].self, from: data)
        return issues
            .filter { $0.pull_request == nil }
            .map { $0.toRemoteIssue() }
    }
}

// MARK: - GitHub API DTOs

private struct GitHubSearchResult: Decodable {
    let items: [GitHubRepo]
}

private struct GitHubRepo: Decodable {
    let id: Int
    let name: String
    let full_name: String
    let description: String?
    let language: String?
    let stargazers_count: Int
    let forks_count: Int
    let default_branch: String
    let clone_url: String
    let html_url: String
    let `private`: Bool
    let updated_at: String

    func toRemoteRepository() -> RemoteRepository {
        RemoteRepository(
            id: "github-\(id)",
            name: name,
            fullName: full_name,
            description: description,
            language: language,
            stars: stargazers_count,
            forks: forks_count,
            defaultBranch: default_branch,
            cloneURL: clone_url,
            htmlURL: html_url,
            isPrivate: `private`,
            updatedAt: ISO8601DateFormatter().date(from: updated_at) ?? Date(),
            provider: .github
        )
    }
}

private struct GitHubBranch: Decodable {
    let name: String
}

private struct GitHubContent: Decodable {
    let name: String
    let path: String
    let sha: String
    let type: String
    let size: Int?

    func toRemoteFileNode() -> RemoteFileNode {
        RemoteFileNode(
            id: sha,
            name: name,
            path: path,
            type: type == "dir" ? .directory : .file,
            size: size
        )
    }
}

private struct GitHubPR: Decodable {
    let id: Int
    let number: Int
    let title: String
    let user: GitHubUser
    let state: String
    let created_at: String
    let merged_at: String?
    let head: GitHubRef
    let base: GitHubRef
    let html_url: String

    func toRemotePR() -> RemotePullRequest {
        let prStatus: PRStatus
        if merged_at != nil {
            prStatus = .merged
        } else if state == "closed" {
            prStatus = .closed
        } else {
            prStatus = .open
        }
        return RemotePullRequest(
            id: "github-pr-\(id)",
            number: number,
            title: title,
            author: user.login,
            status: prStatus,
            createdAt: ISO8601DateFormatter().date(from: created_at) ?? Date(),
            sourceBranch: head.ref,
            targetBranch: base.ref,
            url: html_url
        )
    }
}

private struct GitHubUser: Decodable {
    let login: String
}

private struct GitHubRef: Decodable {
    let ref: String
}

private struct GitHubIssue: Decodable {
    let id: Int
    let number: Int
    let title: String
    let user: GitHubUser
    let state: String
    let labels: [GitHubLabel]
    let created_at: String
    let html_url: String
    let pull_request: GitHubPRRef?

    func toRemoteIssue() -> RemoteIssue {
        RemoteIssue(
            id: "github-issue-\(id)",
            number: number,
            title: title,
            author: user.login,
            state: state == "open" ? .open : .closed,
            labels: labels.map(\.name),
            createdAt: ISO8601DateFormatter().date(from: created_at) ?? Date(),
            url: html_url
        )
    }
}

private struct GitHubLabel: Decodable {
    let name: String
}

private struct GitHubPRRef: Decodable {}

// MARK: - JSONDecoder

extension JSONDecoder {
    static let github: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
