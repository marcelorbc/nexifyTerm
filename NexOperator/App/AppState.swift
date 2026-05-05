import SwiftUI
import Combine
import WidgetKit

@MainActor
class AppState: ObservableObject {
    @Published var tabs: [TerminalTab] = []
    @Published var activeTabId: UUID?
    @Published var isShowingSettings = false
    @Published var isLoading = false

    @Published var history: [HistoryEntry] = []
    @Published var isShowingHistory: Bool {
        didSet { NexPersistence.shared.setFlag("historyPanelOpen", value: isShowingHistory) }
    }

    @Published var isShowingFileBrowser: Bool {
        didSet { NexPersistence.shared.setFlag("fileBrowserOpen", value: isShowingFileBrowser) }
    }

    @Published var isShowingGlobalSearch = false

    @Published var tabStateVersion = 0

    /// Plano dry-run aguardando aprovação do usuário (Phase 1 · Trust).
    @Published var pendingDryRunPlan: ExecutionPlan?
    @Published var isShowingDryRunPreview = false
    /// Continuation que destrava o agent quando o usuário decide.
    var dryRunDecisionContinuation: CheckedContinuation<DryRunDecision, Never>?

    private var tabAgentStates: [UUID: TabAgentState] = [:]
    private var gitViewModels: [UUID: GitViewModel] = [:]
    /// Wave 6 · A9: tracks which mosaic pane is currently in focus per tab.
    /// The key is `tab.id`, the value is `paneId`. When the user taps inside a
    /// pane the agent (and any future per-pane action) will route to that pane
    /// instead of falling back to the tab-wide session.
    @Published private(set) var focusedMosaicPaneIds: [UUID: UUID] = [:]
    private let historyStore = HistoryStore.shared

    let configStore = ConfigStore.shared
    let sessionManager = TerminalSessionManager()
    private let commandGuard = CommandGuard()

    init() {
        self.isShowingHistory = NexPersistence.shared.getFlag("historyPanelOpen")
        self.isShowingFileBrowser = NexPersistence.shared.getFlag("fileBrowserOpen")
        history = historyStore.load()

        if !restoreSession() {
            addExplorerTab(directory: FileManager.default.homeDirectoryForCurrentUser.path)
        }
        startMCPServers()
        warmSystemProfile()
        refreshProviderAvailability()
        if !history.isEmpty {
            HistoryAnalyzer.shared.scheduleAnalysis(entries: history, delay: 5.0)
        }
    }

    func refreshProviderAvailability() {
        Task { @MainActor in
            await ProviderAvailabilityService.shared.refresh()
            let avail = ProviderAvailabilityService.shared
            if avail.hasChecked,
               let best = avail.bestAvailableProvider(),
               !avail.availableProviders.contains(configStore.defaultProvider) {
                configStore.defaultProvider = best
                for i in tabs.indices {
                    tabs[i].provider = best
                    let models = avail.availableModels(for: best)
                    tabs[i].model = models.first ?? best.defaultModel
                }
                notifyTabStateChanged()
            }
        }
    }

    /// Kicks off (in the background) the collection of hardware/OS/installed
    /// software so the next agent prompt already has it. Refresh runs only when
    /// the cache is missing or older than `staleAfter` (3 days).
    private func warmSystemProfile() {
        guard configStore.systemProfileEnabled else { return }
        SystemProfileService.shared.refresh()
    }

    private func startMCPServers() {
        let servers = configStore.mcpServers
        if !servers.isEmpty {
            Task { @MainActor in
                MCPManager.shared.startServers(servers)
            }
        }
    }

    // MARK: - Session Persistence

    func saveSession() {
        // Wave 5 · A8: mosaic layouts now round-trip via Codable on `MosaicNode`,
        // so we no longer drop them on save.
        let savedTabs = tabs.map { SavedTab(from: $0) }
        guard !savedTabs.isEmpty else { return }
        let activeIndex = tabs.firstIndex(where: { $0.id == activeTabId })
        // Wave 3 · A7: persist activeTabId so the right tab is restored even when
        // some tabs are filtered out during restore (e.g., deleted directory).
        NexPersistence.shared.saveTabs(
            savedTabs,
            activeTabIndex: activeIndex,
            activeTabId: activeTabId
        )
    }

    @discardableResult
    private func restoreSession() -> Bool {
        guard let session = NexPersistence.shared.loadTabs(),
              !session.tabs.isEmpty else { return false }

        let validTabs = session.tabs.filter { saved in
            let dir = saved.currentDirectory
            return FileManager.default.fileExists(atPath: dir)
        }
        guard !validTabs.isEmpty else { return false }

        for saved in validTabs {
            let tab = saved.toTerminalTab()
            tabs.append(tab)
            // Wave 6 · A9: seed mosaic focus from the restored layout so the
            // user lands with a focused pane (matches addMosaicTab behaviour).
            if let layout = tab.mosaicLayout, let first = layout.allPaneIds.first {
                focusedMosaicPaneIds[tab.id] = first
            }
        }

        // Wave 3 · A7: prefer activeTabId (resilient to filtering); only fall
        // back to the saved index for sessions written by older builds.
        if let savedActive = session.activeTabId,
           tabs.contains(where: { $0.id == savedActive }) {
            activeTabId = savedActive
        } else if let idx = session.activeTabIndex, idx >= 0, idx < tabs.count {
            activeTabId = tabs[idx].id
        } else {
            activeTabId = tabs.first?.id
        }
        return true
    }

