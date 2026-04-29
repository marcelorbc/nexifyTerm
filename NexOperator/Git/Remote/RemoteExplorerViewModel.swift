import SwiftUI
import Combine

enum AddAccountAuthMethod: String, CaseIterable {
    case browser = "Entrar pelo Navegador"
    case pat = "Personal Access Token"
}

@MainActor
class RemoteExplorerViewModel: ObservableObject {
    @Published var accounts: [RemoteAccount] = []
    @Published var selectedAccount: RemoteAccount?
    @Published var repositories: [RemoteRepository] = []
    @Published var filteredRepositories: [RemoteRepository] = []
    @Published var searchQuery = ""
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var toastMessage: String?
    @Published var toastIsError = false

    // Account creation
    @Published var isShowingAddAccount = false
    @Published var newAccountProvider: RemoteProviderType = .github
    @Published var newAccountName = ""
    @Published var newAccountToken = ""
    @Published var newAccountOrg = ""
    @Published var isAuthenticating = false

    // Browser Auth
    @Published var isWaitingForOAuth = false
    @Published var oauthUserCode: String?
    @Published var authMethod: AddAccountAuthMethod = .browser
    @Published var oauthError: String?

    // Auto-detection
    @Published var detectedAccounts: [DetectedGitAccount] = []
    @Published var isScanning = false
    @Published var hasScanned = false

    // Quick Setup Wizard
    @Published var isShowingQuickSetup = false

    // Repo detail
    @Published var selectedRepo: RemoteRepository?
    @Published var isShowingDetail = false

    // Clone
    @Published var selectedForClone: Set<String> = []
    @Published var isShowingCloneSheet = false
    @Published var cloneBasePath = ""
    @Published var cloneRequests: [CloneRequest] = []
    @Published var isCloningInProgress = false

    // File browser
    @Published var fileTree: [RemoteFileNode] = []
    @Published var currentPath: [String] = []
    @Published var fileContent: String?
    @Published var selectedFilePath: String?
    @Published var isLoadingContent = false

    // PRs & Issues
    @Published var pullRequests: [RemotePullRequest] = []
    @Published var issues: [RemoteIssue] = []
    @Published var isLoadingPRs = false
    @Published var isLoadingIssues = false

    private let oauthService = OAuthService.shared
    private var searchDebounce: AnyCancellable?
    private var currentProvider: (any RemoteGitProvider)?

    init() {
        accounts = oauthService.accounts
        setupSearchDebounce()

        if let first = accounts.first {
            selectedAccount = first
            Task { await loadRepositories() }
        } else {
            Task { await scanLocalGitConfigs() }
        }
    }

    // MARK: - Search Debounce

