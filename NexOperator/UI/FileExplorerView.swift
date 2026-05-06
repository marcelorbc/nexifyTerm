import SwiftUI
import AppKit
import UniformTypeIdentifiers
import QuickLookUI

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
    @State private var renameError: String?
    @FocusState private var renameFieldFocused: Bool
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

    // Type-ahead filter (Finder/Explorer-style): user starts typing while
    // focused on the file list and items are filtered live by name. Esc clears.
    @State private var typeAheadFilter: String = ""
    @State private var typeAheadResetTask: DispatchWorkItem?
    @FocusState private var listHasFocus: Bool

    /// Items to display: applies the local type-ahead filter on top of
    /// whatever the provider returns. Case-insensitive substring match on
    /// the file name. When the filter is empty, returns provider items as-is.
    private var displayedItems: [FileItem] {
        guard !typeAheadFilter.isEmpty else { return provider.items }
        let needle = typeAheadFilter.lowercased()
        return provider.items.filter { $0.name.lowercased().contains(needle) }
    }

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
                if let loc = provider.archiveLocation {
                    archiveBanner(location: loc)
                }
                if !typeAheadFilter.isEmpty {
                    typeAheadBanner
                }

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
        .focusable(true)
        .focusEffectDisabled()
        .focused($listHasFocus)
        .onKeyPress(phases: .down) { press in
            handleListKeyPress(press)
        }
        .onChange(of: provider.currentURL) { _, _ in
            // Limpa o filtro ao trocar de pasta — comportamento padrão do
            // Finder/Explorer: o type-ahead é local da pasta atual.
            clearTypeAheadFilter()
        }
        .onAppear {
            provider.load()
            listHasFocus = true
        }
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
        // Atalhos globais ao estilo Finder/Explorer. Implementados como
        // botões invisíveis no .background pra ficarem ativos sempre que a
        // view estiver na cadeia de respondedores.
        .background(
            VStack(spacing: 0) {
                Button("", action: goUp).keyboardShortcut(.upArrow, modifiers: [.command])
                Button("", action: goBack).keyboardShortcut("[", modifiers: [.command])
                Button("", action: goForward).keyboardShortcut("]", modifiers: [.command])
                Button("", action: { provider.load() }).keyboardShortcut("r", modifiers: [.command])
                Button("", action: { showNewFolderAlert = true }).keyboardShortcut("n", modifiers: [.command, .shift])
                Button("", action: { isSearching = true }).keyboardShortcut("f", modifiers: [.command])
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        )
    }

    // MARK: - Image Gallery

    private var imageGallery: some View {
        VStack(spacing: 0) {
            galleryToolbar

            Divider()

            ScrollView {
                let columns = [GridItem(.adaptive(minimum: thumbnailSize, maximum: thumbnailSize + 40), spacing: 12)]
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(displayedItems) { item in
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
        .onDrag { makeDragProvider(for: item) }
        .onTapGesture { handleTap(item) }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { handleDoubleTap(item) }
        )
        .onRightClick { ensureSelectedForContextMenu(item) }
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

    /// Garante que o item alvo do right-click está na seleção. Se ele já
    /// estava (sozinho ou junto com outros), mantém. Senão, substitui a
    /// seleção pelo item — espelha o comportamento do Finder/Explorer.
    private func ensureSelectedForContextMenu(_ item: FileItem) {
        if !selectedItems.contains(item.id) {
            selectedItems = [item.id]
            lastClickedItemId = item.id
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
                // Background tap = deselect (e commita rename pendente, se
                // houver — comportamento clássico do Finder).
                Color.clear
                    .contentShape(Rectangle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture {
                        if let id = renamingItemId,
                           let item = provider.items.first(where: { $0.id == id }) {
                            commitRename(item)
                        }
                        selectedItems.removeAll()
                    }

                LazyVStack(spacing: 0) {
                    ForEach(displayedItems) { item in
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

    /// Constrói o `NSItemProvider` para arrastar `item`. Trata 3 casos:
    /// 1. Item normal de filesystem → URL direta;
    /// 2. Multi-seleção → várias URLs;
    /// 3. Entry virtual dentro de archive → registra um provedor preguiçoso
    ///    que extrai a entry sob demanda quando o destino solicitar a URL.
    ///    Isso evita extrair desnecessariamente arquivos muito grandes.
    private func makeDragProvider(for item: FileItem) -> NSItemProvider {
        if let origin = item.archiveOrigin, !origin.isDirectory {
            return makeArchiveEntryProvider(item: item, origin: origin)
        }
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

    private func makeArchiveEntryProvider(item: FileItem, origin: ArchiveOrigin) -> NSItemProvider {
        let provider = NSItemProvider()
        let typeID = "public.file-url"
        provider.suggestedName = item.name
        provider.registerFileRepresentation(
            forTypeIdentifier: typeID,
            fileOptions: [],
            visibility: .all
        ) { completion in
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("nex_drag_\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            } catch {
                completion(nil, false, error)
                return nil
            }
            let outFile = tempDir.appendingPathComponent(item.name)
            let entry = ArchiveEntry(
                path: origin.internalPath, isDirectory: false,
                size: item.size, modified: item.modifiedDate
            )
            let archive = origin.archiveURL
            Task.detached {
                do {
                    try await ArchiveService.extractEntry(entry, from: archive, to: outFile)
                    completion(outFile, true, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return nil
        }
        return provider
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
                    renameField(item: item)
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
        .onDrag { makeDragProvider(for: item) }
        .if(item.isDirectory && item.archiveOrigin == nil) { view in
            view.onDrop(of: [.fileURL], isTargeted: nil) { providers in
                handleDrop(providers: providers, destination: item.url)
                return true
            }
        }
        // Single-click responsivo: dispara `handleTap` imediatamente sem
        // esperar o timer do double-click (que acrescentava ~250ms de lag
        // perceptível). O segundo tap roda em paralelo via simultaneous.
        .onTapGesture { handleTap(item) }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { handleDoubleTap(item) }
        )
        .onRightClick { ensureSelectedForContextMenu(item) }
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
        // Se há um rename ativo em outro item, commita antes de mudar seleção.
        if let activeRenameId = renamingItemId, activeRenameId != item.id,
           let activeItem = provider.items.first(where: { $0.id == activeRenameId }) {
            commitRename(activeItem)
        }
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
        // Navegação dentro de archive: pasta virtual = navega no archive.
        if let origin = item.archiveOrigin {
            if origin.isDirectory {
                provider.navigateInsideArchive(toSubPath: origin.internalPath)
                selectedItems.removeAll()
            } else {
                // Entry de arquivo dentro do archive: extrai pra temp e abre.
                openArchiveEntryExternally(item)
            }
            return
        }
        if item.isDirectory {
            navigateTo(item.url)
        } else if item.isArchive {
            // Entrar no archive como se fosse uma pasta — comportamento estilo
            // Windows Explorer/macOS Finder Archive Utility.
            enterArchive(item)
        } else {
            FileItemProvider.openFile(item.url)
        }
    }

    /// Tenta entrar no archive. Em caso de erro (tool ausente, archive
    /// corrompido, etc.) mostra o erro no banner padrão do explorer.
    private func enterArchive(_ item: FileItem) {
        navigationHistory.append(provider.currentURL)
        forwardHistory.removeAll()
        Task {
            do {
                try await provider.enterArchive(item.url)
                selectedItems.removeAll()
                clearTypeAheadFilter()
            } catch {
                // Reverte o histórico já que não conseguimos entrar.
                _ = navigationHistory.popLast()
                provider.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Extrai uma entry de archive pra um diretório temp e abre com o app
    /// padrão do macOS — comportamento "preview" do Windows ao dar duplo
    /// clique em um arquivo dentro de um zip.
    private func openArchiveEntryExternally(_ item: FileItem) {
        guard let origin = item.archiveOrigin else { return }
        Task {
            do {
                let tempDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("nex_archive_open_\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let outFile = tempDir.appendingPathComponent(item.name)
                let entry = ArchiveEntry(
                    path: origin.internalPath, isDirectory: false,
                    size: item.size, modified: item.modifiedDate
                )
                try await ArchiveService.extractEntry(entry, from: origin.archiveURL, to: outFile)
                FileItemProvider.openFile(outFile)
            } catch {
                provider.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
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
        // Voltar a partir de dentro de um archive sai do archive direto, sem
        // empilhar mais histórico — o histórico só faz sentido pra path real.
        if provider.isInsideArchive {
            provider.exitArchive()
            selectedItems.removeAll()
            return
        }
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
        // Em modo archive: sobe um nível dentro do archive ou sai dele.
        if let loc = provider.archiveLocation {
            if loc.subPath.isEmpty {
                provider.exitArchive()
                selectedItems.removeAll()
            } else {
                let parent = (loc.subPath as NSString).deletingLastPathComponent
                provider.navigateInsideArchive(toSubPath: parent == "/" ? "" : parent)
                selectedItems.removeAll()
            }
            return
        }
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
        // Drops dentro de archives são ignorados — arquivos virtuais não
        // suportam mutações no momento.
        if provider.isInsideArchive { return }
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

    // MARK: - Archive browsing

    /// Banner mostrado quando o usuário está navegando dentro de um zip/rar/7z.
    /// Tem botão pra sair, breadcrumb interno e ação de extrair tudo.
    private func archiveBanner(location: ArchiveLocation) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.zipper")
                .foregroundColor(.purple)
                .font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("Dentro de \(location.kind.humanLabel):")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(NexTheme.textPrimary)
                    Text(location.archiveURL.lastPathComponent)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(NexTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if !location.subPath.isEmpty {
                    Text("/ \(location.subPath)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(NexTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            Button {
                extractCurrentArchiveAll(askDestination: false)
            } label: {
                Label("Extrair Tudo", systemImage: "arrow.down.doc.fill")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.purple.opacity(0.12))
            .cornerRadius(4)
            .help("Extrai todo o conteúdo do archive ao lado dele")

            Button {
                provider.exitArchive()
                selectedItems.removeAll()
            } label: {
                Label("Sair", systemImage: "xmark")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(NexTheme.surface)
            .cornerRadius(4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.purple.opacity(0.06))
        .overlay(
            Rectangle().frame(height: 0.5).foregroundColor(Color.purple.opacity(0.3)),
            alignment: .bottom
        )
    }

    /// Extrai todo o archive atualmente aberto. Quando `askDestination`,
    /// abre um NSOpenPanel pra escolher pasta destino — caso contrário,
    /// extrai pra pasta que contém o archive (comportamento padrão).
    private func extractCurrentArchiveAll(askDestination: Bool) {
        guard let loc = provider.archiveLocation else { return }
        let baseName = loc.archiveURL.deletingPathExtension().lastPathComponent
        let defaultDest = loc.archiveURL.deletingLastPathComponent()
            .appendingPathComponent(baseName, isDirectory: true)
        let dest: URL
        if askDestination {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.directoryURL = loc.archiveURL.deletingLastPathComponent()
            panel.prompt = "Extrair Aqui"
            panel.message = "Escolha onde extrair \(loc.archiveURL.lastPathComponent)"
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            dest = chosen.appendingPathComponent(baseName, isDirectory: true)
        } else {
            dest = defaultDest
        }
        Task {
            do {
                try await ArchiveService.extractAll(from: loc.archiveURL, to: dest)
                batchMessage = "Conteúdo extraído em \(dest.lastPathComponent)/"
                showBatchProgress = true
                NSWorkspace.shared.activateFileViewerSelecting([dest])
            } catch {
                batchMessage = "Falha ao extrair: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                showBatchProgress = true
            }
        }
    }

    // MARK: - Type-ahead filter & keyboard

    /// Banner mostrado no topo da lista quando o filtro está ativo.
    private var typeAheadBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .font(.system(size: 11))
                .foregroundColor(NexTheme.accent)
            Text("Filtrando por:")
                .font(.system(size: 11))
                .foregroundColor(NexTheme.textSecondary)
            Text("\"\(typeAheadFilter)\"")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(NexTheme.textPrimary)
            Text("· \(displayedItems.count) de \(provider.items.count)")
                .font(.system(size: 11))
                .foregroundColor(NexTheme.textSecondary)
            Spacer()
            Button(action: clearTypeAheadFilter) {
                HStack(spacing: 3) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                    Text("Limpar (Esc)")
                        .font(.system(size: 10))
                }
                .foregroundColor(NexTheme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Limpar filtro de digitação")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(NexTheme.accent.opacity(0.06))
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundColor(NexTheme.accent.opacity(0.3)),
            alignment: .bottom
        )
    }

    /// Function keys reservadas (F1–F19 do macOS, mapeadas para o private-use
    /// area do Unicode). Devem ser ignoradas pelo type-ahead pra não poluir
    /// o filtro com `\u{F704}`, `\u{F705}` etc.
    private static let functionKeyScalarRange: ClosedRange<UInt32> = 0xF700...0xF8FF

    /// Trata teclas pressionadas com a lista focada. Retorna `.handled` quando
    /// consome o evento (impede que ele propague pra menus etc).
    /// - F2 → inicia rename do único item selecionado.
    /// - Enter → abre item selecionado (folder = navega; arquivo = open).
    /// - Setas ↑/↓ → navega seleção pra cima/baixo.
    /// - Esc → limpa filtro; se vazio, limpa seleção.
    /// - Backspace → remove último char do filtro.
    /// - Caracteres imprimíveis (sem Cmd/Ctrl) → adiciona ao filtro.
    /// - Function keys, Tab, etc → ignorados.
    private func handleListKeyPress(_ press: KeyPress) -> KeyPress.Result {
        // Não interfere quando há modificadores de comando — Cmd+A, Cmd+C, etc.
        if press.modifiers.contains(.command) || press.modifiers.contains(.control) {
            return .ignored
        }
        // Não interfere se já existe um item em modo rename — o TextField captura.
        if renamingItemId != nil { return .ignored }

        // F2: rename — checagem específica antes do filtro de function keys.
        if press.key == .init("\u{F705}") /* NSF2FunctionKey */ {
            triggerRenameForSelection()
            return .handled
        }

        switch press.key {
        case .escape:
            // 1ª Esc → limpa filtro; 2ª Esc → limpa seleção. Comportamento
            // idêntico ao Finder.
            if !typeAheadFilter.isEmpty {
                clearTypeAheadFilter()
                return .handled
            }
            if !selectedItems.isEmpty {
                selectedItems.removeAll()
                lastClickedItemId = nil
                return .handled
            }
            return .ignored
        case .delete: // backspace
            if !typeAheadFilter.isEmpty {
                typeAheadFilter.removeLast()
                scheduleTypeAheadAutoReset()
                return .handled
            }
            return .ignored
        case .return:
            // Enter abre o item selecionado (1 selecionado). Se 0 ou múltiplos,
            // ignora — múltipla abertura seria cara.
            if selectedItems.count == 1, let id = selectedItems.first,
               let item = displayedItems.first(where: { $0.id == id }) {
                handleDoubleTap(item)
                return .handled
            }
            return .ignored
        case .upArrow:
            return moveSelection(by: -1, extending: press.modifiers.contains(.shift))
        case .downArrow:
            return moveSelection(by: +1, extending: press.modifiers.contains(.shift))
        case .leftArrow:
            // ← em modo lista navega de volta (Finder/Explorer comum).
            goBack()
            return .handled
        case .rightArrow:
            // → abre item selecionado (consistente com Cmd+↓).
            if selectedItems.count == 1, let id = selectedItems.first,
               let item = displayedItems.first(where: { $0.id == id }) {
                handleDoubleTap(item)
                return .handled
            }
            return .ignored
        case .space:
            // Quick Look — só pra arquivos previewable, e somente quando há
            // exatamente 1 selecionado. Sem múltipla preview por ora.
            if selectedItems.count == 1, let id = selectedItems.first,
               let item = displayedItems.first(where: { $0.id == id }),
               item.isPreviewable {
                showQuickLookForItem(item)
                return .handled
            }
            return .ignored
        default:
            break
        }

        // Filtra out function keys (F1–F19) e demais chars do private-use area.
        let ch = press.characters
        if ch.count == 1, let scalar = ch.unicodeScalars.first {
            if Self.functionKeyScalarRange.contains(scalar.value) {
                return .ignored
            }
            // Caracteres imprimíveis (>= space, != DEL) entram no filtro.
            if scalar.value >= 0x20, scalar.value != 0x7F {
                typeAheadFilter.append(ch)
                scheduleTypeAheadAutoReset()
                // Auto-seleciona o primeiro item visível pra navegação ficar fluida.
                if let first = displayedItems.first {
                    selectedItems = [first.id]
                    lastClickedItemId = first.id
                }
                return .handled
            }
        }
        return .ignored
    }

    /// Move a seleção para próxima/anterior linha. Se `extending`, mantém os
    /// items já selecionados (range Shift+↑/↓).
    private func moveSelection(by delta: Int, extending: Bool) -> KeyPress.Result {
        let visible = displayedItems
        guard !visible.isEmpty else { return .ignored }
        let currentId = lastClickedItemId ?? selectedItems.first
        let currentIndex = visible.firstIndex(where: { $0.id == currentId }) ?? -1
        let newIndex = max(0, min(visible.count - 1, currentIndex + delta))
        let target = visible[newIndex]
        if extending {
            selectedItems.insert(target.id)
        } else {
            selectedItems = [target.id]
        }
        lastClickedItemId = target.id
        return .handled
    }

    /// Abre Quick Look para um item específico (chamado pelo atalho Space).
    private func showQuickLookForItem(_ item: FileItem) {
        let panel = QLPreviewPanel.shared()!
        let delegate = QuickLookCoordinator(url: item.url)
        objc_setAssociatedObject(panel, "qlCoordinator", delegate, .OBJC_ASSOCIATION_RETAIN)
        panel.dataSource = delegate
        panel.delegate = delegate
        panel.makeKeyAndOrderFront(nil)
    }

    private func clearTypeAheadFilter() {
        typeAheadFilter = ""
        typeAheadResetTask?.cancel()
        typeAheadResetTask = nil
    }

    /// Auto-limpa o filtro depois de 2.5s de inatividade — comportamento de
    /// type-ahead clássico do macOS Finder, evita ficar com filtro "preso".
    private func scheduleTypeAheadAutoReset() {
        typeAheadResetTask?.cancel()
        let task = DispatchWorkItem { [self] in
            self.typeAheadFilter = ""
        }
        typeAheadResetTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: task)
    }

    /// F2: dispara rename quando há exatamente UM item selecionado.
    private func triggerRenameForSelection() {
        guard selectedItems.count == 1, let id = selectedItems.first else { return }
        guard let item = provider.items.first(where: { $0.id == id }) else { return }
        startRename(item)
    }

    // MARK: - Rename

    /// Caracteres proibidos em nomes de arquivos no APFS/HFS+. `:` por
    /// causa do legacy Mac OS Classic, `/` por ser separador de path.
    /// Strings com qualquer um geram erro silencioso no FileManager — então
    /// barramos no UI antes do commit.
    private static let forbiddenFilenameChars = CharacterSet(charactersIn: "/:")

    /// Campo de edição de rename. Faz auto-focus, seleciona apenas o
    /// "basename" (nome sem extensão) ao abrir, valida caracteres proibidos
    /// em tempo real e mostra erro inline. Esc cancela, Enter commita.
    @ViewBuilder
    private func renameField(item: FileItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("", text: $renameText, onCommit: {
                commitRename(item)
            })
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))
            .frame(maxWidth: 240)
            .focused($renameFieldFocused)
            .onChange(of: renameText) { _, newValue in
                let sanitized = String(newValue.unicodeScalars.filter {
                    !Self.forbiddenFilenameChars.contains($0)
                })
                if sanitized != newValue {
                    renameText = sanitized
                    renameError = "Os caracteres / e : não são permitidos"
                } else {
                    renameError = nil
                }
            }
            .onExitCommand { cancelRename() }
            .onAppear {
                // SwiftUI 1.x não tem API direta pra "selecionar até o ponto
                // antes da extensão". Mas no AppKit o NSTextField faz o
                // currentEditor selecionar tudo por padrão ao receber foco;
                // re-selecionamos só o basename via NSApp.keyWindow logo
                // depois.
                DispatchQueue.main.async {
                    renameFieldFocused = true
                    selectBasenameOnly(of: item.name)
                }
            }

            if let err = renameError {
                Text(err)
                    .font(.system(size: 9))
                    .foregroundColor(.orange)
            }
        }
    }

    /// Re-seleciona somente o basename (nome sem extensão) no NSTextField
    /// que está sendo editado. Comportamento idêntico ao Finder ao abrir
    /// o rename (Enter no Finder seleciona "arquivo", deixa ".txt" fora).
    private func selectBasenameOnly(of fullName: String) {
        guard let window = NSApp.keyWindow,
              let editor = window.firstResponder as? NSTextView else { return }
        let nsName = fullName as NSString
        let ext = nsName.pathExtension
        if ext.isEmpty { return }  // sem extensão: deixa tudo selecionado
        let basenameLength = nsName.length - ext.count - 1  // -1 do ponto
        guard basenameLength > 0 else { return }
        editor.setSelectedRange(NSRange(location: 0, length: basenameLength))
    }

    private func startRename(_ item: FileItem) {
        // Não permite renomear entries virtuais (filesystem read-only de archive).
        if item.archiveOrigin != nil {
            batchMessage = "Renomear não é suportado dentro de archives"
            showBatchProgress = true
            return
        }
        renamingItemId = item.id
        renameText = item.name
        renameError = nil
    }

    private func commitRename(_ item: FileItem) {
        let newName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { cancelRename(); return }
        guard newName != item.name else { cancelRename(); return }
        // Conflito: já existe arquivo com esse nome no diretório.
        let candidate = item.url.deletingLastPathComponent().appendingPathComponent(newName)
        if FileManager.default.fileExists(atPath: candidate.path) {
            renameError = "Já existe um item chamado '\(newName)'"
            return
        }
        do {
            try provider.rename(item: item, to: newName)
            cancelRename()
        } catch {
            renameError = "Falha: \(error.localizedDescription)"
        }
    }

    private func cancelRename() {
        renamingItemId = nil
        renameText = ""
        renameError = nil
        renameFieldFocused = false
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

// MARK: - Right-click detection

/// Detecta right-click (`rightMouseDown`) numa view SwiftUI antes do
/// `.contextMenu` abrir. Usado pra garantir que o item clicado entre na
/// seleção visual — comportamento padrão do Finder/Explorer onde o
/// menu reflete o item alvo mesmo se ele não estava selecionado antes.
struct RightClickDetector: NSViewRepresentable {
    let onRightClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ClickAwareView()
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ClickAwareView)?.onRightClick = onRightClick
    }

    final class ClickAwareView: NSView {
        var onRightClick: (() -> Void)?

        override func rightMouseDown(with event: NSEvent) {
            onRightClick?()
            super.rightMouseDown(with: event)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Não bloqueia eventos de mouse — só quer "ver" o right-click,
            // sem interceptar tap/drag/etc do SwiftUI por baixo.
            return nil
        }
    }
}

extension View {
    /// Executa `action` quando o usuário faz right-click nesta view, antes
    /// do `.contextMenu` abrir. Combinar com `.contextMenu` para refletir
    /// o item-alvo na seleção.
    func onRightClick(perform action: @escaping () -> Void) -> some View {
        background(RightClickDetector(onRightClick: action))
    }
}
