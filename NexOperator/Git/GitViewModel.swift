import SwiftUI
import Combine

@MainActor
class GitViewModel: ObservableObject {
    private(set) var repoPath: String
    private var service: GitService
    private var refreshTimer: Timer?
    /// Tracks the in-flight `initialLoad` so concurrent callers coalesce into a single
    /// pass instead of double-fetching everything (Wave 2 · A4).
    private var initialLoadTask: Task<Void, Never>?

    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var toastMessage: String?
    @Published var toastIsError = false

    // Repository state
    @Published var isGitRepo = false
    @Published var currentBranch = ""
    @Published var commits: [GitCommit] = []
    @Published var branches: [GitBranch] = []
    @Published var tags: [GitTag] = []
    @Published var stashes: [GitStash] = []
    @Published var stagedFiles: [GitFileStatus] = []
    @Published var unstagedFiles: [GitFileStatus] = []

    /// Quantos commits a branch atual está à frente / atrás do upstream.
    /// `nil` enquanto carrega ou quando a branch não tem upstream
    /// configurado. Exibido na sidebar e injetado no contexto da IA.
    @Published var aheadBehind: (ahead: Int, behind: Int)?
    @Published var hasUpstream: Bool = false

    // Graph
    @Published var graphLines: [GitGraphLine] = []
    @Published var maxLaneCount: Int = 0

    // UI state
    @Published var selectedCommitId: String? {
        didSet {
            if selectedCommitId != oldValue {
                Task { await loadCommitDetail() }
            }
        }
    }
    @Published var selectedFilePath: String?
    @Published var selectedFileDiff: GitFileDiff?
    @Published var isShowingDiff = false
    @Published var commitMessage = ""
    @Published var searchQuery = ""

    // Commit detail panel
    @Published var commitDetail: GitCommitDetail?
    @Published var isLoadingDetail = false
    @Published var detailFileDiff: GitFileDiff?
    @Published var detailSelectedFile: String?

    // Lazy loading
    private var hasMoreCommits = true
    private var loadedCommitCount = 0
    private let batchSize = 200

    init(repoPath: String) {
        self.repoPath = repoPath
        self.service = GitService(repoPath: repoPath)
    }

    // MARK: - Lifecycle

    func onAppear() {
        Task { await initialLoad() }
        startAutoRefresh()
    }

    func onDisappear() {
        stopAutoRefresh()
    }