    private func appendHistory(_ entry: HistoryEntry) {
        history.append(entry)
        historyStore.save(history)
        // Auto-analyze (debounced) so the personalization panel always shows
        // up-to-date insights without blocking the active conversation.
        HistoryAnalyzer.shared.scheduleAnalysis(entries: history)
        // Auto-title the conversation (ChatGPT-style) for the originating tab.
        if let tabId = entry.tabId, entry.type == .agentPlan {
            ConversationTitler.shared.updateTitleIfNeeded(for: tabId, entries: history)
        }
    }

    var modelRouter: ModelRouter {
        ModelRouter(configStore: configStore)
    }

    // MARK: - Per-tab agent state

    func agentState(for tabId: UUID) -> TabAgentState {
        if let existing = tabAgentStates[tabId] { return existing }
        let state = TabAgentState()
        tabAgentStates[tabId] = state
        return state
    }

    /// Clears the conversation memory for the active tab. Use this when the user
    /// wants a fresh start without past turns biasing the LLM.
    func clearActiveTabConversation() {
        activeAgentState?.clearConversation()
        notifyTabStateChanged()
    }

    var activeAgentState: TabAgentState? {
        guard let id = activeTabId else { return nil }
        return agentState(for: id)
    }

    private func notifyTabStateChanged() {
        tabStateVersion += 1
        pushWidgetData()
    }

