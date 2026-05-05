import SwiftUI
import AppKit
import AVFoundation
import CoreGraphics

/// Painel modal para configurar e controlar uma gravação de áudio/vídeo.
/// Pode ser aberto a partir do file explorer (com pasta atual) ou da top bar
/// (sem pasta — pergunta).
struct RecorderPanel: View {

    /// Pasta sugerida (vinda da aba ativa do explorer). Se `nil`, o painel pede
    /// pra escolher antes de gravar OU pergunta no fim, conforme `askDestinationAfterRecording`.
    let suggestedDirectory: URL?

    /// Quando `true`, o painel grava em pasta temporária e pergunta a pasta de
    /// destino ao terminar (cenário "abriu pelo header, fora de um explorer").
    let askDestinationAfterRecording: Bool

    /// Callback opcional para iniciar a transcrição depois da gravação concluir.
    let onTranscribe: ((URL) -> Void)?

    let onClose: () -> Void

    @StateObject private var controller = MediaRecorderController()
    @State private var selectedMode: RecordingMode = RecordingPreferences.shared.lastMode
    @State private var selectedMicID: String? = RecordingPreferences.shared.lastMicID
    @State private var selectedDisplayID: CGDirectDisplayID?
    @State private var availableMics: [AudioInputDevice] = []
    @State private var availableDisplays: [ScreenRecorder.DisplayChoice] = []
    @State private var outputDirectory: URL?
    @State private var fileBaseName: String = ""
    @State private var errorMessage: String?
    @State private var showFolderPicker = false
    /// URL final escolhida pelo usuário no fim (quando `askDestinationAfterRecording`).
    @State private var resolvedFinalURL: URL?

