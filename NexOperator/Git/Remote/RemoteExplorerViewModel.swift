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

    // Tech filters / sorting (multi-repo discovery UX)
    @Published var selectedTechFilters: Set<RepoTech> = []
    @Published var sortOption: RepoSortOption = .nameAsc
    @Published var isDetectingTechs = false
    @Published var techDetectionProgress: (done: Int, total: Int) = (0, 0)

    enum RepoSortOption: String, CaseIterable, Identifiable {
        case nameAsc = "Nome A→Z"
        case nameDesc = "Nome Z→A"
        case updatedDesc = "Atualizado recente"
        case updatedAsc = "Atualizado antigo"
        var id: String { rawValue }
    }
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
    var defaultClonePath: String?

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
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.applyFilters()
            }
    }

    /// Aplica busca + filtro de tech + ordenação. Tudo é client-side: as
    /// 200+ repos da org já estão em memória, então filtrar é quase
    /// instantâneo (e não consome rate-limit do servidor).
    func applyFilters() {
        let q = searchQuery.lowercased().trimmingCharacters(in: .whitespaces)
        let detector = RepoTechDetector.shared

        var result = repositories.filter { repo in
            // Search box: matches name, description, fullName (project/repo
            // for Azure), language, or any detected tech label.
            if !q.isEmpty {
                let detectedLabels = (detector.techs(for: repo) ?? []).map { $0.label.lowercased() }
                let hay = [
                    repo.name,
                    repo.fullName,
                    repo.description ?? "",
                    repo.language ?? "",
                    detectedLabels.joined(separator: " ")
                ].joined(separator: " ").lowercased()
                if !hay.contains(q) { return false }
            }

            // Tech filter: AND-mode — repo precisa ter TODAS as techs marcadas.
            if !selectedTechFilters.isEmpty {
                let detected = detector.techs(for: repo) ?? []
                if !selectedTechFilters.isSubset(of: detected) { return false }
            }
            return true
        }

        switch sortOption {
        case .nameAsc:      result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .nameDesc:     result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        case .updatedDesc:  result.sort { $0.updatedAt > $1.updatedAt }
        case .updatedAsc:   result.sort { $0.updatedAt < $1.updatedAt }
        }

        filteredRepositories = result
    }

    func toggleTechFilter(_ tech: RepoTech) {
        if selectedTechFilters.contains(tech) {
            selectedTechFilters.remove(tech)
        } else {
            selectedTechFilters.insert(tech)
        }
        applyFilters()
    }

    func clearTechFilters() {
        selectedTechFilters.removeAll()
        applyFilters()
    }

    /// Conjunto de techs detectadas em pelo menos um repo — alimenta a barra
    /// de chips para o usuário só ver filtros relevantes.
    var availableTechs: [RepoTech] {
        let detector = RepoTechDetector.shared
        var seen: Set<RepoTech> = []
        for repo in repositories {
            if let techs = detector.techs(for: repo) {
                seen.formUnion(techs)
            }
        }
        return Array(seen).sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
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
                let cleanOrg = OAuthService.sanitizeAzureOrganization(newAccountOrg)
                guard !cleanOrg.isEmpty else {
                    showToast("Organização é obrigatória para Azure DevOps", isError: true)
                    return
                }
                username = try await oauthService.validateAzureToken(
                    organization: cleanOrg,
                    token: newAccountToken
                )
                org = cleanOrg
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
            // Não prefixar "Falha na autenticação:" — o erro já carrega
            // a causa real (status code + mensagem do servidor).
            showToast(error.localizedDescription, isError: true)
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
            // Paginar até esgotar — antes a chamada padrão limitava a 30
            // (perPage default), criando a falsa impressão de que a org
            // tinha apenas 30 repos.
            repositories = try await provider.allRepositories()
            filteredRepositories = repositories
            applyFilters()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false

        // Dispara detecção de tecnologia em background — não bloqueia a
        // listagem. A UI atualiza linha por linha conforme os resultados
        // chegam graças ao @Published do detector.
        Task { await detectTechsForCurrentRepos() }
    }

    /// Re-detecta techs apagando o cache primeiro. Útil quando o usuário
    /// quer forçar refresh.
    func redetectTechs() async {
        RepoTechDetector.shared.clear()
        await detectTechsForCurrentRepos()
    }

    private func detectTechsForCurrentRepos() async {
        guard let provider = currentProvider, !repositories.isEmpty else { return }
        isDetectingTechs = true
        defer { isDetectingTechs = false }

        techDetectionProgress = (0, repositories.count)
        await RepoTechDetector.shared.detectMany(repos: repositories, provider: provider)
        techDetectionProgress = (repositories.count, repositories.count)
    }

    /// Busca local. Antes ia ao servidor a cada submit (lento + gastava
    /// rate-limit). Agora todos os repos já estão carregados, então filtrar
    /// é client-side e instantâneo. Mantida para compat. com `.onSubmit`.
    func searchRepositories() async {
        applyFilters()
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
        if let path = defaultClonePath,
           FileManager.default.fileExists(atPath: path) {
            cloneBasePath = path
        } else {
            cloneBasePath = NSHomeDirectory() + "/Developer"
        }
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
                let deviceCode = try await oauthService.requestGitHubDeviceCode(clientId: clientId)

                oauthUserCode = deviceCode.userCode
                NSWorkspace.shared.open(deviceCode.verificationURL)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(deviceCode.userCode, forType: .string)

                let result = try await oauthService.completeGitHubAuth(clientId: clientId, deviceCode: deviceCode)

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

        // Mensagens longas (geralmente erros com payload do servidor) ficam
        // persistentes até o usuário fechar manualmente — o objetivo é dar
        // tempo de copiar e compartilhar o erro completo.
        let isLong = isError && message.count > 80
        if isLong { return }

        Task {
            // Erros: 60s (era 4s). Sucesso: 2.5s.
            try? await Task.sleep(nanoseconds: isError ? 60_000_000_000 : 2_500_000_000)
            if toastMessage == message {
                toastMessage = nil
            }
        }
    }

    func dismissToast() {
        toastMessage = nil
    }
}

