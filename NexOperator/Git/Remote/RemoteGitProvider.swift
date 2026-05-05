import Foundation

protocol RemoteGitProvider {
    var account: RemoteAccount { get }

    func repositories(query: String?, page: Int, perPage: Int) async throws -> [RemoteRepository]
    func branches(repo: String) async throws -> [String]
    func fileTree(repo: String, path: String, ref: String) async throws -> [RemoteFileNode]
    func fileContent(repo: String, path: String, ref: String) async throws -> String
    func pullRequests(repo: String, state: PRStatus?) async throws -> [RemotePullRequest]
    func issues(repo: String, state: IssueState?) async throws -> [RemoteIssue]
}

extension RemoteGitProvider {
    func repositories(query: String? = nil, page: Int = 1, perPage: Int = 100) async throws -> [RemoteRepository] {
        try await repositories(query: query, page: page, perPage: perPage)
    }

    /// Pages through repositories until the provider stops returning a full
    /// page (or `pageCap` is hit). Lets the UI show all 200+ repos at once
    /// instead of being silently capped at 30.
    func allRepositories(
        query: String? = nil,
        perPage: Int = 100,
        pageCap: Int = 20
    ) async throws -> [RemoteRepository] {
        var all: [RemoteRepository] = []
        var page = 1
        while page <= pageCap {
            let chunk = try await repositories(query: query, page: page, perPage: perPage)
            all.append(contentsOf: chunk)
            if chunk.count < perPage { break }
            page += 1
        }
        return all
    }

    func fileTree(repo: String, path: String = "", ref: String = "main") async throws -> [RemoteFileNode] {
        try await fileTree(repo: repo, path: path, ref: ref)
    }

    func fileContent(repo: String, path: String, ref: String = "main") async throws -> String {
        try await fileContent(repo: repo, path: path, ref: ref)
    }

    func pullRequests(repo: String, state: PRStatus? = .open) async throws -> [RemotePullRequest] {
        try await pullRequests(repo: repo, state: state)
    }

    func issues(repo: String, state: IssueState? = .open) async throws -> [RemoteIssue] {
        try await issues(repo: repo, state: state)
    }
}

// MARK: - Remote API Errors

enum RemoteGitError: LocalizedError {
    case notAuthenticated
    case rateLimitExceeded
    case notFound(String)
    case apiFailed(Int, String)
    case decodingFailed(String)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Conta não autenticada. Configure o token de acesso."
        case .rateLimitExceeded:
            return "Limite de requisições excedido. Tente novamente mais tarde."
        case .notFound(let resource):
            return "Recurso não encontrado: \(resource)"
        case .apiFailed(let code, let msg):
            return "API retornou erro \(code): \(msg)"
        case .decodingFailed(let detail):
            return "Falha ao decodificar resposta: \(detail)"
        case .networkError(let msg):
            return "Erro de rede: \(msg)"
        }
    }
}

// MARK: - HTTP Helper

enum RemoteHTTP {
    static func request(
        url: String,
        token: String?,
        headers: [String: String] = [:],
        provider: RemoteProviderType
    ) async throws -> (Data, HTTPURLResponse) {
        guard let requestURL = URL(string: url) else {
            throw RemoteGitError.networkError("URL inválida: \(url)")
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let token {
            switch provider {
            case .github:
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            case .azureDevOps:
                let base64 = Data(":\(token)".utf8).base64EncodedString()
                request.setValue("Basic \(base64)", forHTTPHeaderField: "Authorization")
            }
        }

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteGitError.networkError("Resposta não HTTP")
        }

        switch httpResponse.statusCode {
        case 200...299:
            return (data, httpResponse)
        case 401:
            throw RemoteGitError.notAuthenticated
        case 403:
            throw RemoteGitError.rateLimitExceeded
        case 404:
            throw RemoteGitError.notFound(url)
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw RemoteGitError.apiFailed(httpResponse.statusCode, body)
        }
    }
}
