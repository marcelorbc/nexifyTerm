import Foundation

struct AzureDevOpsProvider: RemoteGitProvider {
    let account: RemoteAccount
    private let token: String
    private var baseURL: String {
        "https://dev.azure.com/\(account.organization ?? account.username)"
    }

    init(account: RemoteAccount, token: String) {
        self.account = account
        self.token = token
    }

    // MARK: - Repositories

    func repositories(query: String?, page: Int, perPage: Int) async throws -> [RemoteRepository] {
        let url = "\(baseURL)/_apis/git/repositories?api-version=7.1"
        let (data, _) = try await RemoteHTTP.request(url: url, token: token, provider: .azureDevOps)
        let result = try JSONDecoder.azure.decode(AzureRepoListResponse.self, from: data)

        var repos = result.value.map { $0.toRemoteRepository(org: account.organization ?? account.username) }

        if let query, !query.isEmpty {
            let q = query.lowercased()
            repos = repos.filter { $0.name.lowercased().contains(q) || ($0.description?.lowercased().contains(q) ?? false) }
        }

        let start = (page - 1) * perPage
        let end = min(start + perPage, repos.count)
        guard start < repos.count else { return [] }
        return Array(repos[start..<end])
    }

    // MARK: - Branches

    func branches(repo: String) async throws -> [String] {
        let repoName = repo.components(separatedBy: "/").last ?? repo
        let url = "\(baseURL)/_apis/git/repositories/\(repoName)/refs?filter=heads/&api-version=7.1"
        let (data, _) = try await RemoteHTTP.request(url: url, token: token, provider: .azureDevOps)
        let result = try JSONDecoder.azure.decode(AzureRefListResponse.self, from: data)
        return result.value.compactMap { ref in
            ref.name.hasPrefix("refs/heads/")
                ? String(ref.name.dropFirst("refs/heads/".count))
                : nil
        }
    }

    // MARK: - File Tree

    func fileTree(repo: String, path: String, ref: String) async throws -> [RemoteFileNode] {
        let repoName = repo.components(separatedBy: "/").last ?? repo
        let scopePath = path.isEmpty ? "/" : "/\(path)"
        let url = "\(baseURL)/_apis/git/repositories/\(repoName)/items?scopePath=\(scopePath)&recursionLevel=OneLevel&versionDescriptor.version=\(ref)&api-version=7.1"
        let (data, _) = try await RemoteHTTP.request(url: url, token: token, provider: .azureDevOps)
        let result = try JSONDecoder.azure.decode(AzureItemListResponse.self, from: data)

        return result.value
            .filter { $0.path != scopePath && $0.path != "/" }
            .sorted { a, b in
                if a.isFolder == b.isFolder {
                    return (a.path as NSString).lastPathComponent < (b.path as NSString).lastPathComponent
                }
                return a.isFolder && !b.isFolder
            }
            .map { $0.toRemoteFileNode() }
    }

    // MARK: - File Content

    func fileContent(repo: String, path: String, ref: String) async throws -> String {
        let repoName = repo.components(separatedBy: "/").last ?? repo
        let url = "\(baseURL)/_apis/git/repositories/\(repoName)/items?path=/\(path)&versionDescriptor.version=\(ref)&api-version=7.1"
        let (data, _) = try await RemoteHTTP.request(
            url: url,
            token: token,
            headers: ["Accept": "application/octet-stream"],
            provider: .azureDevOps
        )
        guard let content = String(data: data, encoding: .utf8) else {
            throw RemoteGitError.decodingFailed("Conteúdo não é texto UTF-8")
        }
        return content
    }

    // MARK: - Pull Requests

    func pullRequests(repo: String, state: PRStatus?) async throws -> [RemotePullRequest] {
        let repoName = repo.components(separatedBy: "/").last ?? repo
        let statusParam: String
        switch state {
        case .open: statusParam = "&searchCriteria.status=active"
        case .closed: statusParam = "&searchCriteria.status=abandoned"
        case .merged: statusParam = "&searchCriteria.status=completed"
        case nil: statusParam = ""
        }
        let url = "\(baseURL)/_apis/git/repositories/\(repoName)/pullrequests?api-version=7.1\(statusParam)&$top=30"
        let (data, _) = try await RemoteHTTP.request(url: url, token: token, provider: .azureDevOps)
        let result = try JSONDecoder.azure.decode(AzurePRListResponse.self, from: data)
        return result.value.map { $0.toRemotePR(org: account.organization ?? account.username) }
    }

    // MARK: - Issues (Work Items)

    func issues(repo: String, state: IssueState?) async throws -> [RemoteIssue] {
        let stateFilter = state == .open ? "AND [System.State] <> 'Closed'" : state == .closed ? "AND [System.State] = 'Closed'" : ""
        let wiql = "SELECT [System.Id] FROM WorkItems WHERE [System.WorkItemType] IN ('Bug','Task','User Story','Issue') \(stateFilter) ORDER BY [System.ChangedDate] DESC"

        let wiqlURL = "\(baseURL)/_apis/wit/wiql?api-version=7.1&$top=30"

        guard let url = URL(string: wiqlURL) else {
            throw RemoteGitError.networkError("URL inválida")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let base64 = Data(":\(token)".utf8).base64EncodedString()
        request.setValue("Basic \(base64)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": wiql])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return []
        }

