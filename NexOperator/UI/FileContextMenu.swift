import SwiftUI
import QuickLookUI

struct FileContextMenu: View {
    @EnvironmentObject var appState: AppState
    let item: FileItem
    let provider: FileItemProvider
    /// All currently selected items (or just `[item]` when nothing is selected).
    var selectedItems: [FileItem] = []
    /// Directory where batch outputs (PDF, combined images, zips) are written.
    var currentDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    let onRename: () -> Void
    let onAttach: () -> Void
    var onDelete: (() -> Void)?
    var onPermanentDelete: (() -> Void)?
    /// Called with a user-facing message after a batch action runs (success or error).
    var onBatchResult: ((String) -> Void)?

    private func mergeApps(suggested: [OpenWithApp], system: [OpenWithApp]) -> [OpenWithApp] {
        var seen = Set<String>()
        var result: [OpenWithApp] = []
        for app in suggested + system {
            guard !seen.contains(app.id) else { continue }
            seen.insert(app.id)
            result.append(app)
        }
        return result
    }

    private var targetDirectory: String {
        item.isDirectory ? item.url.path : item.url.deletingLastPathComponent().path
    }

    /// Resolved selection for batch ops — never empty, falls back to `item`.
    private var effectiveSelection: [FileItem] {
        selectedItems.isEmpty ? [item] : selectedItems
    }

    private var imageURLs: [URL] {
        effectiveSelection.map(\.url).filter { BatchFileActions.isImage($0) }
    }

    private var pdfOrImageURLs: [URL] {
        effectiveSelection.map(\.url).filter {
            BatchFileActions.isImage($0) || BatchFileActions.isPDF($0)
        }
    }

    private var canBatch: Bool { effectiveSelection.count > 1 }

    private var mediaKind: MediaKind {
        item.isDirectory ? .unsupported : MediaKind.of(item.url)
    }

    /// `true` quando o item é uma entry virtual dentro de um archive — nesse
    /// caso só permitimos ações de leitura (extração, copiar path, etc).
    /// Mutações no filesystem são bloqueadas porque a "URL" da entry é
    /// virtual.
    private var isArchiveEntry: Bool { item.archiveOrigin != nil }

    var body: some View {
        Group {
            if isArchiveEntry {
                archiveEntryMenu
            } else {
                fileSystemMenu
            }
        }
    }

