import SwiftUI
import Combine

@MainActor
class GitViewModel: ObservableObject {
    let repoPath: String
    private let service: GitService
    private var refreshTimer: Timer?

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

    // MARK: - Initial Load

    func initialLoad() async {
        isLoading = true
        errorMessage = nil

        let isRepo = await service.isGitRepository()
        isGitRepo = isRepo

        guard isRepo else {
            isLoading = false
            errorMessage = "Diretório não é um repositório Git"
            return
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadCommits() }
            group.addTask { await self.loadBranches() }
            group.addTask { await self.loadTags() }
            group.addTask { await self.loadStashes() }
            group.addTask { await self.loadStatus() }
            group.addTask { await self.loadCurrentBranch() }
        }

        isLoading = false
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

    func loadMoreCommits() async {
        guard hasMoreCommits, !isLoading else { return }
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
        catch { /* non-critical */ }
    }

    private func loadTags() async {
        do { tags = try await service.tags() }
        catch { /* non-critical */ }
    }

    private func loadStashes() async {
        do { stashes = try await service.stashes() }
        catch { /* non-critical */ }
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
        catch { /* non-critical */ }
    }

    // MARK: - Refresh

    func refreshAll() async {
        await initialLoad()
    }

    func refreshStatus() async {
        await loadStatus()
        await loadCurrentBranch()
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

    func createTag(_ name: String, message: String? = nil) async {
        do {
            try await service.createTag(name: name, message: message)
            await refreshAll()
            showToast("Tag criada: \(name)")
        } catch {
            showToast("Tag falhou: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - AI Commit Message

    @Published var isGeneratingMessage = false
    @Published var isCommitPushing = false

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

    func loadCommitDetail() async {
        guard let hash = selectedCommitId else {
            commitDetail = nil
            detailFileDiff = nil
            detailSelectedFile = nil
            return
        }

        isLoadingDetail = true
        detailFileDiff = nil
        detailSelectedFile = nil

        do {
            commitDetail = try await service.commitDetail(hash: hash)
        } catch {
            commitDetail = nil
        }

        isLoadingDetail = false
    }

    func loadDetailFileDiff(hash: String, path: String) async {
        detailSelectedFile = path
        do {
            detailFileDiff = try await service.commitDiffForFile(hash: hash, path: path)
        } catch {
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
        Task {
            try? await Task.sleep(nanoseconds: isError ? 4_000_000_000 : 2_500_000_000)
            if toastMessage == message {
                toastMessage = nil
            }
        }
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

    var localBranches: [GitBranch] {
        branches.filter { !$0.isRemote }
    }

    var remoteBranches: [GitBranch] {
        branches.filter { $0.isRemote }
    }
}
