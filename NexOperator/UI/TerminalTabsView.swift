import SwiftUI

struct TerminalTabsView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var presetStore = MosaicPresetStore.shared
    @StateObject private var recentStore = RecentDirectoriesStore.shared
    @State private var showSavePresetAlert = false
    @State private var newPresetName = ""
    @State private var detectedClipboardPath: String?
    @State private var isShowingRemoteExplorer = false
    @State private var isShowingRecorder = false
    @State private var pendingTranscriptionURL: URL?
    @State private var transcriptionMessage: String?
    @State private var showTranscriptionAlert = false

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(appState.tabs) { tab in
                        let isRunning = appState.agentState(for: tab.id).isAgentRunning
                        TabItemView(
                            tab: tab,
                            isActive: tab.id == appState.activeTabId,
                            isAgentRunning: isRunning,
                            onSelect: {
                                appState.activeTabId = tab.id
                                appState.tabStateVersion += 1
                            },
                            onClose: { appState.closeTab(tab.id) }
                        )
                        .contextMenu { tabContextMenu(for: tab) }
                    }

                    newTabMenu
                }
                .padding(.horizontal, 8)
            }

            Spacer()

            HStack(spacing: NexTheme.buttonSpacing) {
                Button {
                    isShowingRecorder = true
                } label: {
                    Image(systemName: "record.circle")
                        .font(.system(size: NexTheme.iconSizeSmall))
                        .foregroundColor(.secondary)
                        .frame(width: NexTheme.hitTargetSmall, height: NexTheme.hitTargetSmall)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Gravar áudio/tela (escolhe pasta no fim)")

                Button {
                    isShowingRemoteExplorer = true
                } label: {
                    Image(systemName: "globe")
                        .font(.system(size: NexTheme.iconSizeSmall))
                        .foregroundColor(.secondary)
                        .frame(width: NexTheme.hitTargetSmall, height: NexTheme.hitTargetSmall)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Explorar Repositórios Remotos")
            }
            .padding(.trailing, 8)
        }
        .frame(height: 38)
        .background(.bar)
        .sheet(isPresented: $isShowingRemoteExplorer) {
            RemoteExplorerView(defaultClonePath: appState.activeTab?.currentDirectory)
        }
        .sheet(isPresented: $isShowingRecorder) {
            RecorderPanel(
                suggestedDirectory: nil,
                askDestinationAfterRecording: true,
                onTranscribe: { url in
                    isShowingRecorder = false
                    runHeaderTranscription(url: url)
                },
                onClose: { isShowingRecorder = false }
            )
        }
        .alert(
            transcriptionMessage ?? "Transcrição",
            isPresented: $showTranscriptionAlert,
            presenting: transcriptionMessage
        ) { _ in
            Button("OK", role: .cancel) { transcriptionMessage = nil }
        } message: { msg in
            Text(msg)
        }
        .alert("Salvar Layout", isPresented: $showSavePresetAlert) {
            TextField("Nome do layout", text: $newPresetName)
            Button("Cancelar", role: .cancel) {}
            Button("Salvar") {
                saveCurrentLayout()
            }
        } message: {
            Text("Escolha um nome para este layout de mosaico.")
        }
    }

    private func runHeaderTranscription(url: URL) {
        let apiKey = ConfigStore.shared.openAIAPIKey
        guard !apiKey.isEmpty else {
            transcriptionMessage = "Chave da OpenAI não configurada. Defina em Configurações → IA."
            showTranscriptionAlert = true
            return
        }
        transcriptionMessage = "Iniciando transcrição de \(url.lastPathComponent)... (pode demorar alguns minutos)"
        showTranscriptionAlert = true
        Task {
            do {
                let output = try await MediaTranscriptionPipeline.runFullTranscription(for: url) { _ in }
                await MainActor.run {
                    transcriptionMessage = "Transcrição salva: \(output.lastPathComponent)"
                    showTranscriptionAlert = true
                    NSWorkspace.shared.activateFileViewerSelecting([output])
                }
            } catch {
                await MainActor.run {
                    transcriptionMessage = "Falha na transcrição: \(error.localizedDescription)"
                    showTranscriptionAlert = true
                }
            }
        }
    }

    private func saveCurrentLayout() {
        guard let tab = appState.activeTab,
              let layout = tab.mosaicLayout else { return }
        let name = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let template = LayoutTemplate.from(node: layout)
        let preset = MosaicPreset(name: name, layout: template)
        presetStore.save(preset)
        newPresetName = ""
    }

    // MARK: - Tab Context Menu

    @ViewBuilder
    private func tabContextMenu(for tab: TerminalTab) -> some View {
        let tabIndex = appState.tabs.firstIndex(where: { $0.id == tab.id }) ?? 0
        let tabCount = appState.tabs.count

        Button {
            appState.togglePin(tab.id)
        } label: {
            Label(
                tab.isPinned ? "Desafixar Aba" : "Fixar Aba",
                systemImage: tab.isPinned ? "pin.slash.fill" : "pin.fill"
            )
        }

        Divider()

        Button("Fechar") {
            appState.closeTab(tab.id)
        }
        .keyboardShortcut("w", modifiers: .command)
        .disabled(tab.isPinned)

        Button("Fechar Abas à Direita") {
            appState.closeTabsToRight(of: tab.id)
        }
        .disabled(tabIndex >= tabCount - 1)

        Button("Fechar Abas à Esquerda") {
            appState.closeTabsToLeft(of: tab.id)
        }
        .disabled(tabIndex == 0)

        Button("Fechar Outras") {
            appState.closeOtherTabs(except: tab.id)
        }
        .disabled(tabCount <= 1)

        Divider()

        Button("Duplicar Aba") {
            appState.createTab(directory: tab.currentDirectory)
        }

        if tab.isMosaic, tab.mosaicLayout != nil {
            Divider()
            Button {
                newPresetName = tab.title
                showSavePresetAlert = true
            } label: {
                Label("Salvar Layout como Preset...", systemImage: "square.and.arrow.down")
            }
        }
    }

    // MARK: - New Tab Menu

    private var newTabMenu: some View {
        Menu {
            Button {
                appState.addTab()
            } label: {
                Label("Novo Terminal", systemImage: "terminal.fill")
            }
            Button {
                appState.addExplorerTab()
            } label: {
                Label("Novo Explorer", systemImage: "folder.fill")
            }
            Button {
                appState.addGitTab()
            } label: {
                Label("Novo Git", systemImage: "arrow.triangle.branch")
            }
            Button {
                appState.addDiskAnalyzerTab()
            } label: {
                Label("Disk Analyzer", systemImage: "chart.pie.fill")
            }
            Button {
                appState.addWhatsAppTab()
            } label: {
                Label("WhatsApp", systemImage: "message.fill")
            }

            Divider()

            if let path = detectedClipboardPath {
                let folderName = URL(fileURLWithPath: path).lastPathComponent
                Section("Clipboard: \(folderName)") {
                    Button {
                        appState.createTab(directory: path)
                    } label: {
                        Label("Terminal", systemImage: "terminal.fill")
                    }
                    Button {
                        appState.addExplorerTab(directory: path)
                    } label: {
                        Label("Explorer", systemImage: "folder.fill")
                    }
                    Button {
                        appState.addGitTab(directory: path)
                    } label: {
                        Label("Git", systemImage: "arrow.triangle.branch")
                    }
                    Button {
                        appState.addDiskAnalyzerTab(directory: path)
                    } label: {
                        Label("Disk Analyzer", systemImage: "chart.pie.fill")
                    }
                }

                Divider()
            }

            Button {
                pickFolder { path in appState.createTab(directory: path) }
            } label: {
                Label("Escolher Pasta...", systemImage: "folder.badge.plus")
            }

            if !recentStore.recents.isEmpty {
                Menu {
                    ForEach(recentStore.recents.prefix(10)) { recent in
                        Menu {
                            Button {
                                appState.createTab(directory: recent.path)
                            } label: {
                                Label("Terminal", systemImage: "terminal.fill")
                            }
                            Button {
                                appState.addExplorerTab(directory: recent.path)
                            } label: {
                                Label("Explorer", systemImage: "folder.fill")
                            }
                            Button {
                                appState.addGitTab(directory: recent.path)
                            } label: {
                                Label("Git", systemImage: "arrow.triangle.branch")
                            }
                            Button {
                                appState.addDiskAnalyzerTab(directory: recent.path)
                            } label: {
                                Label("Disk Analyzer", systemImage: "chart.pie.fill")
                            }
                        } label: {
                            Label(recent.name, systemImage: "folder")
                        }
                    }

                    Divider()

                    Button(role: .destructive) {
                        recentStore.clear()
                    } label: {
                        Label("Limpar Recentes", systemImage: "trash")
                    }
                } label: {
                    Label("Recentes", systemImage: "clock")
                }
            }

            Divider()

            Menu {
                Section("Layouts") {
                    Button {
                        appState.addMosaicTab(layout: .twoColumns(), title: "2 Terminais")
                    } label: {
                        Label("2 Colunas", systemImage: "rectangle.split.2x1")
                    }
                    Button {
                        appState.addMosaicTab(layout: .terminalAndExplorer(), title: "Terminal + Explorer")
                    } label: {
                        Label("Terminal + Explorer", systemImage: "rectangle.split.2x1.fill")
                    }
                    Button {
                        appState.addMosaicTab(layout: .threePane(), title: "3 Painéis")
                    } label: {
                        Label("3 Painéis", systemImage: "rectangle.split.1x2.fill")
                    }
                    Button {
                        appState.addMosaicTab(layout: .grid2x2(), title: "Grid 2x2")
                    } label: {
                        Label("Grid 2x2", systemImage: "rectangle.split.2x2")
                    }
                }

                if !presetStore.presets.isEmpty {
                    Section("Salvos") {
                        ForEach(presetStore.presets) { preset in
                            Button {
                                let dir = appState.configStore.defaultDirectory
                                let layout = preset.layout.instantiate(directory: dir)
                                appState.addMosaicTab(layout: layout, title: preset.name)
                            } label: {
                                Label(preset.name, systemImage: preset.icon)
                            }
                        }
                    }
                }

                Divider()

                if let activeTab = appState.activeTab, activeTab.isMosaic, activeTab.mosaicLayout != nil {
                    Button {
                        showSavePresetAlert = true
                        newPresetName = activeTab.title
                    } label: {
                        Label("Salvar Layout Atual...", systemImage: "square.and.arrow.down")
                    }
                }

                if !presetStore.presets.isEmpty {
                    Menu {
                        ForEach(presetStore.presets) { preset in
                            Button(role: .destructive) {
                                presetStore.delete(preset.id)
                            } label: {
                                Label("Remover \"\(preset.name)\"", systemImage: "trash")
                            }
                        }
                    } label: {
                        Label("Gerenciar Salvos...", systemImage: "gear")
                    }
                }
            } label: {
                Label("Novo Mosaico", systemImage: "rectangle.split.2x2.fill")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: NexTheme.iconSizeSmall, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: NexTheme.hitTargetSmall, height: NexTheme.hitTargetSmall)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .frame(width: NexTheme.hitTargetSmall)
        .onHover { hovering in
            if hovering { refreshClipboardPath() }
        }
    }

    private func refreshClipboardPath() {
        guard let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            detectedClipboardPath = nil
            return
        }
        let expanded = (text as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
            detectedClipboardPath = expanded
        } else {
            detectedClipboardPath = nil
        }
    }

    private func pickFolder(then action: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Abrir"
        if panel.runModal() == .OK, let url = panel.url {
            action(url.path)
        }
    }

}