    private func pushWidgetData() {
        SharedDefaults.updateActiveTabs(tabs, activeId: activeTabId)
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Convenience accessors for active tab

    var isAgentRunning: Bool { activeAgentState?.isAgentRunning ?? false }
    var lastRichOutput: RichOutput? { activeAgentState?.lastRichOutput }
    var agentStartTime: Date? { activeAgentState?.startTime }
    var agentElapsedTime: TimeInterval? {
        guard let start = activeAgentState?.startTime else { return nil }
        let end = activeAgentState?.endTime ?? Date()
        return end.timeIntervalSince(start)
    }
    var browserURL: URL? {
        get { activeAgentState?.browserURL }
        set { activeAgentState?.browserURL = newValue; notifyTabStateChanged() }
    }

    func openBrowser(_ url: URL) {
        activeAgentState?.browserURL = url
        notifyTabStateChanged()
    }

    func closeBrowser() {
        activeAgentState?.browserURL = nil
        notifyTabStateChanged()
    }
    var agentStatus: String? {
        get { activeAgentState?.agentStatus }
        set { activeAgentState?.agentStatus = newValue; notifyTabStateChanged() }
    }
    var agentResults: [StepResult] {
        get { activeAgentState?.agentResults ?? [] }
        set { activeAgentState?.agentResults = newValue; notifyTabStateChanged() }
    }
    var errorMessage: String? {
        get { activeAgentState?.errorMessage }
        set { activeAgentState?.errorMessage = newValue; notifyTabStateChanged() }
    }
    var isShowingPlanPreview: Bool {
        get { activeAgentState?.isShowingPlanPreview ?? false }
        set { activeAgentState?.isShowingPlanPreview = newValue; notifyTabStateChanged() }
    }
    var previewPlan: AgentPlan? { activeAgentState?.previewPlan }
    var isShowingApproval: Bool {
        get { activeAgentState?.isShowingApproval ?? false }
        set { activeAgentState?.isShowingApproval = newValue; notifyTabStateChanged() }
    }
    var currentPlan: AgentPlan? { activeAgentState?.currentPlan }
    var runningPlan: AgentPlan? { activeAgentState?.runningPlan }
    var runningPlanRound: Int { activeAgentState?.runningPlanRound ?? 0 }
    var thinkingPhase: String? { activeAgentState?.thinkingPhase }
    var thinkingDetails: [String] { activeAgentState?.thinkingDetails ?? [] }
    var streamingText: String? { activeAgentState?.streamingText }
    var pendingToolInstall: ToolInstallRequest? { activeAgentState?.pendingToolInstall }
    var isShowingToolInstall: Bool {
        get { activeAgentState?.isShowingToolInstall ?? false }
        set { activeAgentState?.isShowingToolInstall = newValue; notifyTabStateChanged() }
    }
    var pendingSudoRequest: SudoPasswordRequest? { activeAgentState?.pendingSudoRequest }
    var isShowingSudoPrompt: Bool {
        get { activeAgentState?.isShowingSudoPrompt ?? false }
        set { activeAgentState?.isShowingSudoPrompt = newValue; notifyTabStateChanged() }
    }

    // MARK: - Tab Management

    @Published var isShowingDirectoryPicker = false
    private var pendingTabDirectory: String?

    func addTab() {
        if configStore.askDirectoryOnNewTab {
            isShowingDirectoryPicker = true
        } else {
            createTab(directory: configStore.defaultDirectory)
        }
    }

    func createTab(directory: String) {
        let tab = TerminalTab(
            title: "Terminal \(tabs.count + 1)",
            currentDirectory: directory,
            provider: configStore.defaultProvider,
            model: configStore.modelForProvider(configStore.defaultProvider),
            approvalMode: configStore.defaultApprovalMode
        )
        tabs.append(tab)
        activeTabId = tab.id
        RecentDirectoriesStore.shared.add(directory)
        // Wave 3 · A2: parity with addExplorerTab/addGitTab/addMosaicTab — keep
        // sidebar/topbar/widget consistent the moment a new terminal tab opens.
        notifyTabStateChanged()
    }

    func addExplorerTab(directory: String? = nil) {
        let dir = directory ?? configStore.defaultDirectory
        let folderName = URL(fileURLWithPath: dir).lastPathComponent
        let tab = TerminalTab(
            title: folderName,
            currentDirectory: dir,
            provider: configStore.defaultProvider,
            model: configStore.modelForProvider(configStore.defaultProvider),
            approvalMode: configStore.defaultApprovalMode,
            tabMode: .explorer
        )
        tabs.append(tab)
        activeTabId = tab.id
        RecentDirectoriesStore.shared.add(dir)
        notifyTabStateChanged()
    }

    func addGitTab(directory: String? = nil) {
        let dir = directory ?? configStore.defaultDirectory
        let folderName = URL(fileURLWithPath: dir).lastPathComponent
        let tab = TerminalTab(
            title: "Git: \(folderName)",
            currentDirectory: dir,
            provider: configStore.defaultProvider,
            model: configStore.modelForProvider(configStore.defaultProvider),
            approvalMode: configStore.defaultApprovalMode,
            tabMode: .git
        )
        tabs.append(tab)
        activeTabId = tab.id
        notifyTabStateChanged()
    }

    func addDiskAnalyzerTab(directory: String? = nil) {
        let dir = directory ?? configStore.defaultDirectory
        let folderName = URL(fileURLWithPath: dir).lastPathComponent
        let tab = TerminalTab(
            title: "Disco: \(folderName)",
            currentDirectory: dir,
            provider: configStore.defaultProvider,
            model: configStore.modelForProvider(configStore.defaultProvider),
            approvalMode: configStore.defaultApprovalMode,
            tabMode: .diskAnalyzer
        )
        tabs.append(tab)
        activeTabId = tab.id
        RecentDirectoriesStore.shared.add(dir)
        notifyTabStateChanged()
    }

    // MARK: - Mosaic focus (Wave 6 · A9)

    /// Sets the focused pane for a mosaic tab. Called by `MosaicPaneView` on tap
    /// or when a pane gets a primary interaction. Triggers a state notification
    /// so the focus ring updates everywhere.
    func setFocusedPane(_ paneId: UUID, in tabId: UUID) {
        guard focusedMosaicPaneIds[tabId] != paneId else { return }
        focusedMosaicPaneIds[tabId] = paneId
        notifyTabStateChanged()
    }

    /// Returns the currently-focused pane for the given mosaic tab, or `nil` if
    /// none is set yet (caller should pick a sensible default — usually the
    /// first pane in the layout).
    func focusedPane(in tabId: UUID) -> UUID? {
        focusedMosaicPaneIds[tabId]
    }

    /// Resolves the terminal session that the agent (or other code) should
    /// target for the given tab. For non-mosaic tabs this is just the tab's own
    /// session. For mosaic tabs we look up the focused pane's content; if it
    /// resolves to a `.terminal` we use that pane's `sessionId`. Otherwise we
    /// fall back to the tab session so the agent still has somewhere to echo.
    func effectiveSessionId(for tab: TerminalTab) -> UUID {
        guard tab.tabMode == .mosaic, let layout = tab.mosaicLayout else {
            return tab.id
        }
        let candidate = focusedMosaicPaneIds[tab.id] ?? layout.allPaneIds.first
        guard let paneId = candidate,
              let content = Self.findPaneContent(paneId, in: layout) else {
            return tab.id
        }
        if case .terminal(let sessionId) = content {
            return sessionId
        }
        // Pane is an explorer — there's no PTY to echo into, so reuse the tab
        // session (which `AgentExecutor`'s `echoAgentCommand` will spawn lazily
        // if needed).
        return tab.id
    }

    private static func findPaneContent(_ paneId: UUID, in node: MosaicNode) -> PaneContent? {
        switch node {
        case .pane(let id, let content):
            return id == paneId ? content : nil
        case .split(_, _, _, let first, let second):
            return findPaneContent(paneId, in: first) ?? findPaneContent(paneId, in: second)
        }
    }

    func gitViewModel(for tabId: UUID) -> GitViewModel {
        let dir = tabs.first(where: { $0.id == tabId })?.currentDirectory
            ?? configStore.defaultDirectory
        if let existing = gitViewModels[tabId] {
            // Wave 1 · C2: if the tab navigated to another directory, the same
            // GitViewModel instance must follow it. Otherwise the panel keeps
            // showing data from the original repo path.
            if existing.repoPath != dir {
                Task { await existing.relocate(to: dir) }
            }
            return existing
        }
        let vm = GitViewModel(repoPath: dir)
        gitViewModels[tabId] = vm
        return vm
    }

    func addMosaicTab(layout: MosaicNode, title: String = "Mosaico") {
        let tab = TerminalTab(
            title: title,
            currentDirectory: configStore.defaultDirectory,
            provider: configStore.defaultProvider,
            model: configStore.modelForProvider(configStore.defaultProvider),
            approvalMode: configStore.defaultApprovalMode,
            tabMode: .mosaic,
            mosaicLayout: layout
        )
        tabs.append(tab)
        activeTabId = tab.id
        // Wave 6 · A9: seed the focus to the first pane so the agent and the
        // visual indicator have a sensible default before the user clicks.
        if let firstPane = layout.allPaneIds.first {
            focusedMosaicPaneIds[tab.id] = firstPane
        }
        notifyTabStateChanged()
    }

    func updateMosaicLayout(tabId: UUID, layout: MosaicNode) {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let oldSessionIds = tabs[index].mosaicLayout?.allTerminalSessionIds ?? []
        let newSessionIds = layout.allTerminalSessionIds
        let removedIds = Set(oldSessionIds).subtracting(Set(newSessionIds))
        for sessionId in removedIds {
            sessionManager.destroySession(for: sessionId)
        }
        tabs[index].mosaicLayout = layout

        // Wave 6 · A9: if the focused pane is no longer in the layout (was
        // closed), clear the focus so a stale paneId isn't kept around.
        if let focused = focusedMosaicPaneIds[tabId],
           !layout.allPaneIds.contains(focused) {
            focusedMosaicPaneIds[tabId] = layout.allPaneIds.first
        }

        notifyTabStateChanged()
    }

    func closeTab(_ id: UUID, force: Bool = false) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if tab.isPinned && !force { return }

        // Wave 3 · A1: capture neighbour BEFORE removing so we can land the user
        // on the visually-adjacent tab instead of jumping to the very end of the
        // bar. Prefer the tab to the right (`closedIndex` after removal); if it
        // was the rightmost, fall back to the new last tab.
        let closedIndex = tabs.firstIndex(where: { $0.id == id }) ?? -1
        let wasActive = activeTabId == id

        if let layout = tab.mosaicLayout {
            for sessionId in layout.allTerminalSessionIds {
                sessionManager.destroySession(for: sessionId)
            }
        }
        tabAgentStates[id]?.cancel()
        tabAgentStates.removeValue(forKey: id)
        gitViewModels.removeValue(forKey: id)
        focusedMosaicPaneIds.removeValue(forKey: id)
        sessionManager.destroySession(for: id)
        tabs.removeAll { $0.id == id }
        if wasActive {
            if tabs.isEmpty {
                activeTabId = nil
            } else if closedIndex >= 0, closedIndex < tabs.count {
                // After removal, the index that was occupied by `id` now holds
                // the next-to-the-right tab — that's the natural successor.
                activeTabId = tabs[closedIndex].id
            } else {
                activeTabId = tabs.last?.id
            }
        }
        if tabs.isEmpty {
            addTab()
        }
        notifyTabStateChanged()
    }