    private func startAutoRefresh() {
        // Defensive: invalidate any existing timer to avoid duplicate polling if
        // onAppear fires twice without a paired onDisappear (Wave 2 · #5 hardening).
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshStatus()
            }
        }
    }

    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// Repoints this view model at a different repository path. Used when the
    /// owning tab changes its `currentDirectory` — without this, the Git panel
    /// kept showing data from the original path because `service`/`repoPath`
    /// were captured once at init (Wave 1 · C2).
    /// - Parameter newPath: absolute path of the new repo (or non-repo) directory.
    func relocate(to newPath: String) async {
        guard newPath != repoPath else { return }

        initialLoadTask?.cancel()
        initialLoadTask = nil

        repoPath = newPath
        service = GitService(repoPath: newPath)

        // Wipe state from the old repo so the UI never blends data across paths.
        commits.removeAll()
        branches.removeAll()
        tags.removeAll()
        stashes.removeAll()
        stagedFiles.removeAll()
        unstagedFiles.removeAll()
        aheadBehind = nil
        hasUpstream = false
        graphLines.removeAll()
        maxLaneCount = 0
        currentBranch = ""
        commitDetail = nil
        detailFileDiff = nil
        detailSelectedFile = nil
        selectedCommitId = nil
        selectedFilePath = nil
        selectedFileDiff = nil
        commitMessage = ""
        searchQuery = ""
        stashDetailsCache.removeAll()
        hasMoreCommits = true
        loadedCommitCount = 0
        errorMessage = nil

        await initialLoad()
    }

    // MARK: - Initial Load

    func initialLoad() async {
        // Coalesce concurrent callers (e.g., onAppear + manual refresh) onto a
        // single in-flight load so we never double-fetch everything (Wave 2 · A4).
        if let inflight = initialLoadTask {
            await inflight.value
            return
        }

        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.performInitialLoad()
        }
        initialLoadTask = task
        await task.value
        initialLoadTask = nil
    }

    private func performInitialLoad() async {
        isLoading = true
        errorMessage = nil

        let isRepo = await service.isGitRepository()
        isGitRepo = isRepo

        guard isRepo else {
            // Wave 1 · A3: clear stash detail cache here too — when the path stops
            // being a repo, leaving cached entries by index can mislead later reuse.
            stashDetailsCache.removeAll()
            isLoading = false
            errorMessage = "Diretório não é um repositório Git"
            return
        }

        // Stash indices are positional (`stash@{n}`); after a refresh the same
        // index can point to a different stash. Drop the cache to force fresh
        // diffs (Wave 2 · A3).
        stashDetailsCache.removeAll()

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadCommits() }
            group.addTask { await self.loadBranches() }
            group.addTask { await self.loadTags() }
            group.addTask { await self.loadStashes() }
            group.addTask { await self.loadStatus() }
            group.addTask { await self.loadCurrentBranch() }
            group.addTask { await self.loadAheadBehind() }
        }

        isLoading = false
    }

    /// Atualiza `aheadBehind` consultando o upstream da branch atual.
    /// Roda em paralelo com o resto do `initialLoad` e em todo refresh leve.
    private func loadAheadBehind() async {
        let result = await service.aheadBehind()
        aheadBehind = result
        hasUpstream = result != nil
    }

    // MARK: - Data Loading

    private func loadCommits() async {
        do {
            let result = try await service.log(skip: 0, limit: batchSize)
            commits = result
            loadedCommitCount = result.count
            hasMoreCommits = result.count >= batchSize
            layoutGraph()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Wave 4 · M8: in-flight flag prevents duplicate `loadMoreCommits` calls
    /// from racing — multiple `.onAppear` events near the bottom of the list
    /// used to queue several fetches with the same `skip`, producing duplicate
    /// commits in the graph.
    private var isLoadingMore = false

    func loadMoreCommits() async {
        guard hasMoreCommits, !isLoading, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let more = try await service.log(skip: loadedCommitCount, limit: batchSize)
            commits.append(contentsOf: more)
            loadedCommitCount += more.count
            hasMoreCommits = more.count >= batchSize
            layoutGraph()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadBranches() async {
        do { branches = try await service.branches() }
        catch {
            // Wave 5 · M5: surface error so the user knows branches failed
            // to load (sidebar stays empty otherwise without explanation).
            showToast("Falha ao carregar branches: \(error.localizedDescription)", isError: true)
        }
    }

    private func loadTags() async {
        do { tags = try await service.tags() }
        catch {
            showToast("Falha ao carregar tags: \(error.localizedDescription)", isError: true)
        }
    }

    private func loadStashes() async {
        do { stashes = try await service.stashes() }
        catch {
            showToast("Falha ao carregar stashes: \(error.localizedDescription)", isError: true)
        }
    }

    private func loadStatus() async {
        do {
            let s = try await service.status()
            stagedFiles = s.staged
            unstagedFiles = s.unstaged
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadCurrentBranch() async {
        do { currentBranch = try await service.currentBranch() }
        catch {
            // Wave 5 · M5: keep this one silent — detached HEAD legitimately
            // makes `rev-parse --abbrev-ref HEAD` return `HEAD`, which the
            // service may surface as an error in some edge cases. Toasting
            // here on every refresh would spam the user.
            currentBranch = ""
        }
    }

    // MARK: - Refresh

    func refreshAll() async {
        await initialLoad()
    }

    func refreshStatus() async {
        await loadStatus()
        await loadCurrentBranch()
        await loadAheadBehind()
    }

    // MARK: - Graph Layout

    private func layoutGraph() {
        let engine = GitGraphLayoutEngine()
        let result = engine.layout(commits: commits)
        commits = result.commits
        graphLines = result.lines
        maxLaneCount = result.maxLanes
    }

    // MARK: - Stage / Unstage

    func stageFiles(_ files: [GitFileStatus]) async {
        do {
            try await service.stage(files: files.map(\.path))
            await refreshStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stagePaths(_ paths: [String]) async {
        guard !paths.isEmpty else { return }
        do {
            try await service.stage(files: paths)
            await refreshStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stageAll() async {
        do {
            try await service.stageAll()
            await refreshStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unstageFiles(_ files: [GitFileStatus]) async {
        do {
            try await service.unstage(files: files.map(\.path))
            await refreshStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unstagePaths(_ paths: [String]) async {
        guard !paths.isEmpty else { return }
        do {
            try await service.unstage(files: paths)
            await refreshStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unstageAll() async {
        do {
            try await service.unstageAll()
            await refreshStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Commit

    func commitChanges() async {
        guard !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showToast("Mensagem de commit vazia", isError: true)
            return
        }
        do {
            try await service.commit(message: commitMessage)
            let msg = commitMessage
            commitMessage = ""
            await refreshAll()
            showToast("Commit criado: \(msg.prefix(40))")
        } catch {
            showToast("Falha no commit: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Push / Pull

    func push() async {
        // Push em branch protegida pede confirmação extra — protege contra
        // push direto acidental em main/master/develop/production.
        if GitProtectedBranches.isProtected(currentBranch), !currentBranch.isEmpty {
            confirmDestructive(.pushToProtected(branch: currentBranch)) { [weak self] in
                await self?.performPush()
            }
            return
        }
        await performPush()
    }

    private func performPush() async {
        do {
            try await service.push()
            await refreshAll()
            showToast("Push realizado com sucesso")
        } catch {
            showToast("Push falhou: \(error.localizedDescription)", isError: true)
        }
    }

    func pull() async {
        do {
            try await service.pull()
            await refreshAll()
            showToast("Pull realizado com sucesso")
        } catch {
            showToast("Pull falhou: \(error.localizedDescription)", isError: true)
        }
    }

    func pullRebase() async {
        do {
            try await service.pullRebase()
            await refreshAll()
            showToast("Pull --rebase concluído")
        } catch {
            showToast("Pull --rebase falhou: \(error.localizedDescription)", isError: true)
        }
    }

    /// Fetch puro (não mexe no working tree). Útil para atualizar
    /// ahead/behind sem disparar conflito.
    func fetch(prune: Bool = true) async {
        do {
            try await service.fetch(prune: prune)
            await refreshAll()
            showToast(prune ? "Fetch + prune concluído" : "Fetch concluído")
        } catch {
            showToast("Fetch falhou: \(error.localizedDescription)", isError: true)
        }
    }

    /// `git init` no diretório atual quando ainda não é repo. Após sucesso
    /// reexecuta o `initialLoad` para que toda a UI se reposicione.
    func initRepo(initialBranch: String = "main") async {
        do {
            _ = try await service.initRepo(initialBranch: initialBranch)
            await initialLoad()
            showToast("Repositório inicializado em \(initialBranch)")
        } catch {
            showToast("git init falhou: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Branch

    func checkoutBranch(_ name: String) async {
        do {
            try await service.checkout(branch: name)
            await refreshAll()
            showToast("Checkout: \(name)")
        } catch {
            showToast("Checkout falhou: \(error.localizedDescription)", isError: true)
        }
    }

    func checkoutTag(_ name: String) async {
        do {
            try await service.checkout(branch: name)
            await refreshAll()
            showToast("Checkout tag: \(name)")
        } catch {
            showToast("Checkout falhou: \(error.localizedDescription)", isError: true)
        }
    }

    func createBranch(_ name: String) async {
        do {
            try await service.createBranch(name: name)
            await refreshAll()
            showToast("Branch criada: \(name)")
        } catch {
            showToast("Falha ao criar branch: \(error.localizedDescription)", isError: true)
        }
    }

    func deleteBranch(_ name: String, force: Bool = false) async {
        if force {
            confirmDestructive(.forceDeleteBranch(name: name)) { [weak self] in
                await self?.performDeleteBranch(name, force: true)
            }
            return
        }
        await performDeleteBranch(name, force: false)
    }

    private func performDeleteBranch(_ name: String, force: Bool) async {
        do {
            try await service.deleteBranch(name: name, force: force)
            await refreshAll()
            showToast("Branch deletada: \(name)")
        } catch {
            showToast("Falha ao deletar: \(error.localizedDescription)", isError: true)
        }
    }

    func mergeBranch(_ name: String) async {
        do {
            try await service.merge(branch: name)
            await refreshAll()
            showToast("Merge de \(name) concluído")
        } catch {
            showToast("Merge falhou: \(error.localizedDescription)", isError: true)
        }
    }

    func rebaseBranch(_ name: String) async {
        do {
            try await service.rebase(onto: name)
            await refreshAll()
            showToast("Rebase em \(name) concluído")
        } catch {
            showToast("Rebase falhou: \(error.localizedDescription)", isError: true)
        }
    }

    func rebaseAbort() async {
        do {
            try await service.rebaseAbort()
            await refreshAll()
            showToast("Rebase abortado")
        } catch {
            showToast("Abort falhou: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Stash

    func stashSave(_ message: String? = nil) async {
        do {
            try await service.stashSave(message: message)
            await refreshAll()
            showToast("Stash salvo")
        } catch {
            showToast("Stash falhou: \(error.localizedDescription)", isError: true)
        }
    }

    func stashPop(_ index: Int = 0) async {
        do {
            try await service.stashPop(index: index)
            await refreshAll()
            showToast("Stash aplicado")
        } catch {
            showToast("Stash pop falhou: \(error.localizedDescription)", isError: true)
        }
    }

    func stashDrop(_ index: Int) async {
        do {
            try await service.stashDrop(index: index)
            await refreshAll()
            showToast("Stash removido")
        } catch {
            showToast("Stash drop falhou: \(error.localizedDescription)", isError: true)
        }
    }

    // Cache of stash details so the sidebar's expandable rows don't re-shell
    // every time the user toggles a row open/closed.
    @Published var stashDetailsCache: [Int: GitStashDetails] = [:]
    @Published var loadingStashDetails: Set<Int> = []

    func loadStashDetails(_ index: Int, force: Bool = false) async {
        if !force, stashDetailsCache[index] != nil { return }
        loadingStashDetails.insert(index)
        defer { loadingStashDetails.remove(index) }
        do {
            let details = try await service.stashShow(index: index)
            stashDetailsCache[index] = details
        } catch {
            showToast("Falha ao carregar stash: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Hygiene (used by GitBranchHygieneView)

    /// Wrapper that exposes service.mergedBranches without needing the view
    /// to talk to the actor directly.
    func mergedBranchesList(target: String) async throws -> [String] {
        try await service.mergedBranches(into: target)
    }

    /// Wrapper that exposes service.branchesByAge.
    func branchAgeList() async throws -> [GitService.BranchAge] {
        try await service.branchesByAge()
    }

    /// Direct delete used by the bulk hygiene flow. Bypasses the destructive
    /// confirm sheet because the sheet/list itself is the confirmation step.
    /// Throws so the bulk loop can count successes/failures.
    func deleteBranchDirect(_ name: String) async throws {
        try await service.deleteBranch(name: name, force: false)
    }

    // MARK: - Tags

    func createTag(name: String, message: String? = nil) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            showToast("Nome da tag vazio", isError: true)
            return
        }
        if tags.contains(where: { $0.name == trimmed }) {
            showToast("Tag '\(trimmed)' já existe", isError: true)
            return
        }
        do {
            try await service.createTag(name: trimmed, message: message)
            await refreshAll()
            showToast("Tag criada: \(trimmed)")
        } catch {
            showToast("Falha ao criar tag: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Performance Diagnostic

    @Published var perfReport: GitPerfReport?
    @Published var isRunningPerf: Bool = false

    func runPerformanceAnalysis() async {
        isRunningPerf = true
        defer { isRunningPerf = false }
        do {
            perfReport = try await service.runPerformance()
        } catch {
            showToast("Análise falhou: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Revert / Reset / Cherry-pick

    func revertCommit(_ hash: String) async {
        do {
            try await service.revert(commitHash: hash)
            await refreshAll()
            showToast("Revert do commit \(hash.prefix(7)) concluído")
        } catch {
            showToast("Revert falhou: \(error.localizedDescription)", isError: true)
        }
    }

    func resetHard(to hash: String) async {
        let dirty = !stagedFiles.isEmpty || !unstagedFiles.isEmpty
        confirmDestructive(.resetHard(commitHash: hash, hasDirtyTree: dirty)) { [weak self] in
            await self?.performResetHard(to: hash)
        }
    }

    private func performResetHard(to hash: String) async {
        do {
            try await service.resetHard(to: hash)
            await refreshAll()
            showToast("Hard reset para \(hash.prefix(7)) concluído")
        } catch {
            showToast("Hard reset falhou: \(error.localizedDescription)", isError: true)
        }
    }

    func resetSoft(to hash: String) async {
        do {
            try await service.resetSoft(to: hash)
            await refreshAll()
            showToast("Soft reset para \(hash.prefix(7)) concluído")
        } catch {
            showToast("Soft reset falhou: \(error.localizedDescription)", isError: true)
        }
    }

    func resetMixed(to hash: String) async {
        do {
            try await service.resetMixed(to: hash)
            await refreshAll()
            showToast("Reset para \(hash.prefix(7)) concluído")
        } catch {
            showToast("Reset falhou: \(error.localizedDescription)", isError: true)
        }
    }

    func cherryPick(_ hash: String) async {
        do {
            try await service.cherryPick(commitHash: hash)
            await refreshAll()
            showToast("Cherry-pick de \(hash.prefix(7)) concluído")
        } catch {
            showToast("Cherry-pick falhou: \(error.localizedDescription)", isError: true)
        }
    }

    // Wave 5 · M6: previously had a duplicate `createTag(_:message:)` here that
    // skipped the empty/duplicate-name validations of `createTag(name:message:)`.
    // Removed in favour of the validated version above; callers updated.

    // MARK: - AI Commit Message

    @Published var isGeneratingMessage = false
    @Published var isCommitPushing = false

    // MARK: - Safety (destructive confirmations)

    /// Ação destrutiva esperando confirmação do usuário. Quando não-nil,
    /// `GitTabView` mostra `GitDestructiveConfirmSheet`. O closure
    /// `pendingDestructiveExecute` carrega a operação real a executar
    /// quando o usuário confirma.
    @Published var pendingDestructive: GitDestructiveAction?
    private var pendingDestructiveExecute: (() async -> Void)?

    private func confirmDestructive(
        _ action: GitDestructiveAction,
        execute: @escaping () async -> Void
    ) {
        pendingDestructive = action
        pendingDestructiveExecute = execute
    }

    func confirmPendingDestructive() {
        let exec = pendingDestructiveExecute
        pendingDestructive = nil
        pendingDestructiveExecute = nil
        Task { await exec?() }
    }

    func cancelPendingDestructive() {
        pendingDestructive = nil
        pendingDestructiveExecute = nil
    }

    func generateCommitMessage(router: ModelRouter, provider: ProviderType, model: String) async {
        guard !stagedFiles.isEmpty else {
            showToast("Nenhum arquivo staged para gerar mensagem", isError: true)
            return
        }

        isGeneratingMessage = true
        defer { isGeneratingMessage = false }

        do {
            let diffSummary = try await service.stagedDiffSummary()
            let fileList = stagedFiles.map { "\($0.status.rawValue) \($0.path)" }.joined(separator: "\n")

            let prompt = """
            Analyze the following git staged changes and generate a concise, professional commit message.
            Follow the Conventional Commits format: type(scope): description
            Types: feat, fix, refactor, docs, style, test, chore, perf, ci, build
            Keep the first line under 72 characters.
            If needed, add a blank line then a brief body (max 2-3 lines).
            Return ONLY the commit message, nothing else. No markdown, no quotes, no explanation.

            Staged files:
            \(fileList)

            \(diffSummary)
            """

            let messages: [[String: String]] = [
                ["role": "system", "content": "You are a git commit message generator. Output only the commit message text, nothing else."],
                ["role": "user", "content": prompt]
            ]

            let llm = router.provider(for: provider, model: model)
            let response = try await llm.sendRaw(messages: messages)
            let cleaned = response
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            commitMessage = cleaned
            showToast("Mensagem gerada com IA")
        } catch {
            showToast("Falha ao gerar mensagem: \(error.localizedDescription)", isError: true)
        }
    }

    func commitAndPush() async {
        guard !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showToast("Mensagem de commit vazia", isError: true)
            return
        }
        guard !stagedFiles.isEmpty else {
            showToast("Nenhum arquivo staged", isError: true)
            return
        }

        // Confirma antes em branch protegida — o commit + push acontece dentro
        // do execute do confirm para garantir atomicidade UX.
        if GitProtectedBranches.isProtected(currentBranch), !currentBranch.isEmpty {
            confirmDestructive(.pushToProtected(branch: currentBranch)) { [weak self] in
                await self?.performCommitAndPush()
            }
            return
        }
        await performCommitAndPush()
    }

    private func performCommitAndPush() async {
        isCommitPushing = true
        defer { isCommitPushing = false }

        do {
            try await service.commit(message: commitMessage)
            let msg = commitMessage
            commitMessage = ""
            showToast("Commit: \(msg.prefix(40))")

            try await service.push()
            await refreshAll()
            showToast("Commit + Push concluído com sucesso")
        } catch {
            await refreshAll()
            showToast("Erro: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Diff

    func loadDiff(for file: GitFileStatus, staged: Bool) async {
        do {
            selectedFilePath = file.path
            selectedFileDiff = try await service.diffForFile(file.path, staged: staged)
            isShowingDiff = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func closeDiff() {
        isShowingDiff = false
        selectedFileDiff = nil
        selectedFilePath = nil
    }

    // MARK: - Commit Detail

    /// Wave 3 · A5: monotonic generation counter so we can discard stale results
    /// when the user clicks rapidly through the commit list. Without this, the
    /// last `loadCommitDetail` to *finish* (not start) would win, sometimes
    /// showing the previous commit's diff for the currently-selected one.
    private var commitDetailGeneration: Int = 0
    private var detailFileDiffGeneration: Int = 0

    func loadCommitDetail() async {
        guard let hash = selectedCommitId else {
            commitDetail = nil
            detailFileDiff = nil
            detailSelectedFile = nil
            return
        }

        commitDetailGeneration &+= 1
        let myGen = commitDetailGeneration

        isLoadingDetail = true
        detailFileDiff = nil
        detailSelectedFile = nil

        do {
            let detail = try await service.commitDetail(hash: hash)
            // Drop result if a newer selection happened meanwhile.
            guard myGen == commitDetailGeneration else { return }
            commitDetail = detail
        } catch {
            guard myGen == commitDetailGeneration else { return }
            commitDetail = nil
            // Wave 5 · M5: surface error so the user knows the diff failed,
            // instead of silently showing an empty panel.
            showToast("Falha ao carregar commit: \(error.localizedDescription)", isError: true)
        }

        if myGen == commitDetailGeneration {
            isLoadingDetail = false
        }
    }

    func loadDetailFileDiff(hash: String, path: String) async {
        detailFileDiffGeneration &+= 1
        let myGen = detailFileDiffGeneration
        detailSelectedFile = path
        do {
            let diff = try await service.commitDiffForFile(hash: hash, path: path)
            guard myGen == detailFileDiffGeneration else { return }
            detailFileDiff = diff
        } catch {
            guard myGen == detailFileDiffGeneration else { return }
            detailFileDiff = nil
        }
    }

    func closeDetailDiff() {
        detailFileDiff = nil
        detailSelectedFile = nil
    }

    // MARK: - Toast

    private func showToast(_ message: String, isError: Bool = false) {
        toastMessage = message
        toastIsError = isError

        // Erros longos (>80 chars) ficam persistentes para dar tempo de
        // copiar e compartilhar. Auto-dismiss permanece para sucesso (2.5s)
        // e erros curtos (60s — antes 4s).
        let isLong = isError && message.count > 80
        if isLong { return }

        Task {
            try? await Task.sleep(nanoseconds: isError ? 60_000_000_000 : 2_500_000_000)
            if toastMessage == message {
                toastMessage = nil
            }
        }
    }

    func dismissToast() {
        toastMessage = nil
    }

    // MARK: - Filtering

    var filteredCommits: [GitCommit] {
        guard !searchQuery.isEmpty else { return commits }
        let q = searchQuery.lowercased()
        return commits.filter {
            $0.subject.lowercased().contains(q) ||
            $0.authorName.lowercased().contains(q) ||
            $0.shortHash.lowercased().contains(q) ||
            $0.branches.contains(where: { $0.lowercased().contains(q) }) ||
            $0.tags.contains(where: { $0.lowercased().contains(q) })
        }
    }

    /// Wave 4 · M9: pagination helper that handles both unfiltered and filtered
    /// states. With an active search query, the filtered list can be very small
    /// while the underlying history still has thousands of unloaded commits —
    /// the `count - 10` heuristic in the view never fires there. This helper:
    ///   - normalises the trigger to "near the end of what's visible";
    ///   - eagerly fetches more pages while the filter is active and there are
    ///     still candidates upstream, until either the result set grows or we
    ///     run out of history.
    func loadMoreIfNeeded(viewedIndex: Int) async {
        guard hasMoreCommits, !isLoading, !isLoadingMore else { return }
        let visibleCount = filteredCommits.count
        let nearEnd = viewedIndex >= max(0, visibleCount - 10)
        if !nearEnd && !searchQuery.isEmpty {
            return
        }
        await loadMoreCommits()
        // While searching, a single batch may not yield a single match. Keep
        // pulling in the background (cap at a sensible number of batches per
        // tap to avoid runaway requests).
        if !searchQuery.isEmpty {
            var extraBatches = 0
            while !Task.isCancelled,
                  hasMoreCommits,
                  filteredCommits.count == visibleCount,
                  extraBatches < 5 {
                await loadMoreCommits()
                extraBatches += 1
            }
        }
    }

    var localBranches: [GitBranch] {
        branches.filter { !$0.isRemote }
    }

    var remoteBranches: [GitBranch] {
        branches.filter { $0.isRemote }
    }
}
