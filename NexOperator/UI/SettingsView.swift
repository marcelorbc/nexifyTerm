import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    @State private var ollamaBaseURL: String = ""
    @State private var ollamaModel: String = ""
    @State private var openAIKey: String = ""
    @State private var openAIModel: String = ""
    @State private var geminiKey: String = ""
    @State private var geminiModel: String = ""
    @State private var defaultProvider: ProviderType = .ollama
    @State private var defaultApprovalMode: ApprovalMode = .alwaysAsk
    @State private var defaultDirectory: String = ""
    @State private var askDirectoryOnNewTab: Bool = false
    @State private var launchAtLogin: Bool = false
    @State private var terminalFontSize: CGFloat = ConfigStore.defaultTerminalFontSize
    @State private var hotKeyEnabled: Bool = false
    @State private var hotKeyHideOnFocusLost: Bool = true
    @State private var cliInstalled: Bool = false
    @State private var cliStatusMessage: String = ""
    @State private var sudoAutoAuthorize: Bool = false
    @ObservedObject private var updaterService = UpdaterService.shared

    private let fieldWidth: CGFloat = 280

    var body: some View {
        TabView {
            generalContent
                .tabItem { Label("Geral", systemImage: "gear") }
                .tag("general")

            terminalContent
                .tabItem { Label("Terminal", systemImage: "terminal.fill") }
                .tag("terminal")

            integrationContent
                .tabItem { Label("Integração", systemImage: "puzzlepiece.extension") }
                .tag("integration")

            personalizationContent
                .tabItem { Label("Personalização", systemImage: "brain") }
                .tag("personalization")

            skillsContent
                .tabItem { Label("Skills", systemImage: "sparkle") }
                .tag("skills")

            mcpContent
                .tabItem { Label("MCP Servers", systemImage: "server.rack") }
                .tag("mcp")

            whatsappContent
                .tabItem { Label("WhatsApp", systemImage: "message.fill") }
                .tag("whatsapp")

            providersContent
                .tabItem { Label("Provedores IA", systemImage: "cpu") }
                .tag("providers")

            shortcutsContent
                .tabItem { Label("Atalhos", systemImage: "keyboard") }
                .tag("shortcuts")
        }
        .frame(width: 680, height: 580)
        .onAppear { load() }
        .onDisappear {
            save()
            appState.refreshProviderAvailability()
        }
    }

    // MARK: - General

    private var generalContent: some View {
        SettingsScroll {
            SettingsSection(
                title: "Provedor Padrão",
                icon: "cpu",
                caption: "Provedor de IA usado por padrão em novos terminais. Somente provedores configurados aparecem."
            ) {
                LabeledContent("Provedor") {
                    let availability = ProviderAvailabilityService.shared
                    let providers = availability.hasAnyProvider
                        ? availability.availableProviders
                        : ProviderType.allCases

                    Picker("", selection: $defaultProvider) {
                        ForEach(providers) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: fieldWidth)
                }
            }

            SettingsSection(
                title: "Modo de Aprovação",
                icon: "checkmark.shield",
                caption: "Define como os comandos são aprovados antes de executar."
            ) {
                LabeledContent("Modo") {
                    Picker("", selection: $defaultApprovalMode) {
                        ForEach(ApprovalMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: fieldWidth)
                }
            }

            SettingsSection(
                title: "Atualizações",
                icon: "arrow.triangle.2.circlepath",
                caption: "Verifica automaticamente se há novas versões disponíveis."
            ) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("NexifyTerm")
                                .font(.system(size: 12, weight: .semibold))
                            Text("v\(updaterService.currentVersion)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text("(\(updaterService.buildNumber))")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        if let lastCheck = updaterService.lastUpdateCheck {
                            Text("Última verificação: \(lastCheck.formatted(.relative(presentation: .named)))")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Verificar Agora") {
                        updaterService.checkForUpdates()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!updaterService.canCheckForUpdates)
                }

                Toggle("Verificar automaticamente", isOn: Binding(
                    get: { updaterService.automaticallyChecksForUpdates },
                    set: { updaterService.automaticallyChecksForUpdates = $0 }
                ))
                .toggleStyle(.switch)

                Toggle("Baixar atualizações automaticamente", isOn: Binding(
                    get: { updaterService.automaticallyDownloadsUpdates },
                    set: { updaterService.automaticallyDownloadsUpdates = $0 }
                ))
                .toggleStyle(.switch)
            }

            SettingsSection(
                title: "Sistema",
                icon: "macwindow.on.rectangle",
                caption: "O app fica na barra de status do macOS. Ao fechar a janela, ele permanece ativo."
            ) {
                Toggle("Abrir com o sistema", isOn: $launchAtLogin)
                    .toggleStyle(.switch)
                    .onChange(of: launchAtLogin) { _, newValue in
                        AppDelegate.setLaunchAtLogin(newValue)
                    }
            }
        }
    }

    // MARK: - Terminal

    private var terminalContent: some View {
        SettingsScroll {
            SettingsSection(
                title: "Pasta Padrão",
                icon: "folder",
                caption: "Define onde novos terminais iniciam por padrão."
            ) {
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 11))
                        Text(abbreviatePath(defaultDirectory))
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .textBackgroundColor))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(NexTheme.border, lineWidth: 0.5)
                            )
                    )

                    Button("Escolher...") {
                        chooseDefaultDirectory()
                    }
                    .controlSize(.small)
                }
            }

            SettingsSection(
                title: "Fonte do Terminal",
                icon: "textformat.size",
                caption: "Use ⌘+ para aumentar, ⌘− para diminuir e ⌘0 para restaurar."
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Text("Tamanho")
                            .frame(width: 80, alignment: .leading)
                        Slider(
                            value: $terminalFontSize,
                            in: ConfigStore.minTerminalFontSize...ConfigStore.maxTerminalFontSize,
                            step: ConfigStore.fontSizeStep
                        )
                        .onChange(of: terminalFontSize) { _, newValue in
                            appState.configStore.terminalFontSize = newValue
                        }
                        Text("\(Int(terminalFontSize))pt")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                        Button("Reset") {
                            terminalFontSize = ConfigStore.defaultTerminalFontSize
                            appState.configStore.resetFontSize()
                        }
                        .controlSize(.small)
                    }
                }
            }

            SettingsSection(
                title: "Novo Terminal",
                icon: "plus.rectangle.on.rectangle",
                caption: "Se ativada, uma janela permite escolher a pasta ao criar cada tab."
            ) {
                Toggle("Perguntar a pasta ao criar novo terminal", isOn: $askDirectoryOnNewTab)
                    .toggleStyle(.switch)
            }
        }
    }

    // MARK: - Providers

    private var providersContent: some View {
        SettingsScroll {
            SettingsSection(
                title: "Ollama (Local — Sem Custo)",
                icon: "shippingbox",
                caption: "Rode modelos de IA localmente com total privacidade e sem custo. O Ollama precisa estar instalado e rodando."
            ) {
                OllamaSetupView()

                Divider()

                LabeledContent("Base URL") {
                    TextField("http://localhost:11434", text: $ollamaBaseURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: fieldWidth)
                }
                LabeledContent("Model") {
                    TextField("qwen2.5-coder:7b", text: $ollamaModel)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: fieldWidth)
                }
            }

            SettingsSection(
                title: "OpenAI",
                icon: "key",
                caption: "Chave armazenada localmente de forma segura."
            ) {
                LabeledContent("API Key") {
                    SecureField("sk-...", text: $openAIKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: fieldWidth)
                }
                LabeledContent("Model") {
                    TextField("gpt-5.5", text: $openAIModel)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: fieldWidth)
                }
            }

            SettingsSection(
                title: "Gemini",
                icon: "key",
                caption: "Chave armazenada localmente de forma segura."
            ) {
                LabeledContent("API Key") {
                    SecureField("AI...", text: $geminiKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: fieldWidth)
                }
                LabeledContent("Model") {
                    TextField("gemini-2.5-pro", text: $geminiModel)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: fieldWidth)
                }
            }
        }
    }

    // MARK: - Integration

    private var integrationContent: some View {
        SettingsScroll {
            SettingsSection(
                title: "Global Hotkey",
                icon: "command",
                caption: "Ctrl+` abre o terminal como drop-down de qualquer app. Requer permissão de Acessibilidade."
            ) {
                Toggle("Ativar atalho global", isOn: $hotKeyEnabled)
                    .toggleStyle(.switch)
                    .onChange(of: hotKeyEnabled) { _, newValue in
                        HotKeyManager.shared.isEnabled = newValue
                    }

                if hotKeyEnabled {
                    LabeledContent("Atalho atual") {
                        HotKeyBadge(text: hotKeyDescription())
                    }

                    Toggle("Esconder ao perder foco", isOn: $hotKeyHideOnFocusLost)
                        .toggleStyle(.switch)
                        .onChange(of: hotKeyHideOnFocusLost) { _, newValue in
                            appState.configStore.hotKeyHideOnFocusLost = newValue
                        }
                }
            }

            SettingsSection(
                title: "CLI Tool",
                icon: "terminal",
                caption: "Permite abrir o NexifyTerm do terminal: nexify . ou nexify /path"
            ) {
                HStack(alignment: .center, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: cliInstalled ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(cliInstalled ? Color.green : Color.secondary)
                            .font(.system(size: 14))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cliInstalled ? "Instalado" : "Não instalado")
                                .font(.system(size: 12, weight: .medium))
                            Text(cliInstalled ? "/usr/local/bin/nexify" : "Clique em Instalar para configurar")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    if cliInstalled {
                        Button("Desinstalar", role: .destructive) {
                            do {
                                try CLIInstaller.shared.uninstall()
                                cliInstalled = false
                                cliStatusMessage = "CLI removido."
                            } catch {
                                cliStatusMessage = "Erro: \(error.localizedDescription)"
                            }
                        }
                        .controlSize(.small)
                    } else {
                        Button("Instalar") {
                            do {
                                try CLIInstaller.shared.install()
                                cliInstalled = true
                                cliStatusMessage = "CLI instalado com sucesso."
                            } catch {
                                cliStatusMessage = "Erro: \(error.localizedDescription)"
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }

                if !cliStatusMessage.isEmpty {
                    Text(cliStatusMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            SettingsSection(
                title: "Finder & Services",
                icon: "macwindow",
                caption: "\"Abrir no NexifyTerm\" está disponível no menu Serviços do Finder ao clicar com botão direito em pastas."
            ) {
                EmptyView()
            }

            SettingsSection(
                title: "Shortcuts & Siri",
                icon: "wand.and.stars",
                caption: "Ações disponíveis no app Atalhos: Open Terminal, Run Command, New Tab, Ask AI Agent."
            ) {
                HStack {
                    Spacer()
                    Button("Abrir Atalhos") {
                        NSWorkspace.shared.open(URL(string: "shortcuts://")!)
                    }
                    .controlSize(.small)
                }
            }

            SettingsSection(
                title: "Spotlight",
                icon: "magnifyingglass",
                caption: "Diretórios recentes são indexados automaticamente no Spotlight para busca rápida."
            ) {
                HStack {
                    Spacer()
                    Button("Reindexar Agora") {
                        SpotlightIndexer.shared.indexRecentDirectories(RecentDirectoriesStore.shared.recents)
                    }
                    .controlSize(.small)
                }
            }

            SettingsSection(
                title: "Sudo Automático",
                icon: "lock.shield",
                caption: "Quando ativado, comandos sudo usam a senha salva automaticamente sem pedir confirmação. Requer senha previamente salva."
            ) {
                Toggle("Auto-autorizar comandos sudo", isOn: $sudoAutoAuthorize)
                    .toggleStyle(.switch)
                    .onChange(of: sudoAutoAuthorize) { _, newValue in
                        appState.configStore.sudoAutoAuthorize = newValue
                    }

                if sudoAutoAuthorize {
                    HStack(spacing: 8) {
                        Image(systemName: SudoManager.shared.hasSavedPassword ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(SudoManager.shared.hasSavedPassword ? .green : .orange)
                            .font(.system(size: 12))
                        Text(SudoManager.shared.hasSavedPassword
                             ? "Senha salva — sudo será auto-autorizado"
                             : "Nenhuma senha salva. Execute um comando sudo primeiro e salve a senha.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                if SudoManager.shared.hasSavedPassword {
                    HStack {
                        Spacer()
                        Button("Limpar senha salva", role: .destructive) {
                            SudoManager.shared.clear()
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: - Skills / MCP / Shortcuts wrappers (consistent padding)

    private var skillsContent: some View {
        ScrollView {
            SkillsSettingsView()
                .padding(20)
        }
        .background(NexTheme.bg)
    }

    private var personalizationContent: some View {
        PersonalizationSettingsView()
            .environmentObject(appState)
    }

    private var mcpContent: some View {
        ScrollView {
            MCPSettingsView()
                .environmentObject(appState)
                .padding(20)
        }
        .background(NexTheme.bg)
    }

    private var whatsappContent: some View {
        WhatsAppSettingsSection()
            .environmentObject(appState)
    }

    private var shortcutsContent: some View {
        ScrollView {
            ShortcutsGuideView()
                .padding(20)
        }
        .background(NexTheme.bg)
    }

    // MARK: - Helpers

    private func chooseDefaultDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: defaultDirectory)
        panel.prompt = "Selecionar"
        if panel.runModal() == .OK, let url = panel.url {
            defaultDirectory = url.path
        }
    }

    private func hotKeyDescription() -> String {
        var parts: [String] = []
        let mods = NSEvent.ModifierFlags(rawValue: UInt(appState.configStore.hotKeyModifiers))
        if mods.contains(.control) { parts.append("⌃") }
        if mods.contains(.option) { parts.append("⌥") }
        if mods.contains(.command) { parts.append("⌘") }
        if mods.contains(.shift) { parts.append("⇧") }

        let code = appState.configStore.hotKeyCode
        let keyName: String
        switch code {
        case 50: keyName = "`"
        case 49: keyName = "Space"
        case 36: keyName = "Return"
        case 53: keyName = "Esc"
        default: keyName = "Key(\(code))"
        }
        parts.append(keyName)
        return parts.joined(separator: " ")
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func load() {
        let config = appState.configStore
        ollamaBaseURL = config.ollamaBaseURL
        ollamaModel = config.ollamaModel
        openAIKey = config.openAIAPIKey
        openAIModel = config.openAIModel
        geminiKey = config.geminiAPIKey
        geminiModel = config.geminiModel
        defaultProvider = config.defaultProvider
        defaultApprovalMode = config.defaultApprovalMode
        defaultDirectory = config.defaultDirectory
        askDirectoryOnNewTab = config.askDirectoryOnNewTab
        terminalFontSize = config.terminalFontSize
        launchAtLogin = AppDelegate.launchAtLoginEnabled
        hotKeyEnabled = config.hotKeyEnabled
        hotKeyHideOnFocusLost = config.hotKeyHideOnFocusLost
        cliInstalled = CLIInstaller.shared.isInstalled
        sudoAutoAuthorize = config.sudoAutoAuthorize
    }

    private func save() {
        let config = appState.configStore
        config.ollamaBaseURL = ollamaBaseURL
        config.ollamaModel = ollamaModel
        config.openAIAPIKey = openAIKey
        config.openAIModel = openAIModel
        config.geminiAPIKey = geminiKey
        config.geminiModel = geminiModel
        config.defaultProvider = defaultProvider
        config.defaultApprovalMode = defaultApprovalMode
        config.defaultDirectory = defaultDirectory
        config.askDirectoryOnNewTab = askDirectoryOnNewTab
        config.terminalFontSize = terminalFontSize
        config.sudoAutoAuthorize = sudoAutoAuthorize
    }
}

// MARK: - Reusable Settings Components

private struct SettingsScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(NexTheme.bg)
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    var caption: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
            }

            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(NexTheme.border, lineWidth: 0.5)
                    )
            )

            if let caption {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct HotKeyBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.secondary.opacity(0.15))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(NexTheme.border, lineWidth: 0.5)
                    )
            )
    }
}