        let wiqlResult = try JSONDecoder.azure.decode(AzureWIQLResult.self, from: data)
        guard !wiqlResult.workItems.isEmpty else { return [] }

        let ids = wiqlResult.workItems.prefix(30).map { String($0.id) }.joined(separator: ",")
        let detailURL = "\(baseURL)/_apis/wit/workitems?ids=\(ids)&fields=System.Id,System.Title,System.State,System.CreatedBy,System.CreatedDate,System.Tags,System.WorkItemType&api-version=7.1"
        let (detailData, _) = try await RemoteHTTP.request(url: detailURL, token: token, provider: .azureDevOps)
        let details = try JSONDecoder.azure.decode(AzureWorkItemListResponse.self, from: detailData)

        return details.value.map { $0.toRemoteIssue(org: account.organization ?? account.username) }
    }
}

// MARK: - Azure DevOps DTOs

private struct AzureRepoListResponse: Decodable {
    let value: [AzureRepo]
}

private struct AzureRepo: Decodable {
    let id: String
    let name: String
    let project: AzureProject
    let defaultBranch: String?
    let remoteUrl: String
    let webUrl: String
    let size: Int?

    func toRemoteRepository(org: String) -> RemoteRepository {
        RemoteRepository(
            id: "azure-\(id)",
            name: name,
            fullName: "\(project.name)/\(name)",
            description: nil,
            language: nil,
            stars: 0,
            forks: 0,
            defaultBranch: defaultBranch?.replacingOccurrences(of: "refs/heads/", with: "") ?? "main",
            cloneURL: remoteUrl,
            htmlURL: webUrl,
            isPrivate: true,
            updatedAt: Date(),
            provider: .azureDevOps
        )
    }
}

private struct AzureProject: Decodable {
    let id: String
    let name: String
}

private struct AzureRefListResponse: Decodable {
    let value: [AzureRef]
}

private struct AzureRef: Decodable {
    let name: String
    let objectId: String
}

private struct AzureItemListResponse: Decodable {
    let value: [AzureItem]
}

private struct AzureItem: Decodable {
    let objectId: String
    let path: String
    let isFolder: Bool
    let url: String?
    let gitObjectType: String?

    func toRemoteFileNode() -> RemoteFileNode {
        let name = (path as NSString).lastPathComponent
        return RemoteFileNode(
            id: objectId,
            name: name,
            path: String(path.dropFirst()),
            type: isFolder ? .directory : .file,
            size: nil
        )
    }
}

private struct AzurePRListResponse: Decodable {
    let value: [AzurePR]
}

private struct AzurePR: Decodable {
    let pullRequestId: Int
    let title: String
    let createdBy: AzureIdentity
    let status: String
    let creationDate: String
    let sourceRefName: String
    let targetRefName: String
    let repository: AzurePRRepo?

    func toRemotePR(org: String) -> RemotePullRequest {
        let prStatus: PRStatus
        switch status {
        case "active": prStatus = .open
        case "completed": prStatus = .merged
        default: prStatus = .closed
        }
        let repoName = repository?.name ?? ""
        let project = repository?.project?.name ?? ""
        let webURL = "https://dev.azure.com/\(org)/\(project)/_git/\(repoName)/pullrequest/\(pullRequestId)"
        return RemotePullRequest(
            id: "azure-pr-\(pullRequestId)",
            number: pullRequestId,
            title: title,
            author: createdBy.displayName,
            status: prStatus,
            createdAt: ISO8601DateFormatter().date(from: creationDate) ?? Date(),
            sourceBranch: sourceRefName.replacingOccurrences(of: "refs/heads/", with: ""),
            targetBranch: targetRefName.replacingOccurrences(of: "refs/heads/", with: ""),
            url: webURL
        )
    }
}

private struct AzureIdentity: Decodable {
    let displayName: String
}

private struct AzurePRRepo: Decodable {
    let name: String
    let project: AzureProject?
}

private struct AzureWIQLResult: Decodable {
    let workItems: [AzureWorkItemRef]
}

private struct AzureWorkItemRef: Decodable {
    let id: Int
}

private struct AzureWorkItemListResponse: Decodable {
    let value: [AzureWorkItem]
}

private struct AzureWorkItem: Decodable {
    let id: Int
    let fields: AzureWorkItemFields

    func toRemoteIssue(org: String) -> RemoteIssue {
        let itemState: IssueState = fields.state == "Closed" ? .closed : .open
        let tags = fields.tags?.components(separatedBy: "; ").filter { !$0.isEmpty } ?? []
        return RemoteIssue(
            id: "azure-wi-\(id)",
            number: id,
            title: fields.title,
            author: fields.createdBy?.displayName ?? "Desconhecido",
            state: itemState,
            labels: tags,
            createdAt: ISO8601DateFormatter().date(from: fields.createdDate ?? "") ?? Date(),
            url: "https://dev.azure.com/\(org)/_workitems/edit/\(id)"
        )
    }
}

private struct AzureWorkItemFields: Decodable {
    let title: String
    let state: String
    let createdBy: AzureIdentity?
    let createdDate: String?
    let tags: String?
    let workItemType: String?

    enum CodingKeys: String, CodingKey {
        case title = "System.Title"
        case state = "System.State"
        case createdBy = "System.CreatedBy"
        case createdDate = "System.CreatedDate"
        case tags = "System.Tags"
        case workItemType = "System.WorkItemType"
    }
}

extension JSONDecoder {
    static let azure: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()
}
