import AppKit
import ServiceManagement
import CoreSpotlight

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    weak var appState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if terminateIfAlreadyRunning() { return }
        setupStatusBarItem()
        setupHotKey()
        setupNotifications()
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // MARK: - URL Scheme Handling

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleURL(url)
        }
    }

    private func handleURL(_ url: URL) {
        guard url.scheme == "nexifyterm" else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let params = components?.queryItems?.reduce(into: [String: String]()) { $0[$1.name] = $1.value } ?? [:]

        Task { @MainActor in
            guard let state = appState else { return }

            switch url.host {
            case "open":
                let path = params["path"] ?? state.configStore.defaultDirectory
                let newTab = params["newTab"] == "true"
                if newTab || state.tabs.isEmpty {
                    state.createTab(directory: path)
                } else if let tab = state.activeTab {
                    var updated = tab
                    updated.currentDirectory = path
                    state.activeTab = updated
                }
                showMainWindow()

            case "run":
                if let command = params["command"] {
                    showMainWindow()
                    state.sendTerminalCommand(command)
                }

            case "newTab":
                let path = params["path"] ?? state.configStore.defaultDirectory
                let type = params["type"] ?? "terminal"
                switch type {
                case "explorer": state.addExplorerTab(directory: path)
                case "git": state.addGitTab(directory: path)
                default: state.createTab(directory: path)
                }
                showMainWindow()

            case "agent":
                if let prompt = params["prompt"] {
                    showMainWindow()
                    state.startAgentExecution(prompt)
                }

            default:
                break
            }
        }
    }

    // MARK: - Spotlight Continuation

    func application(_ application: NSApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        if let path = SpotlightIndexer.shared.handleSpotlightActivity(userActivity) {
            Task { @MainActor in
                appState?.createTab(directory: path)
                showMainWindow()
            }
            return true
        }
        return false
    }

    // MARK: - Services

    @objc func openInNexifyTerm(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let items = pboard.pasteboardItems else { return }
        for item in items {
            if let urlString = item.string(forType: .fileURL),
               let url = URL(string: urlString) {
                let path = url.path
                Task { @MainActor in
                    self.appState?.createTab(directory: path)
                    self.showMainWindow()
                }
                return
            }
            if let text = item.string(forType: .string) {
                let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if FileManager.default.fileExists(atPath: path) {
                    Task { @MainActor in
                        self.appState?.createTab(directory: path)
                        self.showMainWindow()
                    }
                    return
                }
            }
        }
    }

    // MARK: - HotKey

    private func setupHotKey() {
        let dropdown = DropDownWindow.shared
        dropdown.appState = appState
        HotKeyManager.shared.configure { [weak self] in
            if dropdown.isShowing {
                dropdown.hide()
            } else {
                dropdown.appState = self?.appState
                dropdown.show()
            }
        }
    }

    // MARK: - Notifications

    private func setupNotifications() {
        let manager = NotificationManager.shared
        manager.setup()
        manager.onViewResult = { [weak self] in
            self?.showMainWindow()
        }
        manager.onRetry = { [weak self] input in
            Task { @MainActor in
                self?.appState?.startAgentExecution(input)
            }
        }
    }

    // MARK: - Dock Menu

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()

        guard let state = appState else { return menu }

        for (index, tab) in state.tabs.enumerated() {
            let icon: String
            switch tab.tabMode {
            case .terminal: icon = "⌨"
            case .explorer: icon = "📁"
            case .mosaic:   icon = "◫"
            case .git:      icon = "⎇"
            }

            let prefix = tab.id == state.activeTabId ? "● " : "  "
            let pinIndicator = tab.isPinned ? " 📌" : ""
            let itemTitle = "\(prefix)\(icon) \(tab.title)\(pinIndicator)"

            let item = NSMenuItem(title: itemTitle, action: #selector(dockMenuSelectTab(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let recents = RecentDirectoriesStore.shared.recents.prefix(3)
        if !recents.isEmpty {
            let header = NSMenuItem(title: "Recentes", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            for (i, dir) in recents.enumerated() {
                let item = NSMenuItem(title: "📂 \(dir.name)", action: #selector(dockMenuOpenRecent(_:)), keyEquivalent: "")
                item.tag = i
                item.target = self
                item.toolTip = dir.path
                menu.addItem(item)
            }

            menu.addItem(.separator())
        }

        let newTabItem = NSMenuItem(title: "Novo Terminal", action: #selector(dockMenuNewTab), keyEquivalent: "")
        newTabItem.target = self
        menu.addItem(newTabItem)

        return menu
    }

    @objc private func dockMenuOpenRecent(_ sender: NSMenuItem) {
        let index = sender.tag
        let recents = Array(RecentDirectoriesStore.shared.recents.prefix(3))
        guard index < recents.count else { return }
        let path = recents[index].path
        Task { @MainActor [weak self] in
            self?.appState?.createTab(directory: path)
            self?.showMainWindow()
        }
    }

    @objc private func dockMenuSelectTab(_ sender: NSMenuItem) {
        let index = sender.tag
        Task { @MainActor [weak self] in
            self?.appState?.selectTab(at: index)
            self?.showMainWindow()
        }
    }

    @objc private func dockMenuNewTab() {
        Task { @MainActor [weak self] in
            guard let self, let state = self.appState else { return }
            let dir = state.configStore.defaultDirectory
            state.createTab(directory: dir)
            self.showMainWindow()
        }
    }

    // MARK: - Single Instance

    private func terminateIfAlreadyRunning() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        let others = running.filter { $0 != NSRunningApplication.current }
        guard !others.isEmpty else { return false }

        others.first?.activate()
        NSApp.terminate(nil)
        return true
    }

    // MARK: - Status Bar

    private func setupStatusBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem?.button else { return }

        if let img = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: "NexOperator") {
            img.isTemplate = true
            button.image = img
        }
        button.toolTip = "NexOperator Terminal"

        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        menu.addItem(NSMenuItem(title: "Abrir NexOperator", action: #selector(showMainWindow), keyEquivalent: "o"))
        menu.addItem(.separator())

        let launchItem = NSMenuItem(title: "Abrir com o sistema", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.state = Self.launchAtLoginEnabled ? .on : .off
        launchItem.tag = 100
        menu.addItem(launchItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Sair", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem?.menu = menu
    }

    @objc func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)

        let mainWindow = NSApp.windows.first(where: { $0.canBecomeMain })
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
        } else if let window = NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Launch at Login

    @objc private func toggleLaunchAtLogin() {
        let newValue = !Self.launchAtLoginEnabled
        Self.setLaunchAtLogin(newValue)
    }

    static func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NexLog.general.error("Launch at login toggle failed: \(error.localizedDescription)")
        }
    }

    static var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if let item = menu.item(withTag: 100) {
            item.state = Self.launchAtLoginEnabled ? .on : .off
        }
    }
}