    /// Menu reduzido pra entries virtuais dentro de archives (zip/rar/7z).
    /// Não permite renomear, mover, deletar, recortar ou alterar tags —
    /// nada do filesystem real funciona em URLs virtuais.
    @ViewBuilder
    private var archiveEntryMenu: some View {
        Button("Abrir") {
            if let origin = item.archiveOrigin {
                if origin.isDirectory {
                    provider.navigateInsideArchive(toSubPath: origin.internalPath)
                } else {
                    extractSingleEntry(origin: origin)
                }
            }
        }

        if let origin = item.archiveOrigin, !origin.isDirectory {
            Button("Extrair este arquivo...") {
                extractSingleEntry(origin: origin)
            }
        }

        Divider()

        Button("Copiar nome") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.name, forType: .string)
        }
        Button("Copiar caminho dentro do archive") {
            if let origin = item.archiveOrigin {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(origin.internalPath, forType: .string)
            }
        }
    }

    @ViewBuilder
    private var fileSystemMenu: some View {
        Group {
            Button("Abrir") {
                if item.isDirectory {
                    provider.navigate(to: item.url)
                } else {
                    FileItemProvider.openFile(item.url)
                }
            }

            // Archive: opções específicas pra zip/rar/7z. Abrir como Pasta
            // entra no archive sem extrair; Extrair Aqui descompacta ao
            // lado; Extrair Para... abre seletor de destino.
            if item.isArchive {
                Button("Abrir como Pasta") {
                    Task {
                        do { try await provider.enterArchive(item.url) }
                        catch { onBatchResult?("Falha ao abrir archive: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)") }
                    }
                }
                Button("Extrair Aqui") {
                    extractArchiveHere()
                }
                Button("Extrair Para...") {
                    extractArchiveToChosen()
                }
                Divider()
            }

            Button("Abrir no Finder") {
                FileItemProvider.openInFinder(item.url)
            }

            if item.isPreviewable {
                Button("Quick Look") {
                    showQuickLook(url: item.url)
                }
                .keyboardShortcut(" ", modifiers: [])
            }

            Divider()

            Menu("Abrir com...") {
                Button("VS Code") {
                    ExternalEditorLauncher.open(path: item.url.path, editor: .vscode)
                }
                Button("Cursor") {
                    ExternalEditorLauncher.open(path: item.url.path, editor: .cursor)
                }

                let suggested = item.isDirectory ? [] : ExternalEditorLauncher.suggestedApps(for: item.fileExtension)
                let systemApps = ExternalEditorLauncher.installedAppsForFile(url: item.url)
                let allApps = mergeApps(suggested: suggested, system: systemApps)

                if !allApps.isEmpty {
                    Divider()
                    ForEach(allApps) { app in
                        Button {
                            app.open(url: item.url)
                        } label: {
                            Label(app.name, systemImage: app.icon)
                        }
                    }
                }
            }

            if item.isDirectory {
                Button { appState.createTab(directory: item.url.path) } label: {
                    Label("Terminal", systemImage: "terminal.fill")
                }
                Button { appState.addExplorerTab(directory: item.url.path) } label: {
                    Label("Explorer", systemImage: "folder.fill")
                }
                Button { appState.addGitTab(directory: item.url.path) } label: {
                    Label("Git", systemImage: "arrow.triangle.branch")
                }
                Button { appState.addDiskAnalyzerTab(directory: item.url.path) } label: {
                    Label("Analisar Espaço em Disco", systemImage: "chart.pie.fill")
                }
            } else {
                Button { appState.createTab(directory: targetDirectory) } label: {
                    Label("Terminal", systemImage: "terminal.fill")
                }
                Button { appState.addGitTab(directory: targetDirectory) } label: {
                    Label("Git", systemImage: "arrow.triangle.branch")
                }
            }

            Divider()

            Button("Copiar Path") {
                FileItemProvider.copyPath(item.url)
            }

            Button("Copiar") {
                FileItemProvider.copyFilesToClipboard([item.url], operation: .copy)
            }
            .keyboardShortcut("c", modifiers: .command)

            Button("Recortar") {
                FileItemProvider.copyFilesToClipboard([item.url], operation: .cut)
            }
            .keyboardShortcut("x", modifiers: .command)

            if FileItemProvider.hasClipboardFiles {
                Button("Colar Aqui") {
                    let dest = item.isDirectory ? item.url : item.url.deletingLastPathComponent()
                    try? provider.pasteFiles(to: dest)
                }
                .keyboardShortcut("v", modifiers: .command)
            }

            Button(canBatch ? "Anexar Selecionados ao Prompt" : "Anexar ao Prompt") {
                onAttach()
            }

            if canBatch || !imageURLs.isEmpty || !pdfOrImageURLs.isEmpty {
                batchMenu
            }

            if mediaKind != .unsupported {
                mediaMenu
            }

            Divider()

            moveToRecentMenu

            Button("Renomear") {
                onRename()
            }

            Button("Duplicar") {
                try? provider.duplicateItem(item)
            }

            Divider()

            Menu("Tags") {
                ForEach(MacOSTag.allTags) { tag in
                    let currentTags = item.tags
                    let hasTag = currentTags.contains(tag.id)
                    Button {
                        var newTags = currentTags
                        if hasTag {
                            newTags.removeAll { $0 == tag.id }
                        } else {
                            newTags.append(tag.id)
                        }
                        try? provider.setTags(for: item, tags: newTags)
                    } label: {
                        HStack {
                            Circle()
                                .fill(tag.color)
                                .frame(width: 8, height: 8)
                            Text(tag.name)
                            if hasTag {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                if !item.tags.isEmpty {
                    Divider()
                    Button("Remover Todas") {
                        try? provider.setTags(for: item, tags: [])
                    }
                }
            }

            let isFav = FavoritesStore.shared.isFavorite(path: item.url.path)
            Button(isFav ? "Remover dos Favoritos" : "Adicionar aos Favoritos") {
                FavoritesStore.shared.toggleFavorite(path: item.url.path, name: item.name, icon: item.sfSymbol)
            }

            Divider()

            Button {
                if let onDelete {
                    onDelete()
                } else {
                    try? provider.deleteItems([item])
                }
            } label: {
                Label("Mover para Lixeira", systemImage: "trash")
            }

            Button(role: .destructive) {
                if let onPermanentDelete {
                    onPermanentDelete()
                } else {
                    try? provider.permanentDeleteItems([item])
                }
            } label: {
                Label("Excluir Permanentemente", systemImage: "trash.slash")
            }
        }
    }

    // MARK: - Move to recent

    /// Lists `RecentDirectoriesStore.shared.recents` (excluding the current
    /// directory and the source's own parent) and moves the effective
    /// selection there with `provider.moveItems(_:to:)`.
    @ViewBuilder
    private var moveToRecentMenu: some View {
        let store = RecentDirectoriesStore.shared
        let sourceParents = Set(effectiveSelection.map { $0.url.deletingLastPathComponent().standardizedFileURL.path })
        let currentDirPath = provider.currentURL.standardizedFileURL.path

        let candidates: [RecentDirectory] = store.recents.filter { rec in
            let stdPath = (rec.path as NSString).standardizingPath
            // Esconde destinos sem sentido: o diretório atual e o pai dos
            // arquivos selecionados (mover pra onde já está = no-op).
            if stdPath == currentDirPath { return false }
            if sourceParents.contains(stdPath) { return false }
            // Garantir que a pasta ainda existe no disco
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: stdPath, isDirectory: &isDir) && isDir.boolValue
        }

        if candidates.isEmpty {
            // Mostra item desabilitado pra usuário entender por quê.
            Menu("Mover para recentes…") {
                Text("Nenhuma pasta recente disponível")
                    .font(.system(size: 11))
                    .foregroundColor(NexTheme.textSecondary)
            }
        } else {
            Menu("Mover para recentes…") {
                ForEach(candidates.prefix(15)) { rec in
                    Button {
                        moveSelectionToRecent(rec)
                    } label: {
                        HStack {
                            Image(systemName: "folder.fill")
                            Text(rec.name)
                            Spacer()
                            Text(shortPath(rec.path))
                                .foregroundColor(.secondary)
                        }
                    }
                    .help(rec.path)
                }
                Divider()
                Text("\(effectiveSelection.count) arquivo(s) serão movidos")
                    .font(.system(size: 10))
                    .foregroundColor(NexTheme.textSecondary)
            }
        }
    }

    private func moveSelectionToRecent(_ rec: RecentDirectory) {
        let destination = URL(fileURLWithPath: (rec.path as NSString).standardizingPath)
        do {
            try provider.moveItems(effectiveSelection, to: destination)
            onBatchResult?("\(effectiveSelection.count) item(ns) movido(s) para \(rec.name)")
        } catch {
            onBatchResult?("Falha ao mover: \(error.localizedDescription)")
        }
    }

    private func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    // MARK: - Batch Menu

    @ViewBuilder
    private var batchMenu: some View {
        let count = effectiveSelection.count
        let label = count > 1 ? "Em Lote (\(count) itens)" : "Ações Avançadas"

        Menu(label) {
            if !pdfOrImageURLs.isEmpty {
                Button {
                    runMergePDF()
                } label: {
                    Label("Juntar em PDF", systemImage: "doc.richtext")
                }
            }

            if imageURLs.count > 1 {
                Menu {
                    Button("Vertical") { runCombineImages(.vertical) }
                    Button("Horizontal") { runCombineImages(.horizontal) }
                    Button("Grade") { runCombineImages(.grid) }
                } label: {
                    Label("Combinar Imagens", systemImage: "rectangle.3.group")
                }
            }

            if !imageURLs.isEmpty {
                Button {
                    runAnalyzeWithAI()
                } label: {
                    Label("Analisar com IA", systemImage: "sparkles")
                }
            }

            if canBatch {
                Button {
                    runCompressZip()
                } label: {
                    Label("Comprimir em ZIP", systemImage: "doc.zipper")
                }
            }
        }
    }

    private func runMergePDF() {
        let urls = pdfOrImageURLs
        Task.detached {
            do {
                let output = try BatchFileActions.mergeToPDF(
                    urls: urls,
                    outputDirectory: currentDirectory
                )
                await MainActor.run {
                    onBatchResult?("PDF criado: \(output.lastPathComponent)")
                    NSWorkspace.shared.activateFileViewerSelecting([output])
                }
            } catch {
                await MainActor.run {
                    onBatchResult?("Falha ao gerar PDF: \(error.localizedDescription)")
                }
            }
        }
    }

    private func runCombineImages(_ layout: BatchFileActions.CombineLayout) {
        let urls = imageURLs
        Task.detached {
            do {
                let output = try BatchFileActions.combineImages(
                    urls: urls,
                    layout: layout,
                    outputDirectory: currentDirectory
                )
                await MainActor.run {
                    onBatchResult?("Imagem combinada: \(output.lastPathComponent)")
                    NSWorkspace.shared.activateFileViewerSelecting([output])
                }
            } catch {
                await MainActor.run {
                    onBatchResult?("Falha ao combinar imagens: \(error.localizedDescription)")
                }
            }
        }
    }

    private func runCompressZip() {
        let urls = effectiveSelection.map(\.url)
        let baseName = urls.count == 1
            ? urls[0].deletingPathExtension().lastPathComponent
            : "arquivos"
        Task.detached {
            do {
                let output = try BatchFileActions.compressToZip(
                    urls: urls,
                    outputDirectory: currentDirectory,
                    baseName: baseName
                )
                await MainActor.run {
                    onBatchResult?("ZIP criado: \(output.lastPathComponent)")
                    NSWorkspace.shared.activateFileViewerSelecting([output])
                }
            } catch {
                await MainActor.run {
                    onBatchResult?("Falha ao criar ZIP: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Media Menu (Áudio / Transcrição)

    @ViewBuilder
    private var mediaMenu: some View {
        Menu("Mídia") {
            if mediaKind == .video {
                Button {
                    runExtractAudio()
                } label: {
                    Label("Separar Áudio do Vídeo", systemImage: "waveform.path")
                }
            }

            Button {
                runFullTranscription()
            } label: {
                Label("Gerar Transcrição Completa", systemImage: "text.bubble")
            }
        }
    }

    private func runExtractAudio() {
        let url = item.url
        onBatchResult?("Extraindo áudio de \(url.lastPathComponent)...")
        Task {
            do {
                let output = try await MediaTranscriptionPipeline.extractAudioOnly(for: url) { _ in }
                await MainActor.run {
                    onBatchResult?("Áudio salvo: \(output.lastPathComponent)")
                    NSWorkspace.shared.activateFileViewerSelecting([output])
                }
            } catch {
                await MainActor.run {
                    onBatchResult?("Falha ao extrair áudio: \(error.localizedDescription)")
                }
            }
        }
    }

    private func runFullTranscription() {
        let url = item.url
        let apiKey = ConfigStore.shared.openAIAPIKey
        guard !apiKey.isEmpty else {
            onBatchResult?("Chave da OpenAI não configurada. Defina em Configurações → IA.")
            return
        }

        onBatchResult?("Iniciando transcrição de \(url.lastPathComponent)... (pode demorar alguns minutos)")
        Task {
            do {
                let output = try await MediaTranscriptionPipeline.runFullTranscription(for: url) { step in
                    NexLog.ai.info("Transcrição: \(step.description, privacy: .public)")
                }
                await MainActor.run {
                    onBatchResult?("Transcrição salva: \(output.lastPathComponent)")
                    NSWorkspace.shared.activateFileViewerSelecting([output])
                }
            } catch {
                await MainActor.run {
                    onBatchResult?("Falha na transcrição: \(error.localizedDescription)")
                }
            }
        }
    }

    private func runAnalyzeWithAI() {
        let urls = imageURLs
        let attachments = urls.compactMap { FileAttachmentExtractor.extract(from: $0) }
        guard !attachments.isEmpty else {
            onBatchResult?("Nenhuma imagem válida para analisar.")
            return
        }
        let prompt = attachments.count == 1
            ? "Analise esta imagem e descreva o conteúdo, detalhes técnicos e qualquer informação útil."
            : "Analise estas \(attachments.count) imagens. Descreva cada uma e indique semelhanças/diferenças relevantes."
        appState.startAgentExecution(prompt, attachments: attachments)
    }

    private func showQuickLook(url: URL) {
        guard let window = NSApp.keyWindow else { return }
        let panel = QLPreviewPanel.shared()!
        let delegate = QuickLookCoordinator(url: url)
        objc_setAssociatedObject(panel, "qlCoordinator", delegate, .OBJC_ASSOCIATION_RETAIN)
        panel.dataSource = delegate
        panel.delegate = delegate
        panel.makeKeyAndOrderFront(nil)
        panel.center()
    }

    // MARK: - Archive actions

    /// Extrai o archive `item.url` numa pasta com o mesmo nome (sem extensão)
    /// dentro do diretório atual. Comportamento "Extract Here" do Windows.
    private func extractArchiveHere() {
        let baseName = item.url.deletingPathExtension().lastPathComponent
        let dest = currentDirectory.appendingPathComponent(baseName, isDirectory: true)
        let archive = item.url
        Task {
            do {
                try await ArchiveService.extractAll(from: archive, to: dest)
                await MainActor.run {
                    onBatchResult?("Extraído em \(dest.lastPathComponent)/")
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                }
            } catch {
                await MainActor.run {
                    onBatchResult?("Falha ao extrair: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
                }
            }
        }
    }

    /// Abre seletor de pasta e extrai o archive lá dentro, em uma sub-pasta
    /// com o nome do archive.
    private func extractArchiveToChosen() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = currentDirectory
        panel.prompt = "Extrair Aqui"
        panel.message = "Escolha onde extrair \(item.name)"
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        let baseName = item.url.deletingPathExtension().lastPathComponent
        let dest = chosen.appendingPathComponent(baseName, isDirectory: true)
        let archive = item.url
        Task {
            do {
                try await ArchiveService.extractAll(from: archive, to: dest)
                await MainActor.run {
                    onBatchResult?("Extraído em \(chosen.lastPathComponent)/\(baseName)/")
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                }
            } catch {
                await MainActor.run {
                    onBatchResult?("Falha ao extrair: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
                }
            }
        }
    }

    /// Extrai UMA entry específica (estamos dentro de um archive). Pede
    /// destino via NSSavePanel — usuário pode renomear na hora.
    private func extractSingleEntry(origin: ArchiveOrigin) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.name
        panel.directoryURL = currentDirectory
        panel.message = "Extrair \(item.name)"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let entry = ArchiveEntry(
            path: origin.internalPath, isDirectory: false,
            size: item.size, modified: item.modifiedDate
        )
        let archive = origin.archiveURL
        Task {
            do {
                try await ArchiveService.extractEntry(entry, from: archive, to: dest)
                await MainActor.run {
                    onBatchResult?("Extraído: \(dest.lastPathComponent)")
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                }
            } catch {
                await MainActor.run {
                    onBatchResult?("Falha ao extrair: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - Preview support on FileItem

extension FileItem {
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "svg", "webp", "ico", "heic", "heif",
        "tiff", "tif", "bmp", "raw", "cr2", "nef", "arw"
    ]

    private static let previewableExtensions: Set<String> = imageExtensions.union([
        "pdf", "mp4", "mov", "avi", "mkv", "mp3", "wav", "aac", "flac", "m4a"
    ])

    var isImage: Bool {
        Self.imageExtensions.contains(fileExtension)
    }

    var isPreviewable: Bool {
        !isDirectory && Self.previewableExtensions.contains(fileExtension)
    }
}

// MARK: - Quick Look Coordinator

final class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        url as NSURL
    }
}

// MARK: - File Preview View (used for context menu preview)

struct FilePreviewView: View {
    let url: URL
    let fileExtension: String

    var body: some View {
        Group {
            if isImageFile {
                imagePreview
            } else if fileExtension == "pdf" {
                pdfPreview
            } else {
                iconPreview
            }
        }
    }

    private var isImageFile: Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp", "ico"].contains(fileExtension)
    }

    @ViewBuilder
    private var imagePreview: some View {
        if let nsImage = NSImage(contentsOf: url) {
            VStack(spacing: 8) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 320, maxHeight: 240)
                    .cornerRadius(6)

                fileInfo(nsImage: nsImage)
            }
            .padding(12)
        } else {
            iconPreview
        }
    }

    @ViewBuilder
    private var pdfPreview: some View {
        if let pdfDoc = PDFThumbnailGenerator.thumbnail(for: url) {
            VStack(spacing: 8) {
                Image(nsImage: pdfDoc)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 240, maxHeight: 320)
                    .cornerRadius(4)
                    .shadow(color: .black.opacity(0.15), radius: 4, y: 2)

                Text(url.lastPathComponent)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .padding(12)
        } else {
            iconPreview
        }
    }

    private var iconPreview: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 64, height: 64)
            Text(url.lastPathComponent)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .padding(12)
    }

    private func fileInfo(nsImage: NSImage) -> some View {
        VStack(spacing: 2) {
            Text(url.lastPathComponent)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)

            let w = Int(nsImage.representations.first?.pixelsWide ?? Int(nsImage.size.width))
            let h = Int(nsImage.representations.first?.pixelsHigh ?? Int(nsImage.size.height))
            let sizeStr = ByteCountFormatter.string(
                fromByteCount: (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0,
                countStyle: .file
            )
            Text("\(w) x \(h) — \(sizeStr)")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - PDF Thumbnail Helper

enum PDFThumbnailGenerator {
    static func thumbnail(for url: URL) -> NSImage? {
        guard let pdf = CGPDFDocument(url as CFURL),
              let page = pdf.page(at: 1) else { return nil }

        let rect = page.getBoxRect(.mediaBox)
        let scale: CGFloat = min(240 / rect.width, 320 / rect.height, 2.0)
        let size = CGSize(width: rect.width * scale, height: rect.height * scale)

        let image = NSImage(size: size)
        image.lockFocus()
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return nil
        }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.scaleBy(x: scale, y: scale)
        ctx.drawPDFPage(page)
        image.unlockFocus()
        return image
    }
}