    private func setupSearchDebounce() {
        searchDebounce = $searchQuery
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] query in
                guard let self else { return }
                Task { await self.filterRepositories(query: query) }
            }
    }

    private func filterRepositories(query: String) async {
        if query.isEmpty {
            filteredRepositories = repositories
        } else {
            let q = query.lowercased()
            filteredRepositories = repositories.filter {
                $0.name.lowercased().contains(q) ||
                ($0.description?.lowercased().contains(q) ?? false) ||
                ($0.language?.lowercased().contains(q) ?? false)
            }
        }
    }

    // MARK: - Account Management

    func selectAccount(_ account: RemoteAccount) {
        selectedAccount = account
        repositories = []
        filteredRepositories = []
        searchQuery = ""
        Task { await loadRepositories() }
    }

    func addAccountWithToken() async {
        guard !newAccountToken.isEmpty else { return }

        isAuthenticating = true
        defer { isAuthenticating = false }

        do {
            let username: String
            let org: String?

            switch newAccountProvider {
            case .github:
                let (data, _) = try await RemoteHTTP.request(
                    url: "https://api.github.com/user",
                    token: newAccountToken,
                    provider: .github
                )
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                username = json["login"] as? String ?? "user"
                org = nil

            case .azureDevOps:
                guard !newAccountOrg.isEmpty else {
                    showToast("Organização é obrigatória para Azure DevOps", isError: true)
                    return
                }
                username = try await oauthService.validateAzureToken(
                    organization: newAccountOrg,
                    token: newAccountToken
                )
                org = newAccountOrg
            }

            let name = newAccountName.isEmpty
                ? "\(newAccountProvider.displayName) - \(username)"
                : newAccountName

            oauthService.addAccount(
                provider: newAccountProvider,
                displayName: name,
                username: username,
                organization: org,
                token: newAccountToken
            )

            accounts = oauthService.accounts
            selectedAccount = accounts.last
            isShowingAddAccount = false
            resetNewAccountForm()
            showToast("Conta adicionada: \(name)")
            await loadRepositories()
        } catch {
            showToast("Falha na autenticação: \(error.localizedDescription)", isError: true)
        }
    }

    func removeAccount(_ account: RemoteAccount) {
        oauthService.removeAccount(account)
        accounts = oauthService.accounts
        if selectedAccount?.id == account.id {
            selectedAccount = accounts.first
            repositories = []
            filteredRepositories = []
            if selectedAccount != nil {
                Task { await loadRepositories() }
            }
        }
    }

    private func resetNewAccountForm() {
        newAccountName = ""
        newAccountToken = ""
        newAccountOrg = ""
        newAccountProvider = .github
    }

    // MARK: - Repositories

    func loadRepositories() async {
        guard let account = selectedAccount,
              let provider = oauthService.provider(for: account) else { return }

        currentProvider = provider
        isLoading = true
        errorMessage = nil

        do {
            repositories = try await provider.repositories()
            filteredRepositories = repositories
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func searchRepositories() async {
        guard let provider = currentProvider else { return }
        guard !searchQuery.isEmpty else {
            filteredRepositories = repositories
            return
        }

        isLoading = true
        do {
            let results = try await provider.repositories(query: searchQuery)
            filteredRepositories = results
        } catch {
            filteredRepositories = repositories.filter {
                $0.name.lowercased().contains(searchQuery.lowercased())
            }
        }
        isLoading = false
    }

    // MARK: - Repo Detail

    func openRepoDetail(_ repo: RemoteRepository) {
        selectedRepo = repo
        isShowingDetail = true
        currentPath = []
        fileTree = []
        fileContent = nil
        selectedFilePath = nil
        pullRequests = []
        issues = []

        Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.loadFileTree() }
                group.addTask { await self.loadPullRequests() }
                group.addTask { await self.loadIssues() }
            }
        }
    }

    func closeDetail() {
        isShowingDetail = false
        selectedRepo = nil
    }

    // MARK: - File Tree

    func loadFileTree(path: String = "") async {
        guard let repo = selectedRepo, let provider = currentProvider else { return }
        isLoadingContent = true

        do {
            let nodes = try await provider.fileTree(
                repo: repo.fullName,
                path: path,
                ref: repo.defaultBranch
            )
            fileTree = nodes
            fileContent = nil
            selectedFilePath = nil
        } catch {
            showToast("Erro ao carregar arquivos: \(error.localizedDescription)", isError: true)
        }
        isLoadingContent = false
    }

    func navigateToDirectory(_ node: RemoteFileNode) {
        currentPath.append(node.name)
        Task { await loadFileTree(path: node.path) }
    }

    func navigateBack() {
        guard !currentPath.isEmpty else { return }
        currentPath.removeLast()
        let path = currentPath.joined(separator: "/")
        Task { await loadFileTree(path: path) }
    }

    func navigateToRoot() {
        currentPath = []
        Task { await loadFileTree() }
    }

    func loadFileContent(_ node: RemoteFileNode) async {
        guard let repo = selectedRepo, let provider = currentProvider else { return }
        isLoadingContent = true
        selectedFilePath = node.path

        do {
            fileContent = try await provider.fileContent(
                repo: repo.fullName,
                path: node.path,
                ref: repo.defaultBranch
            )
        } catch {
            fileContent = "// Erro ao carregar: \(error.localizedDescription)"
        }
        isLoadingContent = false
    }

    // MARK: - PRs & Issues

    func loadPullRequests() async {
        guard let repo = selectedRepo, let provider = currentProvider else { return }
        isLoadingPRs = true
        do {
            pullRequests = try await provider.pullRequests(repo: repo.fullName)
        } catch {
            NexLog.git.error("Failed to load PRs: \(error.localizedDescription)")
        }
        isLoadingPRs = false
    }

    func loadIssues() async {
        guard let repo = selectedRepo, let provider = currentProvider else { return }
        isLoadingIssues = true
        do {
            issues = try await provider.issues(repo: repo.fullName)
        } catch {
            NexLog.git.error("Failed to load issues: \(error.localizedDescription)")
        }
        isLoadingIssues = false
    }

    // MARK: - Clone

    func toggleCloneSelection(_ repoId: String) {
        if selectedForClone.contains(repoId) {
            selectedForClone.remove(repoId)
        } else {
            selectedForClone.insert(repoId)
        }
    }

    func selectAllForClone() {
        selectedForClone = Set(filteredRepositories.map(\.id))
    }

    func deselectAllForClone() {
        selectedForClone.removeAll()
    }

    func prepareClone() {
        guard !selectedForClone.isEmpty else {
            showToast("Selecione ao menos um repositório", isError: true)
            return
        }
        cloneBasePath = NSHomeDirectory() + "/Developer"
        cloneRequests = filteredRepositories
            .filter { selectedForClone.contains($0.id) }
            .map { CloneRequest(repository: $0, destinationPath: "") }
        isShowingCloneSheet = true
    }

    func startClone() async {
        guard let account = selectedAccount else { return }
        let token = oauthService.token(for: account)

        isCloningInProgress = true

        for i in cloneRequests.indices {
            let repo = cloneRequests[i].repository
            let dest = "\(cloneBasePath)/\(repo.name)"
            cloneRequests[i].destinationPath = dest
            cloneRequests[i].status = .cloning

            do {
                try await oauthService.cloneRepository(
                    url: repo.cloneURL,
                    destination: dest,
                    token: token,
                    provider: account.provider
                ) { progress in
                    Task { @MainActor in
                        if let idx = self.cloneRequests.firstIndex(where: { $0.repository.id == repo.id }) {
                            self.cloneRequests[idx].status = .cloning
                        }
                    }
                }
                cloneRequests[i].status = .completed
            } catch {
                cloneRequests[i].status = .failed(error.localizedDescription)
            }
        }

        isCloningInProgress = false

        let succeeded = cloneRequests.filter { $0.status == .completed }.count
        let failed = cloneRequests.filter {
            if case .failed = $0.status { return true }
            return false
        }.count

        if failed == 0 {
            showToast("\(succeeded) repositórios clonados com sucesso")
        } else {
            showToast("\(succeeded) clonados, \(failed) falharam", isError: failed > 0)
        }
    }

    func createDirectory(at path: String) -> Bool {
        do {
            try FileManager.default.createDirectory(
                atPath: path,
                withIntermediateDirectories: true
            )
            return true
        } catch {
            showToast("Erro ao criar pasta: \(error.localizedDescription)", isError: true)
            return false
        }
    }

    // MARK: - Browser Login

    func startGitHubBrowserLogin() {
        isWaitingForOAuth = true
        oauthError = nil
        oauthUserCode = nil

        Task {
            do {
                let clientId = AppConfig.GitHub.oauthClientId
                let codeResponse = try await requestGitHubDeviceCode(clientId: clientId)

                oauthUserCode = codeResponse.userCode
                NSWorkspace.shared.open(codeResponse.verificationURL)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(codeResponse.userCode, forType: .string)

                let result = try await oauthService.authenticateGitHub(clientId: clientId)

                oauthService.addAccount(
                    provider: .github,
                    displayName: "GitHub - \(result.username)",
                    username: result.username,
                    organization: nil,
                    token: result.token
                )

                accounts = oauthService.accounts
                selectedAccount = accounts.last
                isWaitingForOAuth = false
                isShowingAddAccount = false
                resetNewAccountForm()
                showToast("Conta GitHub conectada: \(result.username)")
                await loadRepositories()
            } catch {
                isWaitingForOAuth = false
                oauthError = "Falha no login: \(error.localizedDescription)"
            }
        }
    }

    func cancelBrowserLogin() {
        isWaitingForOAuth = false
        oauthUserCode = nil
        oauthError = nil
    }

    func openAzurePATCreationPage() {
        let org = newAccountOrg.isEmpty ? "_" : newAccountOrg
        let url = "https://dev.azure.com/\(org)/_usersSettings/tokens"
        if let u = URL(string: url) {
            NSWorkspace.shared.open(u)
        }
    }

    private func requestGitHubDeviceCode(clientId: String) async throws -> (userCode: String, verificationURL: URL, deviceCode: String, interval: Int) {
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

        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        guard let deviceCode = json["device_code"] as? String,
              let userCode = json["user_code"] as? String,
              let verificationURI = json["verification_uri"] as? String,
              let verificationURL = URL(string: verificationURI) else {
            throw RemoteGitError.decodingFailed("Device code response inválida")
        }

        let interval = json["interval"] as? Int ?? 5
        return (userCode, verificationURL, deviceCode, interval)
    }

    // MARK: - Auto-Detection

    func scanLocalGitConfigs() async {
        isScanning = true
        detectedAccounts = await GitConfigScanner.shared.scanAll()
        hasScanned = true
        isScanning = false
    }

    func prefillFromDetected(_ detected: DetectedGitAccount) {
        newAccountProvider = detected.provider
        newAccountName = detected.username
        newAccountToken = detected.token ?? ""
        newAccountOrg = detected.organization ?? ""
        isShowingAddAccount = true
    }

    func importDetectedAccount(_ detected: DetectedGitAccount) async {
        guard detected.hasToken else {
            prefillFromDetected(detected)
            return
        }

        isAuthenticating = true
        defer { isAuthenticating = false }

        do {
            let username: String
            let org: String?

            switch detected.provider {
            case .github:
                let (data, _) = try await RemoteHTTP.request(
                    url: "https://api.github.com/user",
                    token: detected.token!,
                    provider: .github
                )
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                username = json["login"] as? String ?? detected.username
                org = nil

            case .azureDevOps:
                guard let detectedOrg = detected.organization, !detectedOrg.isEmpty else {
                    prefillFromDetected(detected)
                    return
                }
                username = try await oauthService.validateAzureToken(
                    organization: detectedOrg,
                    token: detected.token!
                )
                org = detectedOrg
            }

            let name = "\(detected.provider.displayName) - \(username)"

            oauthService.addAccount(
                provider: detected.provider,
                displayName: name,
                username: username,
                organization: org,
                token: detected.token!
            )

            accounts = oauthService.accounts
            selectedAccount = accounts.last
            showToast("Conta importada: \(name)")
            await loadRepositories()
        } catch {
            prefillFromDetected(detected)
            showToast("Token inválido. Preencha manualmente.", isError: true)
        }
    }

    // MARK: - Toast

    func showToast(_ message: String, isError: Bool = false) {
        toastMessage = message
        toastIsError = isError
        Task {
            try? await Task.sleep(nanoseconds: isError ? 4_000_000_000 : 2_500_000_000)
            if toastMessage == message {
                toastMessage = nil
            }
        }
    }
}