    init(
        suggestedDirectory: URL?,
        askDestinationAfterRecording: Bool = false,
        onTranscribe: ((URL) -> Void)? = nil,
        onClose: @escaping () -> Void
    ) {
        self.suggestedDirectory = suggestedDirectory
        self.askDestinationAfterRecording = askDestinationAfterRecording
        self.onTranscribe = onTranscribe
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            switch controller.state {
            case .idle, .preparing, .failed:
                setupView
            case .recording, .finalizing:
                liveView
            case .finished(let url):
                finishedView(url: url)
            }
        }
        .frame(width: 460)
        .background(NexTheme.bg)
        .task {
            await loadDevices()
            initializeDefaults()
        }
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                outputDirectory = url
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: controller.state == .recording
                  ? "record.circle.fill"
                  : "record.circle")
                .foregroundColor(controller.state == .recording ? .red : NexTheme.accent)
                .font(.system(size: 16))
            Text("Gravador")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Button {
                Task { await closeFlow() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11))
                    .foregroundColor(NexTheme.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Setup view (modo idle/preparing/failed)

    private var setupView: some View {
        VStack(alignment: .leading, spacing: 14) {
            modeSection
            if selectedMode.needsMic { micSection }
            if selectedMode.isVideo { displaySection }
            outputSection
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }
            Button {
                Task { await startRecording() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "record.circle.fill")
                    Text(controller.state == .preparing ? "Preparando..." : "Iniciar Gravação")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(canStart ? Color.red : Color.gray.opacity(0.4))
                .foregroundColor(.white)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .disabled(!canStart || controller.state == .preparing)
        }
        .padding(14)
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Modo")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(NexTheme.textSecondary)
            VStack(spacing: 4) {
                ForEach(RecordingMode.allCases) { mode in
                    Button { selectedMode = mode } label: {
                        HStack(spacing: 8) {
                            Image(systemName: mode.icon)
                                .font(.system(size: 13))
                                .frame(width: 18)
                                .foregroundColor(selectedMode == mode ? NexTheme.accent : NexTheme.textSecondary)
                            Text(mode.displayName)
                                .font(.system(size: 12))
                                .foregroundColor(NexTheme.textPrimary)
                            Spacer()
                            if selectedMode == mode {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(NexTheme.accent)
                            }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .background(selectedMode == mode ? NexTheme.accent.opacity(0.1) : Color.clear)
                        .cornerRadius(4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var micSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Microfone")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(NexTheme.textSecondary)
            if availableMics.isEmpty {
                Text("Nenhum microfone encontrado")
                    .font(.system(size: 11))
                    .foregroundColor(NexTheme.textSecondary)
            } else {
                Picker("", selection: Binding(
                    get: { selectedMicID ?? availableMics.first?.id ?? "" },
                    set: { selectedMicID = $0 }
                )) {
                    ForEach(availableMics) { device in
                        Text(device.name + (device.isBuiltIn ? " (interno)" : ""))
                            .tag(device.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }
    }

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tela")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(NexTheme.textSecondary)
            if availableDisplays.isEmpty {
                Text("Nenhum display detectado (verifique a permissão de Gravação de Tela)")
                    .font(.system(size: 11))
                    .foregroundColor(NexTheme.textSecondary)
            } else {
                Picker("", selection: Binding(
                    get: { selectedDisplayID ?? availableDisplays.first?.id ?? 0 },
                    set: { selectedDisplayID = $0 }
                )) {
                    ForEach(availableDisplays) { display in
                        Text(display.name).tag(display.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if askDestinationAfterRecording {
                HStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down")
                        .foregroundColor(NexTheme.textSecondary)
                        .font(.system(size: 11))
                    Text("A pasta de destino será escolhida ao parar a gravação.")
                        .font(.system(size: 11))
                        .foregroundColor(NexTheme.textSecondary)
                }
                .padding(.vertical, 4)
            } else {
                Text("Pasta de saída")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(NexTheme.textSecondary)
                HStack(spacing: 6) {
                    Text(outputDirectory?.path ?? "(escolha uma pasta)")
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(NexTheme.surface.opacity(0.6))
                        .cornerRadius(4)
                    Button("Escolher...") { showFolderPicker = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            Text("Nome do arquivo")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(NexTheme.textSecondary)
                .padding(.top, 4)
            TextField("recording-...", text: $fileBaseName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
        }
    }

    // MARK: - Live view (gravando)

    private var liveView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 10, height: 10)
                    .opacity(controller.state == .recording ? 1 : 0.5)
                Text(formattedElapsed)
                    .font(.system(size: 24, weight: .semibold, design: .monospaced))
                    .foregroundColor(NexTheme.textPrimary)
                Spacer()
                Text(selectedMode.displayName)
                    .font(.system(size: 11))
                    .foregroundColor(NexTheme.textSecondary)
            }

            if selectedMode.needsMic {
                levelMeter(label: "Microfone", value: controller.levelMic, color: .blue)
            }
            if selectedMode.needsSystemAudio {
                levelMeter(label: "Sistema", value: controller.levelSystem, color: .green)
            }
            if selectedMode.isVideo {
                Label("Gravando tela...", systemImage: "rectangle.dashed.badge.record")
                    .font(.system(size: 11))
                    .foregroundColor(NexTheme.textSecondary)
            }

            HStack(spacing: 8) {
                Button {
                    Task { await controller.cancel() }
                } label: {
                    Text("Cancelar")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(NexTheme.surface)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)

                Button {
                    Task { _ = await controller.stop() }
                } label: {
                    HStack {
                        Image(systemName: "stop.fill")
                        Text("Parar e Salvar")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.red)
                    .foregroundColor(.white)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(controller.state == .finalizing)
            }
        }
        .padding(14)
    }

    private func levelMeter(label: String, value: Float, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.system(size: 10))
                    .foregroundColor(NexTheme.textSecondary)
                Spacer()
                Text(String(format: "%.0f%%", min(1, max(0, value)) * 100))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(NexTheme.textSecondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(color.opacity(0.15))
                    Rectangle()
                        .fill(color.opacity(0.85))
                        .frame(width: CGFloat(min(1, max(0, value))) * geo.size.width)
                }
            }
            .frame(height: 6)
            .cornerRadius(3)
        }
    }

    // MARK: - Finished view

    private func finishedView(url: URL) -> some View {
        // Se a sheet foi aberta sem pasta (header), exigimos que o usuário
        // escolha uma antes das demais ações.
        let displayURL = resolvedFinalURL ?? url
        let needsDestination = askDestinationAfterRecording && resolvedFinalURL == nil

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: needsDestination ? "tray.and.arrow.down.fill" : "checkmark.circle.fill")
                    .foregroundColor(needsDestination ? NexTheme.accent : .green)
                    .font(.system(size: 18))
                VStack(alignment: .leading, spacing: 2) {
                    Text(needsDestination ? "Onde deseja salvar?" : "Gravação concluída")
                        .font(.system(size: 13, weight: .semibold))
                    HStack(spacing: 4) {
                        Text(displayURL.lastPathComponent)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(NexTheme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                            .font(.system(size: 9))
                            .foregroundColor(NexTheme.textSecondary.opacity(0.6))
                            .help("Arraste o nome do arquivo para outro app (Finder, Mail, Slack, etc.)")
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .onDrag { NSItemProvider(object: displayURL as NSURL) }

            if needsDestination {
                Text("Sua gravação está pronta em uma pasta temporária. Escolha onde deseja arquivá-la.")
                    .font(.system(size: 11))
                    .foregroundColor(NexTheme.textSecondary)
                HStack {
                    Button {
                        Task { await chooseDestinationAndMove(currentURL: url) }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "folder")
                            Text("Salvar Como...")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button {
                        Task {
                            // Cancelar = descarta o arquivo temporário.
                            try? FileManager.default.removeItem(at: url)
                            onClose()
                        }
                    } label: {
                        Text("Descartar")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                HStack(spacing: 8) {
                    Button("Mostrar no Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([displayURL])
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if MediaKind.of(displayURL) == .audio || MediaKind.of(displayURL) == .video {
                        Button {
                            onTranscribe?(displayURL)
                            onClose()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "text.bubble")
                                Text("Transcrever Agora")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }

                    Spacer()

                    Button {
                        resolvedFinalURL = nil
                        controller.reset()
                    } label: {
                        Text("Nova Gravação")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Fechar") { onClose() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(14)
    }

    /// Apresenta um `NSSavePanel` para o usuário escolher a pasta/nome final
    /// e move o arquivo gravado para lá.
    @MainActor
    private func chooseDestinationAndMove(currentURL: URL) async {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowsOtherFileTypes = false
        panel.title = "Salvar Gravação"
        panel.nameFieldStringValue = currentURL.lastPathComponent
        panel.allowedContentTypes = []
        if let lastDir = RecordingPreferences.shared.lastOutputDirectory
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
            panel.directoryURL = lastDir
        }

        let response = panel.runModal()
        guard response == .OK, var dest = panel.url else { return }

        // Garante que a extensão final bate com o arquivo gravado.
        let originalExt = currentURL.pathExtension
        if dest.pathExtension.lowercased() != originalExt.lowercased() {
            dest = dest.appendingPathExtension(originalExt)
        }

        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: currentURL, to: dest)
            RecordingPreferences.shared.lastOutputDirectory = dest.deletingLastPathComponent()
            resolvedFinalURL = dest
        } catch {
            errorMessage = "Falha ao salvar: \(error.localizedDescription)"
        }
    }

    // MARK: - Actions

    private var canStart: Bool {
        outputDirectory != nil && !controller.state.isActive
    }

    private var formattedElapsed: String {
        let total = Int(controller.elapsed)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%02d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    private func loadDevices() async {
        availableMics = AudioInputDevices.list()
        if selectedMicID == nil {
            selectedMicID = availableMics.first?.id
        }
        if #available(macOS 13.0, *) {
            do {
                availableDisplays = try await ScreenRecorder.listDisplays()
                if selectedDisplayID == nil {
                    selectedDisplayID = availableDisplays.first?.id
                }
            } catch {
                NexLog.general.warning("Falha ao listar displays: \(error.localizedDescription)")
            }
        }
    }

    private func initializeDefaults() {
        if outputDirectory == nil {
            if askDestinationAfterRecording {
                // Pasta temporária dedicada — só existe durante a gravação.
                outputDirectory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("nexify_pending_recordings", isDirectory: true)
                if let dir = outputDirectory {
                    try? FileManager.default.createDirectory(
                        at: dir, withIntermediateDirectories: true
                    )
                }
            } else {
                outputDirectory = suggestedDirectory
                    ?? RecordingPreferences.shared.lastOutputDirectory
                    ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            }
        }
        if fileBaseName.isEmpty {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            fileBaseName = "recording-\(f.string(from: Date()))"
        }
    }

    private func startRecording() async {
        errorMessage = nil
        guard let dir = outputDirectory else {
            errorMessage = "Escolha uma pasta de saída."
            return
        }
        do {
            try await controller.start(
                mode: selectedMode,
                micID: selectedMicID,
                displayID: selectedDisplayID,
                outputDirectory: dir,
                baseName: fileBaseName
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func closeFlow() async {
        if controller.state.isActive {
            await controller.cancel()
        }
        onClose()
    }
}
