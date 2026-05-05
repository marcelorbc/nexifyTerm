import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum ExplorerViewMode: String {
    case list, gallery
}

struct FileExplorerView: View {
    @EnvironmentObject var appState: AppState
    let directory: String

    @StateObject private var provider: FileItemProvider
    @StateObject private var searchEngine = FileSearchEngine()
    @State private var selectedItems: Set<String> = []
    @State private var lastClickedItemId: String?
    @State private var navigationHistory: [URL] = []
    @State private var forwardHistory: [URL] = []
    @State private var renamingItemId: String?
    @State private var renameText = ""
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var showDeleteConfirm = false
    @State private var showPermanentDeleteConfirm = false
    @State private var itemsToDelete: [FileItem] = []
    @State private var viewMode: ExplorerViewMode = .list
    @State private var thumbnailSize: CGFloat = 120
    @State private var isSearching = false
    @State private var showClipboardPasteAlert = false
    @State private var clipboardPasteFileName = ""
    @State private var clipboardPasteType: FileItemProvider.ClipboardContentType = .none

    // Marquee selection (rubber-band) — track start/current points and per-item frames.
    @State private var marqueeStart: CGPoint?
    @State private var marqueeCurrent: CGPoint?
    @State private var marqueeAnchor: Set<String> = []
    @State private var rowFrames: [String: CGRect] = [:]

    // Batch results feedback
    @State private var batchMessage: String?
    @State private var showBatchProgress = false

    // Recorder sheet
    @State private var showRecorder = false

    init(directory: String) {
        self.directory = directory
        _provider = StateObject(wrappedValue: FileItemProvider(url: URL(fileURLWithPath: directory)))
    }