    func togglePin(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].isPinned.toggle()

        if tabs[index].isPinned {
            let tab = tabs.remove(at: index)
            let pinnedCount = tabs.filter(\.isPinned).count
            tabs.insert(tab, at: pinnedCount)
        }
        notifyTabStateChanged()
    }

    var activeTab: TerminalTab? {
        get { tabs.first { $0.id == activeTabId } }
        set {
            if let newValue, let index = tabs.firstIndex(where: { $0.id == newValue.id }) {
                tabs[index] = newValue
                notifyTabStateChanged()
            }
        }
    }

    // MARK: - Tab Navigation

    func selectNextTab() {
        guard tabs.count > 1, let currentId = activeTabId,
              let currentIndex = tabs.firstIndex(where: { $0.id == currentId }) else { return }
        let nextIndex = (currentIndex + 1) % tabs.count
        activeTabId = tabs[nextIndex].id
        notifyTabStateChanged()
    }

    func selectPreviousTab() {
        guard tabs.count > 1, let currentId = activeTabId,
              let currentIndex = tabs.firstIndex(where: { $0.id == currentId }) else { return }
        let prevIndex = (currentIndex - 1 + tabs.count) % tabs.count
        activeTabId = tabs[prevIndex].id
        notifyTabStateChanged()
    }

    func selectTab(at index: Int) {
        guard index >= 0 && index < tabs.count else { return }
        activeTabId = tabs[index].id
        notifyTabStateChanged()
    }

    func closeActiveTab() {
        guard let id = activeTabId else { return }
        closeTab(id)
    }

    func closeTabsToRight(of id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let toClose = Array(tabs[(index + 1)...]).filter { !$0.isPinned }
        for tab in toClose { closeTab(tab.id) }
    }

    func closeTabsToLeft(of id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }), index > 0 else { return }
        let toClose = Array(tabs[..<index]).filter { !$0.isPinned }
        for tab in toClose { closeTab(tab.id) }
    }

    func closeOtherTabs(except id: UUID) {
        let toClose = tabs.filter { $0.id != id && !$0.isPinned }
        for tab in toClose { closeTab(tab.id) }
    }

    // MARK: - Terminal Command

    func sendTerminalCommand(_ command: String) {
        guard let tabId = activeTabId,
              let tab = tabs.first(where: { $0.id == tabId }) else { return }
        // Wave 6 · A9: in mosaic mode, route to the focused pane's session so
        // the user types into the visible terminal, not into a hidden one.
        let targetSessionId = effectiveSessionId(for: tab)
        let session = sessionManager.session(for: targetSessionId, initialDirectory: tab.currentDirectory)
        SessionLogger.shared.logTerminalCommand(command)
        session.sendCommand(command)

        let entry = HistoryEntry(
            type: .terminalCommand,
            userInput: command,
            commands: [command],
            tabId: tabId,
            tabTitle: tab.title
        )
        appendHistory(entry)
    }

    // MARK: - Agent Execution (per-tab)

    func buildContextExtra(for tab: TerminalTab) -> String {
        switch tab.tabMode {
        case .git:
            let vm = gitViewModel(for: tab.id)
            let ctx = GitContextBuilder.build(from: vm)
            return GitContextBuilder.formatForPrompt(ctx)
        case .explorer:
            // Wave 5 · B1: feed the LLM a real directory snapshot instead of an
            // empty string when the user is operating in explorer mode.
            let ctx = ExplorerContextBuilder.build(directory: tab.currentDirectory)
            return ExplorerContextBuilder.formatForPrompt(ctx)
        default:
            return ""
        }
    }

    func startAgentExecution(_ userMessage: String, attachments: [FileAttachment] = []) {
        guard let tab = activeTab else { return }

        if browserURL != nil {
            executeBrowserAgent(userMessage, tab: tab)
            return
        }

        let state = agentState(for: tab.id)
        state.fileAttachments = attachments

        let needsPreview = (tab.approvalMode == .alwaysAsk || tab.approvalMode == .manualOnly)

        if needsPreview {
            showPlanPreview(userMessage, tab: tab)
        } else {
            executeAgent(userMessage, tab: tab)
        }
    }

    func showPlanPreview(_ userMessage: String, tab: TerminalTab) {
        let state = agentState(for: tab.id)
        // Wave 6 · A9: route to the focused mosaic pane's session if applicable.
        let targetSessionId = effectiveSessionId(for: tab)
        let session = sessionManager.session(for: targetSessionId, initialDirectory: tab.currentDirectory)

        state.isAgentRunning = true
        state.agentStatus = "Gerando plano..."
        state.agentResults = []
        state.errorMessage = nil
        state.pendingAgentMessage = userMessage
        state.startTime = Date()
        state.endTime = nil
        notifyTabStateChanged()

        let terminalText = session.getTerminalText(maxLines: 50)
        let mcpCtx = MCPManager.shared.toolsDescription()
        let contextExtra = buildContextExtra(for: tab)

        let input = AgentInput(
            userMessage: userMessage,
            currentDirectory: tab.currentDirectory,
            provider: tab.provider,
            model: tab.model,
            terminalContext: terminalText,
            mcpToolsContext: mcpCtx,
            fileAttachments: state.fileAttachments,
            tabMode: tab.tabMode,
            contextExtra: contextExtra,
            conversationTurns: state.recentTurnsForPrompt
        )

        let router = modelRouter
        let guard_ = commandGuard

        state.agentTask = Task { [weak self] in
            do {
                let plan = try await router.generatePlan(input: input)
                await MainActor.run {
                    state.previewPlan = plan
                    state.previewGuardResults = guard_.evaluatePlan(plan, approvalMode: tab.approvalMode)
                    state.isShowingPlanPreview = true
                    state.isAgentRunning = false
                    state.agentStatus = nil
                    self?.notifyTabStateChanged()
                }
            } catch {
                await MainActor.run {
                    state.errorMessage = error.localizedDescription
                    state.isAgentRunning = false
                    state.agentStatus = nil
                    self?.notifyTabStateChanged()
                }
            }
        }
    }

    /// Wave 1 · C1: locates the tab whose preview is currently being shown to the
    /// user. We prefer the active tab (the user almost always operates on what
    /// they see), but fall back to *any* tab that still has a pending preview —
    /// this prevents accidentally approving/dismissing a preview against the
    /// wrong tab if state shifted between rendering and the button tap.
    private func tabWithPendingPreview() -> TerminalTab? {
        if let active = activeTab,
           let activeState = tabAgentStates[active.id],
           activeState.isShowingPlanPreview {
            return active
        }
        for tab in tabs {
            if let state = tabAgentStates[tab.id], state.isShowingPlanPreview {
                return tab
            }
        }
        return nil
    }

    func approvePlanPreview() {
        guard let tab = tabWithPendingPreview() else { return }
        let state = agentState(for: tab.id)
        guard let msg = state.pendingAgentMessage else { return }
        state.dismissPlanPreview()
        notifyTabStateChanged()
        executeAgent(msg, tab: tab)
    }

    func dismissPlanPreview() {
        guard let tab = tabWithPendingPreview() else {
            activeAgentState?.dismissPlanPreview()
            notifyTabStateChanged()
            return
        }
        agentState(for: tab.id).dismissPlanPreview()
        notifyTabStateChanged()
    }

    func previewGuardResultsList() -> [CommandGuard.GuardResult] {
        if let tab = tabWithPendingPreview() {
            return agentState(for: tab.id).previewGuardResults
        }
        return activeAgentState?.previewGuardResults ?? []
    }

    func executeAgent(_ userMessage: String, tab: TerminalTab) {
        let state = agentState(for: tab.id)

        state.isAgentRunning = true
        state.agentStatus = nil
        state.agentResults = []
        state.errorMessage = nil
        state.startTime = Date()
        state.endTime = nil
        state.runningPlan = nil
        state.runningPlanRound = 0
        state.dismissPlan()
        notifyTabStateChanged()

        let executor = AgentExecutor(router: modelRouter)
        executor.fileAttachments = state.fileAttachments
        executor.contextExtra = buildContextExtra(for: tab)
        executor.priorTurns = state.recentTurnsForPrompt
        if tab.tabMode == .git {
            executor.gitViewModel = gitViewModel(for: tab.id)
        }
        if tab.tabMode == .explorer {
            executor.fileExplorerDirectory = tab.currentDirectory
        }
        executor.onThinking = { [weak self] phase, details in
            state.thinkingPhase = phase
            state.thinkingDetails = details
            self?.notifyTabStateChanged()
        }
        executor.onStreaming = { [weak self] partial in
            state.streamingText = partial
            self?.notifyTabStateChanged()
        }
        executor.onDryRunRequest = { [weak self] plan in
            guard let self else { return .approve }
            return await self.requestDryRunApproval(plan: plan)
        }
        // Wave 6 · A9: target the focused pane's session so agent output ends
        // up in the terminal the user is actually looking at.
        let targetSessionId = effectiveSessionId(for: tab)
        let session = sessionManager.session(for: targetSessionId, initialDirectory: tab.currentDirectory)

        state.agentTask = Task { [weak self] in
            executor.execute(
                userMessage: userMessage,
                tab: tab,
                session: session,
                onStatus: { status in
                    state.agentStatus = status
                    self?.notifyTabStateChanged()
                },
                onStep: { result in
                    state.agentResults.append(result)
                    if result.output.stdout.hasPrefix("OPEN_TERMINAL:") {
                        let dir = String(result.output.stdout.dropFirst("OPEN_TERMINAL:".count))
                        self?.createTab(directory: dir)
                    }
                    self?.notifyTabStateChanged()
                },
                onPlanUpdate: { plan, round in
                    state.runningPlan = plan
                    state.runningPlanRound = round
                    self?.notifyTabStateChanged()
                },
                onComplete: { summary, richOutput in
                    state.agentStatus = summary
                    state.isAgentRunning = false
                    state.endTime = Date()
                    state.lastRichOutput = richOutput

                    // IMPORTANT: snapshot the plan BEFORE clearing it, otherwise the
                    // ConversationTurn we build for the tab memory has empty title /
                    // explanation and the next user message loses context.
                    let completedPlan = state.runningPlan
                    state.runningPlan = nil

                    if let urlStr = richOutput?.openUrl, let url = URL(string: urlStr) {
                        state.browserURL = url
                    }

                    let succeeded = state.agentResults.allSatisfy { $0.output.succeeded || $0.wasBlocked }
                    let turn = ConversationTurn.from(
                        userMessage: userMessage,
                        plan: completedPlan,
                        results: state.agentResults,
                        summary: summary,
                        richOutput: richOutput,
                        succeeded: succeeded
                    )
                    state.appendTurn(turn)

                    self?.notifyTabStateChanged()

                    let cmds = state.agentResults.map(\.command)
                    let outputs = state.agentResults.map {
                        HistoryStepOutput(
                            command: $0.command,
                            stdout: $0.output.stdout,
                            stderr: $0.output.stderr,
                            exitCode: $0.output.exitCode,
                            risk: $0.risk.rawValue
                        )
                    }
                    let entry = HistoryEntry(
                        type: .agentPlan,
                        userInput: userMessage,
                        commands: cmds,
                        summary: summary,
                        stepOutputs: outputs,
                        tabId: tab.id,
                        tabTitle: tab.title
                    )
                    self?.appendHistory(entry)
                },
                onError: { error in
                    state.errorMessage = error
                    state.agentStatus = nil
                    state.isAgentRunning = false
                    state.endTime = Date()

                    let failedPlan = state.runningPlan
                    state.runningPlan = nil

                    let turn = ConversationTurn.from(
                        userMessage: userMessage,
                        plan: failedPlan,
                        results: state.agentResults,
                        summary: "Erro: \(error)",
                        richOutput: nil,
                        succeeded: false
                    )
                    state.appendTurn(turn)

                    self?.notifyTabStateChanged()

                    let cmds = state.agentResults.map(\.command)
                    let outputs = state.agentResults.map {
                        HistoryStepOutput(
                            command: $0.command,
                            stdout: $0.output.stdout,
                            stderr: $0.output.stderr,
                            exitCode: $0.output.exitCode,
                            risk: $0.risk.rawValue
                        )
                    }
                    let entry = HistoryEntry(
                        type: .agentPlan,
                        userInput: userMessage,
                        commands: cmds,
                        summary: "Erro: \(error)",
                        stepOutputs: outputs,
                        tabId: tab.id,
                        tabTitle: tab.title
                    )
                    self?.appendHistory(entry)
                },
                onToolMissing: { [weak self] request in
                    state.pendingToolInstall = request
                    state.isShowingToolInstall = true
                    request.resolver.onResolved = { [weak self, weak state] in
                        Task { @MainActor in
                            state?.isShowingToolInstall = false
                            state?.pendingToolInstall = nil
                            self?.notifyTabStateChanged()
                        }
                    }
                    self?.notifyTabStateChanged()
                },
                onSudoNeeded: { request in
                    state.pendingSudoRequest = request
                    state.isShowingSudoPrompt = true
                    self?.notifyTabStateChanged()
                }
            )
        }
    }

    func executeBrowserAgent(_ userMessage: String, tab: TerminalTab) {
        let state = agentState(for: tab.id)

        state.isAgentRunning = true
        state.agentStatus = "Analisando página..."
        state.agentResults = []
        state.errorMessage = nil
        state.startTime = Date()
        state.endTime = nil
        state.dismissPlan()
        notifyTabStateChanged()

        let router = modelRouter
        let maxBrowserSteps = 15

        state.agentTask = Task { [weak self] in
            do {
                let pageInfo = await BrowserAgent.shared.getPageInfo()

                let input = AgentInput(
                    userMessage: userMessage,
                    currentDirectory: tab.currentDirectory,
                    provider: tab.provider,
                    model: tab.model,
                    isBrowserMode: true,
                    browserPageInfo: pageInfo
                )

                try Task.checkCancellation()

                await MainActor.run {
                    state.agentStatus = "Gerando plano de ações no browser..."
                    self?.notifyTabStateChanged()
                }

                var plan = try await router.generateBrowserPlan(input: input)
                var allResults: [BrowserActionResult] = []
                var round = 0
                let maxRounds = 5

                while !plan.browserActions.isEmpty && round < maxRounds && allResults.count < maxBrowserSteps {
                    try Task.checkCancellation()
                    round += 1

                    for (i, action) in plan.browserActions.enumerated() {
                        try Task.checkCancellation()
                        if allResults.count >= maxBrowserSteps { break }

                        await MainActor.run {
                            state.agentStatus = "[\(allResults.count + 1)] \(action.action): \(action.reason)"
                            self?.notifyTabStateChanged()
                        }

                        let result = await BrowserAgent.shared.executeAction(action)
                        allResults.append(result)

                        let stepResult = StepResult(
                            command: "🌐 \(action.action)\(action.selector.map { " (\($0))" } ?? "")",
                            output: CommandOutput(
                                command: action.action,
                                stdout: result.output,
                                stderr: result.success ? "" : result.output,
                                exitCode: result.success ? 0 : 1
                            ),
                            risk: .readOnly,
                            wasBlocked: false
                        )
                        await MainActor.run {
                            state.agentResults.append(stepResult)
                            self?.notifyTabStateChanged()
                        }
                    }

                    try Task.checkCancellation()

                    let freshPageInfo = await BrowserAgent.shared.getPageInfo()
                    let followUpMsg = PromptBuilder.buildBrowserFollowUpMessage(
                        originalRequest: userMessage,
                        results: allResults,
                        pageInfo: freshPageInfo
                    )

                    let followUpMessages: [[String: String]] = [
                        ["role": "system", "content": PromptBuilder.buildBrowserSystemPrompt()],
                        ["role": "user", "content": followUpMsg]
                    ]

                    await MainActor.run {
                        state.agentStatus = "Analisando resultados..."
                        self?.notifyTabStateChanged()
                    }

                    plan = try await router.sendBrowserFollowUp(
                        messages: followUpMessages,
                        providerType: tab.provider,
                        model: tab.model
                    )
                }

                let summary = plan.explanation + "\n\n" + plan.finalNote
                await MainActor.run {
                    state.agentStatus = summary
                    state.isAgentRunning = false
                    state.endTime = Date()
                    state.lastRichOutput = plan.richOutput
                    self?.notifyTabStateChanged()

                    let cmds = state.agentResults.map(\.command)
                    let outputs = state.agentResults.map {
                        HistoryStepOutput(
                            command: $0.command,
                            stdout: $0.output.stdout,
                            stderr: $0.output.stderr,
                            exitCode: $0.output.exitCode,
                            risk: $0.risk.rawValue
                        )
                    }
                    let entry = HistoryEntry(
                        type: .agentPlan,
                        userInput: "🌐 \(userMessage)",
                        commands: cmds,
                        summary: summary,
                        stepOutputs: outputs,
                        tabId: tab.id,
                        tabTitle: tab.title
                    )
                    self?.appendHistory(entry)
                }

            } catch is CancellationError {
                await MainActor.run {
                    state.errorMessage = "Execução cancelada pelo usuário."
                    state.isAgentRunning = false
                    state.endTime = Date()
                    self?.notifyTabStateChanged()
                }
            } catch {
                let msg = error.localizedDescription
                NexLog.ai.error("Browser agent error: \(msg)")
                await MainActor.run {
                    state.errorMessage = msg
                    state.agentStatus = nil
                    state.isAgentRunning = false
                    state.endTime = Date()
                    self?.notifyTabStateChanged()

                    let entry = HistoryEntry(
                        type: .agentPlan,
                        userInput: "🌐 \(userMessage)",
                        commands: [],
                        summary: "Erro: \(msg)",
                        tabId: tab.id,
                        tabTitle: tab.title
                    )
                    self?.appendHistory(entry)
                }
            }
        }
    }

    func cancelAgent() {
        activeAgentState?.cancel()
        notifyTabStateChanged()
    }

    func cancelAllAgents() {
        for (_, state) in tabAgentStates {
            state.cancel()
        }
        notifyTabStateChanged()
    }

    func respondToToolInstall(_ response: ToolInstallResponse) {
        guard let state = activeAgentState, let request = state.pendingToolInstall else { return }
        state.isShowingToolInstall = false
        state.pendingToolInstall = nil
        request.resolver.resolve(response)
        notifyTabStateChanged()
    }

    func respondToSudo(_ response: SudoPasswordResponse) {
        guard let state = activeAgentState, let request = state.pendingSudoRequest else { return }
        state.isShowingSudoPrompt = false
        state.pendingSudoRequest = nil
        request.continuation.resume(returning: response)
        notifyTabStateChanged()
    }

    // MARK: - Plan (inline)

    func submitPromptInline(_ userMessage: String) {
        guard let tab = activeTab else { return }
        let state = agentState(for: tab.id)
        let originatingTabId = tab.id

        isLoading = true
        state.errorMessage = nil
        notifyTabStateChanged()

        let mcpCtx = MCPManager.shared.toolsDescription()

        let input = AgentInput(
            userMessage: userMessage,
            currentDirectory: tab.currentDirectory,
            provider: tab.provider,
            model: tab.model,
            mcpToolsContext: mcpCtx
        )

        let router = modelRouter
        let guard_ = commandGuard
        let approvalMode = tab.approvalMode

        // Wave 2 · C6: store the Task on the tab's TabAgentState so it can be
        // cancelled when the tab closes or the user hits cancel. Without this,
        // closing the tab mid-flight let the task complete and publish into a
        // state already removed from the registry.
        state.inlineTask?.cancel()
        state.inlineTask = Task { [weak self] in
            do {
                let plan = try await router.generatePlan(input: input)
                try Task.checkCancellation()
                await MainActor.run {
                    guard let self else { return }
                    // Use the captured tabId — not activeTab — so the result is
                    // applied to the tab that originated the request even if the
                    // user has switched tabs in the meantime.
                    let targetState = self.agentState(for: originatingTabId)
                    targetState.currentPlan = plan
                    targetState.guardResults = guard_.evaluatePlan(plan, approvalMode: approvalMode)
                    targetState.isShowingApproval = true
                    targetState.inlineTask = nil
                    if self.activeTabId == originatingTabId {
                        self.isLoading = false
                    }
                    self.notifyTabStateChanged()
                }
            } catch is CancellationError {
                // Tab was closed or user cancelled — silently drop, the state was
                // already reset by the canceller.
                return
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    let targetState = self.agentState(for: originatingTabId)
                    targetState.errorMessage = error.localizedDescription
                    targetState.inlineTask = nil
                    if self.activeTabId == originatingTabId {
                        self.isLoading = false
                    }
                    self.notifyTabStateChanged()
                }
            }
        }
    }

    func approvePlan() {
        guard let tab = activeTab else { return }
        let state = agentState(for: tab.id)
        guard let plan = state.currentPlan else { return }

        // Wave 6 · A9: route to the focused pane's session in mosaic mode.
        let targetSessionId = effectiveSessionId(for: tab)
        let session = sessionManager.session(for: targetSessionId, initialDirectory: tab.currentDirectory)

        for (index, command) in plan.commands.enumerated() {
            let result = state.guardResults.indices.contains(index)
                ? state.guardResults[index]
                : commandGuard.evaluate(command: command.command, approvalMode: tab.approvalMode)

            if result.isBlocked {
                NexLog.safety.warning("Blocked command: \(command.command)")
                continue
            }

            session.sendCommand(command.command)
        }

        state.dismissPlan()
        notifyTabStateChanged()
    }

    func dismissPlan() {
        activeAgentState?.dismissPlan()
        notifyTabStateChanged()
    }

    func currentGuardResults() -> [CommandGuard.GuardResult] {
        activeAgentState?.guardResults ?? []
    }

    // MARK: - Dry-run flow

    /// Solicita um dry-run preview ao usuário e bloqueia até a decisão.
    /// Chamado pelo AgentExecutor antes de executar ações destrutivas.
    func requestDryRunApproval(plan: ExecutionPlan) async -> DryRunDecision {
        await withCheckedContinuation { (cont: CheckedContinuation<DryRunDecision, Never>) in
            self.dryRunDecisionContinuation = cont
            self.pendingDryRunPlan = plan
            self.isShowingDryRunPreview = true
            // Persiste os steps planejados na timeline para servir como histórico
            // mesmo se o usuário cancelar.
            ExecutionLogStore.shared.append(plan.steps)
        }
    }

    func approveDryRun() {
        if let plan = pendingDryRunPlan {
            // Marca os steps planejados como aprovados (UI vai atualizar quando
            // executarem de fato e virarem .completed/.failed).
            for step in plan.steps {
                ExecutionLogStore.shared.updateStatus(id: step.id, to: .approved)
            }
        }
        dryRunDecisionContinuation?.resume(returning: .approve)
        dryRunDecisionContinuation = nil
        isShowingDryRunPreview = false
        pendingDryRunPlan = nil
    }

    func cancelDryRun() {
        if let plan = pendingDryRunPlan {
            for step in plan.steps {
                ExecutionLogStore.shared.updateStatus(id: step.id, to: .cancelled)
            }
        }
        dryRunDecisionContinuation?.resume(returning: .cancel)
        dryRunDecisionContinuation = nil
        isShowingDryRunPreview = false
        pendingDryRunPlan = nil
    }
}
