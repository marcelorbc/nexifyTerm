import SwiftUI
import UserNotifications
import Foundation

extension Notification.Name {
    static let focusInputBar = Notification.Name("focusInputBar")
    static let terminalFontSizeChanged = Notification.Name("terminalFontSizeChanged")
}

struct RootView: View {
    @EnvironmentObject var appState: AppState
    @State private var showWelcome = true
    @State private var terminalRatio: CGFloat = 0.6
    @State private var keyMonitor: Any?

    private var hasResults: Bool {
        appState.isAgentRunning || !appState.agentResults.isEmpty || appState.agentStatus != nil
    }

    var body: some View {
        let _ = appState.tabStateVersion

        HStack(spacing: 0) {
            if appState.isShowingFileBrowser {
                FileBrowserSidebarView()
                    .environmentObject(appState)
                    .transition(.move(edge: .leading).combined(with: .opacity))

                Divider()
            }

            VStack(spacing: 0) {
                TerminalTabsView()

                #if DEBUG
                HStack(spacing: 6) {
                    Image(systemName: "hammer.fill")
                        .font(.system(size: 9))
                    Text("DEV MODE")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(1)
                    Text("—")
                        .font(.system(size: 9))
                    Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                }
                .foregroundColor(.orange)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(Color.orange.opacity(0.1))
                #endif

                Divider()

                GeometryReader { geo in
                    let totalHeight = geo.size.height
                    let showSplit = hasResults || appState.isShowingPlanPreview || appState.isShowingApproval

                    VStack(spacing: 0) {
                        ZStack {
                            if let browserURL = appState.browserURL {
                                EmbeddedBrowserView(
                                    initialURL: browserURL,
                                    onDismiss: { appState.closeBrowser() }
                                )
                                .transition(.opacity)
                            } else {
                                TerminalContainerView()
                            }

                            if showWelcome && appState.activeTab?.isTerminal == true && !appState.isAgentRunning && appState.agentResults.isEmpty && !appState.isShowingPlanPreview && appState.browserURL == nil {
                                WelcomeOverlay { prompt in
                                    showWelcome = false
                                    appState.startAgentExecution(prompt)
                                } onDismiss: {
                                    showWelcome = false
                                }
                                .transition(.opacity)
                            }
                        }
                        .frame(height: showSplit ? totalHeight * terminalRatio : totalHeight)

                        if showSplit {
                            dragHandle(totalHeight: totalHeight)

                            VStack(spacing: 0) {
                                if appState.isShowingPlanPreview, let plan = appState.previewPlan {
                                    PlanPreviewView(plan: plan, guardResults: appState.previewGuardResultsList())
                                        .environmentObject(appState)
                                        .transition(.move(edge: .bottom).combined(with: .opacity))
                                }

                                InlineResultsView()
                                    .environmentObject(appState)

                                if appState.isShowingApproval, let plan = appState.currentPlan {
                                    InlinePlanView(plan: plan, guardResults: appState.currentGuardResults())
                                        .environmentObject(appState)
                                        .transition(.move(edge: .bottom).combined(with: .opacity))
                                }
                            }
                            .frame(height: totalHeight * (1 - terminalRatio) - 5)
                        }
                    }
                    .coordinateSpace(name: "splitContainer")
                }

                InputBarView()
            }

            if appState.isShowingHistory {
                Divider()

                HistoryPanelView(
                    onReplay: { entry in
                        showWelcome = false
                        if entry.isAgent {
                            appState.startAgentExecution(entry.userInput)
                        } else if let cmd = entry.commands.first {
                            appState.sendTerminalCommand(cmd)
                        }
                    },
                    onClose: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            appState.isShowingHistory = false
                        }
                    }
                )
                .environmentObject(appState)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .navigationTitle(Host.current().localizedName ?? ProcessInfo.processInfo.hostName)
        .overlay {
            if appState.isShowingGlobalSearch {
                ZStack {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.15)) {
                                appState.isShowingGlobalSearch = false
                            }
                        }

                    VStack {
                        GlobalSearchView {
                            withAnimation(.easeOut(duration: 0.15)) {
                                appState.isShowingGlobalSearch = false
                            }
                        }
                        .environmentObject(appState)
                        .padding(.top, 60)

                        Spacer()
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        appState.isShowingFileBrowser.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.leading")
                }
                .help("Explorer (⌘B)")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                        appState.isShowingGlobalSearch.toggle()
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .help("Busca Global (⌘P)")

                if appState.isAgentRunning {
                    AgentRunningBadge(startTime: appState.agentStartTime) {
                        appState.cancelAgent()
                    }
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        appState.isShowingHistory.toggle()
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .help("Histórico (⌘Y)")
            }
        }
        .sheet(isPresented: $appState.isShowingSudoPrompt) {
            SudoPromptView { response in
                appState.respondToSudo(response)
            }
        }
        .sheet(isPresented: $appState.isShowingDirectoryPicker) {
            DirectoryPickerView(
                defaultPath: appState.configStore.defaultDirectory,
                onSelect: { path in
                    appState.createTab(directory: path)
                    appState.isShowingDirectoryPicker = false
                },
                onCancel: {
                    appState.isShowingDirectoryPicker = false
                }
            )
        }
        .animation(.easeInOut(duration: 0.2), value: appState.tabStateVersion)
        .animation(.easeInOut(duration: 0.2), value: appState.isShowingHistory)
        .animation(.easeInOut(duration: 0.2), value: appState.isShowingFileBrowser)
        .animation(.spring(response: 0.25, dampingFraction: 0.9), value: appState.isShowingGlobalSearch)
        .animation(.easeInOut(duration: 0.3), value: showWelcome)
        .frame(minWidth: 700, minHeight: 500)
        .onAppear {
            if let crash = CrashLog.shared.loadAndClear() {
                appState.errorMessage = "O app fechou inesperadamente na última sessão.\n\(crash.prefix(300))"
            }
            installKeyMonitor()
        }
        .onDisappear {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
        }
        .onChange(of: appState.tabStateVersion) { _, _ in
            if !appState.isAgentRunning && appState.agentStatus != nil {
                showWelcome = false
                sendCompletionNotification()
            }
        }
    }

    private func dragHandle(totalHeight: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 5)
            .overlay(
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 32, height: 2)
            )
            .background(Color(nsColor: .separatorColor).opacity(0.3))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let newRatio = terminalRatio + (value.translation.height / totalHeight)
                        terminalRatio = min(0.85, max(0.15, newRatio))
                    }
            )
            .cursorOnHover(.resizeUpDown)
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            let cmd = event.modifierFlags.contains(.command)
            let opt = event.modifierFlags.contains(.option)
            let ctrl = event.modifierFlags.contains(.control)

            // ⌥⌘→ or ⌃Tab: next tab
            if (cmd && opt && event.keyCode == 124) || (ctrl && event.keyCode == 48) {
                appState.selectNextTab()
                return nil
            }

            // ⌥⌘← or ⌃⇧Tab: previous tab
            if (cmd && opt && event.keyCode == 123) ||
               (ctrl && event.modifierFlags.contains(.shift) && event.keyCode == 48) {
                appState.selectPreviousTab()
                return nil
            }

            // ⌘P: global search
            if cmd && event.charactersIgnoringModifiers == "p" && !event.modifierFlags.contains(.shift) {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                    appState.isShowingGlobalSearch.toggle()
                }
                return nil
            }

            // ⌘L: focus input bar
            if cmd && event.charactersIgnoringModifiers == "l" {
                NotificationCenter.default.post(name: .focusInputBar, object: nil)
                return nil
            }

            // ⌘G: open git tab for current directory
            if cmd && event.charactersIgnoringModifiers == "g" && !opt {
                if let dir = appState.activeTab?.currentDirectory {
                    appState.addGitTab(directory: dir)
                }
                return nil
            }

            // ⌘= / ⌘+: increase font size
            if cmd && !opt && (event.charactersIgnoringModifiers == "=" || event.charactersIgnoringModifiers == "+") {
                appState.configStore.increaseFontSize()
                return nil
            }

            // ⌘-: decrease font size
            if cmd && !opt && event.charactersIgnoringModifiers == "-" {
                appState.configStore.decreaseFontSize()
                return nil
            }

            // ⌘0: reset font size
            if cmd && !opt && event.charactersIgnoringModifiers == "0" {
                appState.configStore.resetFontSize()
                return nil
            }

            return event
        }
    }

    private func sendCompletionNotification() {
        let summary = appState.agentStatus ?? "Pronto"
        let isError = appState.errorMessage != nil
        let tabTitle = appState.activeTab?.title
        let lastOutput = appState.agentResults.last?.output.stdout ?? ""

        NotificationManager.shared.sendAgentComplete(
            summary: summary,
            userInput: appState.agentResults.first?.command ?? "",
            output: lastOutput,
            tabTitle: tabTitle,
            isError: isError
        )
    }
}