struct TabItemView: View {
    let tab: TerminalTab
    let isActive: Bool
    let isAgentRunning: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false
    @State private var isGitRepo = false

    var body: some View {
        HStack(spacing: 5) {
            if tab.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8))
                    .foregroundColor(isActive ? .accentColor : .secondary.opacity(0.5))
                    .rotationEffect(.degrees(-45))
                    .frame(width: 10)
            }

            if isAgentRunning {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
                    .frame(width: 10, height: 10)
            } else {
                Image(systemName: tab.tabIcon)
                    .font(.system(size: 10))
                    .foregroundColor(isActive ? .accentColor : .secondary.opacity(0.6))
                    .frame(width: 12)
            }

            if isGitRepo && !tab.isGit {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.green)
            }

            Text(tab.title)
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundColor(isActive ? .primary : .secondary)

            if !tab.isPinned && (isHovered || isActive) {
                Button { onClose() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, tab.isPinned ? 8 : 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive
                    ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.15)
                    : isHovered ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor).opacity(0.5) : Color.clear
                )
        )
        .overlay(
            tab.isPinned
                ? RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor.opacity(isActive ? 0.3 : 0.1), lineWidth: 0.5)
                : nil
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { isHovered = $0 }
        .onAppear { checkGit() }
        .onChange(of: tab.currentDirectory) { _, _ in checkGit() }
    }

    private func checkGit() {
        let gitPath = URL(fileURLWithPath: tab.currentDirectory).appendingPathComponent(".git").path
        isGitRepo = FileManager.default.fileExists(atPath: gitPath)
    }
}