    var body: some View {
        VStack(spacing: 0) {
            FileExplorerPathBar(
                url: provider.currentURL,
                onNavigate: { url in navigateTo(url) },
                onDropToSegment: { destination, providers in
                    handleDrop(providers: providers, destination: destination)
                    return true
                }
            )

            Divider()

            FileExplorerToolbar(
                provider: provider,
                canGoBack: !navigationHistory.isEmpty,
                canGoForward: !forwardHistory.isEmpty,
                viewMode: $viewMode,
                isSearching: $isSearching,
                onBack: goBack,
                onForward: goForward,
                onUp: goUp,
                onNewFolder: { showNewFolderAlert = true },
                onTerminalHere: { appState.createTab(directory: provider.currentURL.path) },
                onToggleHidden: {
                    provider.showHidden.toggle()
                    provider.load()
                },
                onAttachSelected: attachSelected,
                onRefresh: { provider.load() },
                onRecord: { showRecorder = true },
                selectedCount: selectedItems.count
            )
            .environmentObject(appState)

            if isSearching {
                ExplorerSearchBar(
                    searchEngine: searchEngine,
                    directory: provider.currentURL,
                    showHidden: provider.showHidden,
                    onNavigate: { url in
                        if url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                            navigateTo(url)
                        } else {
                            FileItemProvider.openFile(url)
                        }
                        isSearching = false
                        searchEngine.clear()
                    },
                    onDismiss: {
                        isSearching = false
                        searchEngine.clear()
                    }
                )
            }

            Divider()

            if isSearching && !searchEngine.results.isEmpty {
                explorerSearchResults
            } else if isSearching && searchEngine.isSearching {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Buscando em \(provider.currentURL.lastPathComponent)...")
                        .font(.system(size: 12))
                        .foregroundColor(NexTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isSearching && !searchEngine.searchText.isEmpty && searchEngine.results.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundColor(NexTheme.textSecondary.opacity(0.4))
                    Text("Nenhum resultado para \"\(searchEngine.searchText)\"")
                        .font(.system(size: 12))
                        .foregroundColor(NexTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                fileListHeader

                Divider()

                if provider.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = provider.error {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title)
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundColor(NexTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if provider.items.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(.system(size: 32))
                            .foregroundColor(NexTheme.textSecondary.opacity(0.4))
                        Text("Pasta vazia")
                            .font(.system(size: 13))
                            .foregroundColor(NexTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewMode == .gallery {
                    imageGallery
                } else {
                    fileList
                }
            }
        }
        .background(NexTheme.bg)
        .onAppear { provider.load() }
        // Wave 1 · C3: keep the provider in sync when the owning tab navigates
        // externally (sidebar, URL handler, agent file actions in mosaic). Without
        // this, the explorer kept showing the directory it was first mounted with
        // even though `tab.currentDirectory` had moved on.
        .onChange(of: directory) { newPath in
            let newURL = URL(fileURLWithPath: newPath)
            guard newURL.standardizedFileURL != provider.currentURL.standardizedFileURL else { return }
            provider.navigate(to: newURL)
            navigationHistory.removeAll()
            forwardHistory.removeAll()
            selectedItems.removeAll()
        }
        .alert("Nova Pasta", isPresented: $showNewFolderAlert) {
            TextField("Nome da pasta", text: $newFolderName)
            Button("Criar") {
                if !newFolderName.isEmpty {
                    try? provider.createFolder(named: newFolderName)
                    newFolderName = ""
                }
            }
            Button("Cancelar", role: .cancel) { newFolderName = "" }
        }
        .alert("Mover para Lixeira", isPresented: $showDeleteConfirm) {
            Button("Mover para Lixeira", role: .destructive) {
                try? provider.deleteItems(itemsToDelete)
                selectedItems.removeAll()
                itemsToDelete = []
            }
            Button("Cancelar", role: .cancel) { itemsToDelete = [] }
        } message: {
            Text("Mover \(itemsToDelete.count) item(ns) para a Lixeira?")
        }
        .alert("Excluir Permanentemente", isPresented: $showPermanentDeleteConfirm) {
            Button("Excluir Permanentemente", role: .destructive) {
                try? provider.permanentDeleteItems(itemsToDelete)
                selectedItems.removeAll()
                itemsToDelete = []
            }
            Button("Cancelar", role: .cancel) { itemsToDelete = [] }
        } message: {
            Text("Excluir \(itemsToDelete.count) item(ns) permanentemente?\nEsta ação não pode ser desfeita.")
        }
        .alert("Operação em lote", isPresented: $showBatchProgress, presenting: batchMessage) { _ in
            Button("OK", role: .cancel) { batchMessage = nil }
        } message: { msg in
            Text(msg)
        }
        .sheet(isPresented: $showRecorder) {
            RecorderPanel(
                suggestedDirectory: provider.currentURL,
                onTranscribe: { url in
                    showRecorder = false
                    runTranscriptionAfterRecording(url: url)
                },
                onClose: { showRecorder = false }
            )
        }
        .alert(
            clipboardPasteType == .image ? "Salvar Imagem do Clipboard" : "Salvar Texto do Clipboard",
            isPresented: $showClipboardPasteAlert
        ) {
            TextField("Nome do arquivo", text: $clipboardPasteFileName)
            Button("Salvar") {
                let name = clipboardPasteFileName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                switch clipboardPasteType {
                case .image:
                    try? provider.saveImageFromClipboard(named: name, to: provider.currentURL)
                case .text:
                    try? provider.saveTextFromClipboard(named: name, to: provider.currentURL)
                case .none:
                    break
                }
                clipboardPasteFileName = ""
            }
            Button("Cancelar", role: .cancel) { clipboardPasteFileName = "" }
        } message: {
            Text(clipboardPasteType == .image
                 ? "Digite o nome para salvar a imagem (será salva como PNG)"
                 : "Digite o nome para salvar o texto (será salvo como TXT)")
        }
        .onDeleteCommand {
            let items = provider.items.filter { selectedItems.contains($0.id) }
            guard !items.isEmpty else { return }
            itemsToDelete = items
            if NSEvent.modifierFlags.contains(.shift) {
                showPermanentDeleteConfirm = true
            } else {
                showDeleteConfirm = true
            }
        }
        .onCopyCommand {
            let urls = provider.items
                .filter { selectedItems.contains($0.id) }
                .map(\.url)
            if !urls.isEmpty {
                FileItemProvider.copyFilesToClipboard(urls, operation: .copy)
            }
            return urls.map { NSItemProvider(object: $0 as NSURL) }
        }
        .onCutCommand {
            let urls = provider.items
                .filter { selectedItems.contains($0.id) }
                .map(\.url)
            if !urls.isEmpty {
                FileItemProvider.copyFilesToClipboard(urls, operation: .cut)
            }
            return urls.map { NSItemProvider(object: $0 as NSURL) }
        }
        .onPasteCommand(of: [.fileURL, .image, .plainText]) { _ in
            if FileItemProvider.hasClipboardFiles {
                try? provider.pasteFiles(to: provider.currentURL)
                return
            }

            let contentType = FileItemProvider.detectClipboardContent()
            if contentType != .none {
                clipboardPasteType = contentType
                clipboardPasteFileName = ""
                showClipboardPasteAlert = true
            }
        }
    }

    // MARK: - Image Gallery

    private var imageGallery: some View {
        VStack(spacing: 0) {
            galleryToolbar

            Divider()

            ScrollView {
                let columns = [GridItem(.adaptive(minimum: thumbnailSize, maximum: thumbnailSize + 40), spacing: 12)]
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(provider.items) { item in
                        galleryCell(item)
                    }
                }
                .padding(12)
            }
        }
    }

    private var galleryToolbar: some View {
        HStack(spacing: 8) {
            let imageCount = provider.items.filter(\.isImage).count
            let totalCount = provider.items.count
            Text("\(imageCount) imagens de \(totalCount) itens")
                .font(.system(size: 10))
                .foregroundColor(NexTheme.textSecondary)

            Spacer()

            Image(systemName: "photo")
                .font(.system(size: 9))
                .foregroundColor(NexTheme.textSecondary)

            Slider(value: $thumbnailSize, in: 60...240, step: 20)
                .frame(width: 100)

            Image(systemName: "photo.fill")
                .font(.system(size: 11))
                .foregroundColor(NexTheme.textSecondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(NexTheme.surface.opacity(0.4))
    }

    private func galleryCell(_ item: FileItem) -> some View {
        let isSelected = selectedItems.contains(item.id)
        let cellSize = thumbnailSize

        return VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(NexTheme.surface)

                if item.isImage {
                    ImageThumbnailView(url: item.url, size: cellSize)
                } else if item.isDirectory {
                    Image(systemName: item.sfSymbol)
                        .font(.system(size: cellSize * 0.35))
                        .foregroundColor(.accentColor)
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: cellSize * 0.45, height: cellSize * 0.45)
                }
            }
            .frame(width: cellSize, height: cellSize)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? NexTheme.accent : Color.clear, lineWidth: 2)
            )
            .shadow(color: .black.opacity(0.1), radius: 2, y: 1)

            Text(item.name)
                .font(.system(size: 10))
                .foregroundColor(NexTheme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: cellSize)

            if item.isImage {
                Text(item.formattedSize)
                    .font(.system(size: 9))
                    .foregroundColor(NexTheme.textSecondary)
            }
        }
        .contentShape(Rectangle())
        .onDrag {
            let urls = dragURLs(for: item)
            if urls.count > 1 {
                let provider = NSItemProvider()
                for url in urls {
                    provider.registerObject(url as NSURL, visibility: .all)
                }
                return provider
            }
            return NSItemProvider(object: (urls.first ?? item.url) as NSURL)
        }
        .onTapGesture { handleTap(item) }
        .onTapGesture(count: 2) { handleDoubleTap(item) }
        .contextMenu {
            FileContextMenu(
                item: item,
                provider: provider,
                selectedItems: selectedFileItems(includingFallback: item),
                currentDirectory: provider.currentURL,
                onRename: { startRename(item) },
                onAttach: { attachFile(item) },
                onDelete: {
                    itemsToDelete = selectedFileItems(includingFallback: item)
                    showDeleteConfirm = true
                },
                onPermanentDelete: {
                    itemsToDelete = selectedFileItems(includingFallback: item)
                    showPermanentDeleteConfirm = true
                },
                onBatchResult: { message in
                    batchMessage = message
                    showBatchProgress = true
                    provider.load()
                }
            )
            .environmentObject(appState)
        }
    }

    // MARK: - Header

    private var fileListHeader: some View {
        HStack(spacing: 0) {
            headerCell("Nome", field: .name, flex: true)
            headerCell("Tamanho", field: .size, width: 80)
            headerCell("Modificado", field: .modified, width: 120)
            headerCell("Tipo", field: .type, width: 70)
            Text("Tags")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(NexTheme.textSecondary)
                .frame(width: 60)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(NexTheme.surface.opacity(0.4))
    }

    private func headerCell(_ title: String, field: FileSortField, width: CGFloat? = nil, flex: Bool = false) -> some View {
        Button {
            if provider.sortField == field {
                provider.sortOrder = provider.sortOrder.toggled
            } else {
                provider.sortField = field
                provider.sortOrder = .ascending
            }
            provider.sortItems()
        } label: {
            HStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(provider.sortField == field ? NexTheme.accent : NexTheme.textSecondary)
                if provider.sortField == field {
                    Image(systemName: provider.sortOrder == .ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(NexTheme.accent)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: flex ? nil : width, alignment: .leading)
        .if(flex) { $0.frame(maxWidth: .infinity, alignment: .leading) }
    }

    // MARK: - File List

    private var fileList: some View {
        ScrollView {
            ZStack(alignment: .topLeading) {
                // Background tap = deselect / Cmd+A select all anchor.
                Color.clear
                    .contentShape(Rectangle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture { selectedItems.removeAll() }

                LazyVStack(spacing: 0) {
                    ForEach(provider.items) { item in
                        fileRow(item)
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: RowFramesPreferenceKey.self,
                                        value: [item.id: geo.frame(in: .named("fileListSpace"))]
                                    )
                                }
                            )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                if let rect = marqueeRect {
                    Rectangle()
                        .fill(NexTheme.accent.opacity(0.12))
                        .overlay(
                            Rectangle().stroke(NexTheme.accent.opacity(0.6), lineWidth: 1)
                        )
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .allowsHitTesting(false)
                }
            }
        }
        .coordinateSpace(name: "fileListSpace")
        .onPreferenceChange(RowFramesPreferenceKey.self) { rowFrames = $0 }
        .gesture(marqueeDragGesture)
        .onKeyboardShortcut("a", modifiers: .command) {
            selectedItems = Set(provider.items.map(\.id))
        }
    }

    private var marqueeRect: CGRect? {
        guard let start = marqueeStart, let current = marqueeCurrent else { return nil }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    private var marqueeDragGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("fileListSpace"))
            .onChanged { value in
                // Skip if drag started on a row (so .onDrag still works for files).
                let startedOnRow = rowFrames.contains { $0.value.contains(value.startLocation) }
                if marqueeStart == nil {
                    if startedOnRow { return }
                    marqueeStart = value.startLocation
                    let mods = NSEvent.modifierFlags
                    marqueeAnchor = (mods.contains(.shift) || mods.contains(.command)) ? selectedItems : []
                }
                marqueeCurrent = value.location

                guard let rect = marqueeRect else { return }
                let hitIds = rowFrames
                    .filter { $0.value.intersects(rect) }
                    .map(\.key)
                selectedItems = marqueeAnchor.union(hitIds)
            }
            .onEnded { _ in
                marqueeStart = nil
                marqueeCurrent = nil
                marqueeAnchor = []
            }
    }

    /// URLs to drag when user starts dragging an item. If the item is already
    /// part of the multi-selection, drag the whole selection; otherwise just
    /// drag that single item (and update selection to match).
    private func dragURLs(for item: FileItem) -> [URL] {
        if selectedItems.contains(item.id) && selectedItems.count > 1 {
            return provider.items
                .filter { selectedItems.contains($0.id) }
                .map(\.url)
        }
        selectedItems = [item.id]
        lastClickedItemId = item.id
        return [item.url]
    }

    private func fileRow(_ item: FileItem) -> some View {
        let isSelected = selectedItems.contains(item.id)
        let isRenaming = renamingItemId == item.id

        return HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: item.sfSymbol)
                    .font(.system(size: 14))
                    .foregroundColor(item.isGitRepo ? .green : (item.isDirectory ? .accentColor : fileIconColor(item)))
                    .frame(width: 20, height: 20)

                if isRenaming {
                    TextField("", text: $renameText, onCommit: {
                        commitRename(item)
                    })
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(maxWidth: 200)
                    .onExitCommand { cancelRename() }
                } else {
                    Text(item.name)
                        .font(.system(size: 12, weight: item.isDirectory ? .medium : .regular))
                        .foregroundColor(item.isHidden ? NexTheme.textSecondary.opacity(0.5) : NexTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()
            }

            Text(item.formattedSize)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(NexTheme.textSecondary)
                .frame(width: 80, alignment: .leading)

            Text(formatDate(item.modifiedDate))
                .font(.system(size: 11))
                .foregroundColor(NexTheme.textSecondary)
                .frame(width: 120, alignment: .leading)

            Text(item.typeDescription)
                .font(.system(size: 11))
                .foregroundColor(NexTheme.textSecondary)
                .frame(width: 70, alignment: .leading)

            FileTagDots(tags: item.tags)
                .frame(width: 60, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isSelected ? NexTheme.accentDim : Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isSelected ? NexTheme.accent.opacity(0.3) : Color.clear, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onDrag {
            let urls = dragURLs(for: item)
            if urls.count > 1 {
                let provider = NSItemProvider()
                for url in urls {
                    provider.registerObject(url as NSURL, visibility: .all)
                }
                return provider
            }
            return NSItemProvider(object: (urls.first ?? item.url) as NSURL)
        }
        .if(item.isDirectory) { view in
            view.onDrop(of: [.fileURL], isTargeted: nil) { providers in
                handleDrop(providers: providers, destination: item.url)
                return true
            }
        }
        .onTapGesture {
            handleTap(item)
        }
        .onTapGesture(count: 2) {
            handleDoubleTap(item)
        }
        .contextMenu {
            FileContextMenu(
                item: item,
                provider: provider,
                selectedItems: selectedFileItems(includingFallback: item),
                currentDirectory: provider.currentURL,
                onRename: { startRename(item) },
                onAttach: { attachFile(item) },
                onDelete: {
                    itemsToDelete = selectedFileItems(includingFallback: item)
                    showDeleteConfirm = true
                },
                onPermanentDelete: {
                    itemsToDelete = selectedFileItems(includingFallback: item)
                    showPermanentDeleteConfirm = true
                },
                onBatchResult: { message in
                    batchMessage = message
                    showBatchProgress = true
                    provider.load()
                }
            )
            .environmentObject(appState)
        } preview: {
            if item.isPreviewable {
                FilePreviewView(url: item.url, fileExtension: item.fileExtension)
            } else {
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                        .resizable()
                        .frame(width: 32, height: 32)
                    Text(item.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }
                .padding(12)
            }
        }
    }

    private func fileIconColor(_ item: FileItem) -> Color {
        switch item.fileType {
        case .folder: return NexTheme.accent
        case .app: return .blue
        case .symlink: return .purple
        case .file:
            switch item.fileExtension {
            case "swift", "py", "js", "ts", "rb", "go", "rs", "java", "c", "cpp", "h", "m", "cs":
                return NexTheme.accent
            case "json", "yaml", "yml", "xml", "plist", "toml":
                return .cyan
            case "md", "txt", "rtf", "log":
                return NexTheme.textSecondary
            case "html", "css", "scss":
                return .orange
            case "png", "jpg", "jpeg", "gif", "svg", "webp", "ico", "heic":
                return .pink
            case "mp4", "mov", "avi", "mkv":
                return .purple
            case "mp3", "wav", "aac", "flac", "m4a":
                return .indigo
            case "pdf":
                return .red
            case "zip", "tar", "gz", "rar", "7z":
                return .brown
            case "sh", "bash", "zsh", "fish":
                return NexTheme.accent
            default:
                return NexTheme.textSecondary.opacity(0.7)
            }
        }
    }

    // MARK: - Date Formatting

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd/MM/yyyy HH:mm"
        return f
    }()

    private func formatDate(_ date: Date?) -> String {
        guard let date else { return "--" }
        return Self.dateFormatter.string(from: date)
    }

    // MARK: - Interaction

    private func handleTap(_ item: FileItem) {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.shift), let anchorId = lastClickedItemId {
            guard let anchorIndex = provider.items.firstIndex(where: { $0.id == anchorId }),
                  let clickedIndex = provider.items.firstIndex(where: { $0.id == item.id }) else {
                selectedItems = [item.id]
                lastClickedItemId = item.id
                return
            }
            let range = min(anchorIndex, clickedIndex)...max(anchorIndex, clickedIndex)
            let rangeIds = Set(provider.items[range].map(\.id))
            if modifiers.contains(.command) {
                selectedItems.formUnion(rangeIds)
            } else {
                selectedItems = rangeIds
            }
        } else if modifiers.contains(.command) {
            if selectedItems.contains(item.id) {
                selectedItems.remove(item.id)
            } else {
                selectedItems.insert(item.id)
            }
            lastClickedItemId = item.id
        } else {
            selectedItems = [item.id]
            lastClickedItemId = item.id
        }
    }

    private func handleDoubleTap(_ item: FileItem) {
        if item.isDirectory {
            navigateTo(item.url)
        } else {
            FileItemProvider.openFile(item.url)
        }
    }

    // MARK: - Navigation

    private func navigateTo(_ url: URL) {
        navigationHistory.append(provider.currentURL)
        forwardHistory.removeAll()
        provider.navigate(to: url)
        selectedItems.removeAll()
        syncTabDirectory(url, updateTitle: true)
        RecentDirectoriesStore.shared.add(url.path)
    }

    private func goBack() {
        guard let prev = navigationHistory.popLast() else { return }
        forwardHistory.append(provider.currentURL)
        provider.navigate(to: prev)
        selectedItems.removeAll()
        syncTabDirectory(prev, updateTitle: true)
    }

    private func goForward() {
        guard let next = forwardHistory.popLast() else { return }
        navigationHistory.append(provider.currentURL)
        provider.navigate(to: next)
        selectedItems.removeAll()
        syncTabDirectory(next, updateTitle: true)
    }

    private func goUp() {
        let parent = provider.currentURL.deletingLastPathComponent()
        guard parent != provider.currentURL else { return }
        navigateTo(parent)
    }

    /// Wave 1 · C3: sync tab directory after explorer navigation. We used to gate
    /// this on `tab.isExplorer`, which left mosaic tabs (and the agent that reads
    /// `tab.currentDirectory`) pointing at the original directory forever. Now we
    /// always sync the cwd; the title is only retitled in pure-explorer tabs so we
    /// don't overwrite a user-given mosaic title.
    private func syncTabDirectory(_ url: URL, updateTitle: Bool) {
        guard var tab = appState.activeTab else { return }
        guard tab.currentDirectory != url.path else { return }
        tab.currentDirectory = url.path
        if updateTitle && tab.isExplorer {
            tab.title = url.lastPathComponent
        }
        appState.activeTab = tab
    }

    // MARK: - Drag & Drop

    private func handleDrop(providers: [NSItemProvider], destination: URL) {
        for p in providers {
            p.loadItem(forTypeIdentifier: "public.file-url", options: nil) { data, _ in
                guard let data = data as? Data,
                      let sourceURL = URL(dataRepresentation: data, relativeTo: nil) else { return }
                let normalizedSource = sourceURL.standardizedFileURL
                let normalizedDest = destination.standardizedFileURL
                // Skip no-ops: dropping a file in its own parent directory,
                // or dropping a directory onto itself.
                guard normalizedSource != normalizedDest,
                      normalizedSource.deletingLastPathComponent() != normalizedDest
                else { return }
                let dest = normalizedDest.appendingPathComponent(normalizedSource.lastPathComponent)
                DispatchQueue.main.async {
                    try? FileManager.default.moveItem(at: normalizedSource, to: dest)
                    provider.load()
                }
            }
        }
    }

    // MARK: - Rename

    private func startRename(_ item: FileItem) {
        renamingItemId = item.id
        renameText = item.name
    }

    private func commitRename(_ item: FileItem) {
        let newName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !newName.isEmpty && newName != item.name {
            try? provider.rename(item: item, to: newName)
        }
        cancelRename()
    }

    private func cancelRename() {
        renamingItemId = nil
        renameText = ""
    }

    // MARK: - Attach / Terminal Integration

    private func attachFile(_ item: FileItem) {
        FileItemProvider.copyPath(item.url)
    }

    private func attachSelected() {
        let paths = provider.items
            .filter { selectedItems.contains($0.id) }
            .map(\.url.path)
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths, forType: .string)
    }

    private func runTranscriptionAfterRecording(url: URL) {
        let apiKey = ConfigStore.shared.openAIAPIKey
        guard !apiKey.isEmpty else {
            batchMessage = "Chave da OpenAI não configurada. Defina em Configurações → IA."
            showBatchProgress = true
            return
        }
        batchMessage = "Iniciando transcrição de \(url.lastPathComponent)... (pode demorar alguns minutos)"
        showBatchProgress = true
        Task {
            do {
                let output = try await MediaTranscriptionPipeline.runFullTranscription(for: url) { _ in }
                await MainActor.run {
                    batchMessage = "Transcrição salva: \(output.lastPathComponent)"
                    showBatchProgress = true
                    NSWorkspace.shared.activateFileViewerSelecting([output])
                    provider.load()
                }
            } catch {
                await MainActor.run {
                    batchMessage = "Falha na transcrição: \(error.localizedDescription)"
                    showBatchProgress = true
                }
            }
        }
    }

    /// Returns currently selected items. If selection is empty (e.g. user
    /// right-clicked an unselected item), falls back to that single item.
    private func selectedFileItems(includingFallback item: FileItem) -> [FileItem] {
        let selected = provider.items.filter { selectedItems.contains($0.id) }
        if selected.isEmpty || !selected.contains(where: { $0.id == item.id }) {
            return [item]
        }
        return selected
    }

    // MARK: - Explorer Search Results

    private var explorerSearchResults: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(searchEngine.results) { result in
                    explorerSearchRow(result)
                }
            }
        }
    }

    private func explorerSearchRow(_ result: FileSearchEngine.FileSearchResult) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: result.icon)
                .resizable()
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(result.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(NexTheme.textPrimary)
                    .lineLimit(1)

                Text(result.displayPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(NexTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer()

            if !result.isDirectory {
                Text(ByteCountFormatter.string(fromByteCount: result.size, countStyle: .file))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(NexTheme.textSecondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            if result.isDirectory {
                navigateTo(result.url)
            } else {
                FileItemProvider.openFile(result.url)
            }
            isSearching = false
            searchEngine.clear()
        }
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

// MARK: - Explorer Search Bar

struct ExplorerSearchBar: View {
    @ObservedObject var searchEngine: FileSearchEngine
    let directory: URL
    let showHidden: Bool
    let onNavigate: (URL) -> Void
    let onDismiss: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(NexTheme.textSecondary)

            TextField("Buscar em \(directory.lastPathComponent)...", text: $searchEngine.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isFocused)
                .onSubmit {
                    if let first = searchEngine.results.first {
                        onNavigate(first.url)
                    }
                }

            if searchEngine.isSearching {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
            }

            if !searchEngine.searchText.isEmpty {
                Text("\(searchEngine.results.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(NexTheme.textSecondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(NexTheme.surface)
                    .cornerRadius(3)
            }

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(NexTheme.textSecondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(NexTheme.surface.opacity(0.8))
        .onAppear { isFocused = true }
        .onChange(of: searchEngine.searchText) { _, newValue in
            searchEngine.searchLocal(query: newValue, in: directory, showHidden: showHidden)
        }
    }
}

// MARK: - Conditional View Modifier

private extension View {
    @ViewBuilder
    func `if`<Transform: View>(_ condition: Bool, transform: (Self) -> Transform) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }

    /// Attaches an invisible button that fires `action` when the keyboard
    /// shortcut is pressed while this view is in the responder chain.
    func onKeyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers, action: @escaping () -> Void) -> some View {
        background(
            Button("", action: action)
                .keyboardShortcut(key, modifiers: modifiers)
                .hidden()
                .frame(width: 0, height: 0)
        )
    }
}

// MARK: - Row frame tracking for marquee selection

struct RowFramesPreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, b in b })
    }
}
