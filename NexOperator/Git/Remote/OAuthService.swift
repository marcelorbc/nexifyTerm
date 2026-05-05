import Foundation
import AuthenticationServices

@MainActor
class OAuthService: NSObject, ObservableObject {
    static let shared = OAuthService()

    private let keychain = KeychainStore()
    private let accountsKey = "remote_accounts"
    private let callbackScheme = "nexifyterm"

    @Published var accounts: [RemoteAccount] = []

    override init() {
        super.init()
        loadAccounts()
    }

    // MARK: - Account Management

    func addAccount(provider: RemoteProviderType, displayName: String, username: String, organization: String?, token: String) {
        let account = RemoteAccount(
            id: UUID(),
            provider: provider,
            displayName: displayName,
            username: username,
            organization: organization,
            isAuthenticated: true
        )
        keychain.set(key: account.keychainTokenKey, value: token)
        accounts.append(account)
        saveAccounts()
    }

    func removeAccount(_ account: RemoteAccount) {
        keychain.delete(key: account.keychainTokenKey)
        accounts.removeAll { $0.id == account.id }
        saveAccounts()
    }

    func updateToken(for account: RemoteAccount, token: String) {
        keychain.set(key: account.keychainTokenKey, value: token)
        if let idx = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[idx] = RemoteAccount(
                id: account.id,
                provider: account.provider,
                displayName: account.displayName,
                username: account.username,
                organization: account.organization,
                isAuthenticated: true
            )
            saveAccounts()
        }
    }

    func token(for account: RemoteAccount) -> String? {
        keychain.get(key: account.keychainTokenKey)
    }

    func provider(for account: RemoteAccount) -> (any RemoteGitProvider)? {
        guard let token = token(for: account) else { return nil }
        switch account.provider {
        case .github:
            return GitHubProvider(account: account, token: token)
        case .azureDevOps:
            return AzureDevOpsProvider(account: account, token: token)
        }
    }

    // MARK: - GitHub OAuth (Device Flow)

    struct DeviceCode {
        let deviceCode: String
        let userCode: String
        let verificationURL: URL
        let interval: Int
    }

    func requestGitHubDeviceCode(clientId: String) async throws -> DeviceCode {
        let response = try await requestDeviceCode(clientId: clientId)
        return DeviceCode(
            deviceCode: response.deviceCode,
            userCode: response.userCode,
            verificationURL: response.verificationURL,
            interval: response.interval
        )
    }

    func completeGitHubAuth(clientId: String, deviceCode: DeviceCode) async throws -> (token: String, username: String) {
        let token = try await pollForToken(
            clientId: clientId,
            deviceCode: deviceCode.deviceCode,
            interval: deviceCode.interval
        )
        let username = try await fetchGitHubUsername(token: token)
        return (token, username)
    }

    private func requestDeviceCode(clientId: String) async throws -> DeviceCodeResponse {
        guard let url = URL(string: "https://github.com/login/device/code") else {
            throw RemoteGitError.networkError("URL inválida")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": clientId,
            "scope": "repo read:org read:user"
        ])

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw RemoteGitError.networkError("Resposta HTTP inválida")
        }

        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw RemoteGitError.apiFailed(http.statusCode, "GitHub retornou status \(http.statusCode). Verifique se o OAuth Client ID é válido. \(body.prefix(200))")
        }

        var json: [String: Any] = [:]

        if let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = parsed
        } else if let body = String(data: data, encoding: .utf8) {
            for pair in body.components(separatedBy: "&") {
                let kv = pair.components(separatedBy: "=")
                if kv.count == 2 {
                    json[kv[0]] = kv[1].removingPercentEncoding ?? kv[1]
                }
            }
        }

        if let errorMsg = json["error"] as? String {
            let desc = json["error_description"] as? String ?? errorMsg
            throw RemoteGitError.apiFailed(http.statusCode, "GitHub OAuth: \(desc)")
        }

        guard let deviceCode = json["device_code"] as? String,
              let userCode = json["user_code"] as? String,
              let verificationURI = json["verification_uri"] as? String,
              let verificationURL = URL(string: verificationURI) else {
            let body = String(data: data, encoding: .utf8) ?? "vazio"
            throw RemoteGitError.decodingFailed("Device code response inválida. Verifique o Client ID OAuth. Resposta: \(body.prefix(300))")
        }

        let interval = json["interval"] as? Int ?? 5

        return DeviceCodeResponse(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURL: verificationURL,
            interval: interval
        )
    }

    private func pollForToken(clientId: String, deviceCode: String, interval: Int) async throws -> String {
        guard let url = URL(string: "https://github.com/login/oauth/access_token") else {
            throw RemoteGitError.networkError("URL inválida")
        }

        let maxAttempts = 60
        for _ in 0..<maxAttempts {
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "client_id": clientId,
                "device_code": deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
            ])

            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

            if let token = json["access_token"] as? String {
                return token
            }

            if let error = json["error"] as? String {
                switch error {
                case "authorization_pending":
                    continue
                case "slow_down":
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    continue
                case "expired_token":
                    throw RemoteGitError.notAuthenticated
                case "access_denied":
                    throw RemoteGitError.notAuthenticated
                default:
                    throw RemoteGitError.apiFailed(0, error)
                }
            }
        }

        throw RemoteGitError.notAuthenticated
    }

    private func fetchGitHubUsername(token: String) async throws -> String {
        let (data, _) = try await RemoteHTTP.request(
            url: "https://api.github.com/user",
            token: token,
            provider: .github
        )
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let login = json["login"] as? String else {
            throw RemoteGitError.decodingFailed("Não foi possível obter username")
        }
        return login
    }

    // MARK: - Azure DevOps (PAT-based for now)

    func validateAzureToken(organization: String, token: String) async throws -> String {
        // Sanitiza a organização: usuários frequentemente colam a URL inteira
        // (`https://dev.azure.com/yandev/`) no campo. O Azure devolve 404
        // nesses casos com uma mensagem inútil — melhor extrair só o slug.
        let cleanOrg = OAuthService.sanitizeAzureOrganization(organization)

        // Azure DevOps muda periodicamente quais versões de API são GA vs
        // preview. Em vez de hard-codar uma única, tentamos uma cadeia de
        // versões — passamos para o caso quando a primeira reclamar de
        // "preview" (HTTP 400 com mensagem específica).
        let versionFallbacks = [
            "7.1-preview.1",
            "7.2-preview.1",
            "6.0",
            "5.0"
        ]

        let base64 = Data(":\(token)".utf8).base64EncodedString()

        var data = Data()
        var http: HTTPURLResponse? = nil

        for (idx, version) in versionFallbacks.enumerated() {
            let url = "https://dev.azure.com/\(cleanOrg)/_apis/connectionData?api-version=\(version)"
            guard let requestURL = URL(string: url) else {
                throw RemoteGitError.networkError("URL inválida (org='\(cleanOrg)')")
            }
            var request = URLRequest(url: requestURL)
            request.setValue("Basic \(base64)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let (d, response) = try await URLSession.shared.data(for: request)
            guard let r = response as? HTTPURLResponse else {
                throw RemoteGitError.networkError("Resposta sem HTTPURLResponse")
            }

            data = d
            http = r

            // Sucesso ou erro definitivo (não é preview-mismatch): para aqui.
            // Só retentamos quando a resposta diz exatamente "under preview".
            let bodyText = String(data: d, encoding: .utf8) ?? ""
            let isPreviewMismatch = r.statusCode == 400 && bodyText.contains("under preview")
            let hasMoreFallbacks = idx < versionFallbacks.count - 1
            if r.statusCode == 200 || !isPreviewMismatch || !hasMoreFallbacks {
                break
            }
        }

        guard let http else {
            throw RemoteGitError.networkError("Sem resposta após \(versionFallbacks.count) tentativas")
        }

        if http.statusCode != 200 {
            // Surface real cause: status code + first chunk of the response
            // body. Keeps the user out of a guessing game ("é o token?
            // é o org?") that the previous code forced.
            let bodyPreview = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(240) ?? ""
            // Azure devolve HTML quando o domínio aceita mas o tenant não
            // existe — detectamos pelo Content-Type pra dar dica útil.
            let contentType = (http.allHeaderFields["Content-Type"] as? String) ?? ""
            let detail: String
            switch http.statusCode {
            case 401:
                detail = "401 Unauthorized — token inválido, expirado ou sem o scope necessário (precisa Code: Read, no mínimo)."
            case 403:
                detail = "403 Forbidden — token válido mas sem permissão na organização '\(cleanOrg)'. Confira se o PAT foi gerado dentro dessa org."
            case 404:
                if contentType.contains("text/html") {
                    detail = "404 — organização '\(cleanOrg)' não existe ou exige login pelo navegador. Confirme em https://dev.azure.com/\(cleanOrg)"
                } else {
                    detail = "404 — endpoint não encontrado para org '\(cleanOrg)'. Verifique o nome da organização."
                }
            case 203:
                detail = "203 — Azure devolveu página de login HTML (token rejeitado silenciosamente). Confirme o PAT."
            default:
                detail = "HTTP \(http.statusCode). Resposta: \(bodyPreview.isEmpty ? "(corpo vazio)" : String(bodyPreview))"
            }
            throw RemoteGitError.apiFailed(http.statusCode, detail)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let authenticatedUser = json["authenticatedUser"] as? [String: Any] ?? [:]
        let properties = authenticatedUser["properties"] as? [String: Any] ?? [:]
        let account = properties["Account"] as? [String: Any] ?? [:]
        let username = account["$value"] as? String ?? cleanOrg
        return username
    }

    /// Aceita "yandev", "https://dev.azure.com/yandev", "yandev/", etc.
    /// Retorna apenas o slug. Static para que o caller também possa sanitizar
    /// antes de persistir no keychain.
    static func sanitizeAzureOrganization(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = s.range(of: "dev.azure.com/") {
            s = String(s[range.upperBound...])
        }
        if let slash = s.firstIndex(of: "/") {
            s = String(s[..<slash])
        }
        return s
    }

    // MARK: - Clone

    func cloneRepository(url: String, destination: String, token: String?, provider: RemoteProviderType, onProgress: @escaping (String) -> Void) async throws {
        let cloneURL: String
        if let token {
            switch provider {
            case .github:
                cloneURL = url.replacingOccurrences(of: "https://", with: "https://x-access-token:\(token)@")
            case .azureDevOps:
                cloneURL = url.replacingOccurrences(of: "https://", with: "https://pat:\(token)@")
            }
        } else {
            cloneURL = url
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["clone", "--progress", cloneURL, destination]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let line = String(data: data, encoding: .utf8), !line.isEmpty {
                DispatchQueue.main.async {
                    onProgress(line.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }

        try process.run()
        process.waitUntilExit()

        stderrPipe.fileHandleForReading.readabilityHandler = nil

        guard process.terminationStatus == 0 else {
            throw RemoteGitError.apiFailed(Int(process.terminationStatus), "git clone falhou")
        }
    }

    // MARK: - Persistence

    private func saveAccounts() {
        guard let data = try? JSONEncoder().encode(accounts),
              let json = String(data: data, encoding: .utf8) else { return }
        keychain.set(key: accountsKey, value: json)
    }

    private func loadAccounts() {
        guard let json = keychain.get(key: accountsKey),
              let data = json.data(using: .utf8),
              let loaded = try? JSONDecoder().decode([RemoteAccount].self, from: data) else { return }
        accounts = loaded
    }
}

// MARK: - Device Code Response

private struct DeviceCodeResponse {
    let deviceCode: String
    let userCode: String
    let verificationURL: URL
    let interval: Int
}
