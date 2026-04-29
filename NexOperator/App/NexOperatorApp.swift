import SwiftUI
import CoreSpotlight

@main
struct NexOperatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var permissionsManager = PermissionsManager()
    @State private var showOnboarding: Bool
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let needs = !NexPersistence.shared.getFlag(PermissionsManager.hasCompletedOnboardingKey)
        _showOnboarding = State(initialValue: needs)
        setupCrashHandling()
        setupTerminationObserver()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if showOnboarding {
                    PermissionsView(manager: permissionsManager) {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            showOnboarding = false
                        }
                    }
                    .task {
                        await permissionsManager.checkAllPermissions()
                    }
                } else {
                    RootView()
                        .environmentObject(appState)
                }
            }
            .onAppear {
                appDelegate.appState = appState
                DropDownWindow.shared.appState = appState
            }
            .onOpenURL { url in
                appDelegate.application(NSApp, open: [url])
            }
            .onContinueUserActivity(CSSearchableItemActionType) { activity in
                if let path = SpotlightIndexer.shared.handleSpotlightActivity(activity) {
                    appState.createTab(directory: path)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 900, height: 600)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Novo Terminal") {
                    appState.addTab()
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("Novo Explorer") {
                    appState.addExplorerTab()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Divider()

                Button("Fechar Aba") {
                    appState.closeActiveTab()
                }
                .keyboardShortcut("w", modifiers: .command)
            }

            CommandGroup(after: .toolbar) {
                Button("Próxima Aba") {
                    appState.selectNextTab()
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])

                Button("Aba Anterior") {
                    appState.selectPreviousTab()
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])

                Divider()

                ForEach(0..<9, id: \.self) { index in
                    Button("Aba \(index + 1)") {
                        appState.selectTab(at: index)
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }

                Divider()

                Button("Busca Global") {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                        appState.isShowingGlobalSearch.toggle()
                    }
                }
                .keyboardShortcut("p", modifiers: .command)

                Button("Alternar Sidebar") {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        appState.isShowingFileBrowser.toggle()
                    }
                }
                .keyboardShortcut("b", modifiers: .command)

                Button("Alternar Histórico") {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        appState.isShowingHistory.toggle()
                    }
                }
                .keyboardShortcut("y", modifiers: .command)

                Divider()

                Button("Aumentar Fonte") {
                    appState.configStore.increaseFontSize()
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("Diminuir Fonte") {
                    appState.configStore.decreaseFontSize()
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Restaurar Fonte") {
                    appState.configStore.resetFontSize()
                }
                .keyboardShortcut("0", modifiers: .command)

            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                appState.saveSession()
                appState.cancelAllAgents()
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }

    private func setupTerminationObserver() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            appState.saveSession()
            appState.cancelAllAgents()
        }
    }

    private func setupCrashHandling() {
        NSSetUncaughtExceptionHandler { exception in
            let info = """
            [NexOperator CRASH]
            Exception: \(exception.name.rawValue)
            Reason: \(exception.reason ?? "unknown")
            Stack: \(exception.callStackSymbols.prefix(15).joined(separator: "\n"))
            """
            NexLog.general.critical("\(info)")
            CrashLog.shared.save(info)
        }

        signal(SIGSEGV) { _ in CrashLog.shared.save("SIGSEGV - Segmentation Fault") }
        signal(SIGBUS) { _ in CrashLog.shared.save("SIGBUS - Bus Error") }
        signal(SIGABRT) { _ in CrashLog.shared.save("SIGABRT - Abort") }
    }
}
