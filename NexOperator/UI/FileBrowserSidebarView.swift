import SwiftUI

struct FileBrowserSidebarView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var favoritesStore = FavoritesStore.shared
    @StateObject private var recentStore = RecentDirectoriesStore.shared
    @State private var expandedFolders: Set<String> = []
    @State private var rootURL = FileManager.default.homeDirectoryForCurrentUser
    @State private var sidebarWidth: CGFloat = 220
    @State private var renamingFavoriteID: UUID? = nil
    @State private var renamingText: String = ""

    private let minSidebarWidth: CGFloat = 180
    private let maxSidebarWidth: CGFloat = 400

    private var activeExplorerDirectory: String? {
        guard let tab = appState.activeTab, tab.isExplorer else { return nil }
        return tab.currentDirectory
    }

    private var activeTabDirectory: String? {
        appState.activeTab?.currentDirectory
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                sidebarHeader

                sidebarToolbar

                Divider()

                List {
                    Section("Favoritos") {
                        ForEach(favoritesStore.favorites) { fav in
                            if renamingFavoriteID == fav.id {
                                HStack(spacing: 6) {
                                    Image(systemName: fav.icon)
                                        .font(.system(size: 11))
                                        .foregroundColor(fav.isDirectory ? .accentColor : .secondary)
                                        .frame(width: 16)
                                    TextField("Nome", text: $renamingText, onCommit: {
                                        commitRename(fav.id)
                                    })
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12))
                                    .onExitCommand { cancelRename() }
                                }
                            } else {
                                SidebarItem(
                                    icon: fav.icon,
                                    label: fav.name,
                                    isFolder: fav.isDirectory,
                                    onTap: {
                                        if fav.isDirectory {
                                            appState.addExplorerTab(directory: fav.path)
                                        } else {
                                            FileItemProvider.openFile(URL(fileURLWithPath: fav.path))
                                        }
                                    },
                                    onContextMenu: {
                                        favoriteSidebarMenu(fav)
                                    }
                                )
                            }
                        }
                    }

                    if !recentStore.recents.isEmpty {
                        Section("Recentes") {
                            ForEach(recentStore.recents.prefix(8)) { recent in
                                Button {
                                    navigateOrOpenExplorer(recent.path)
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "clock")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                            .frame(width: 16)
                                        Text(recent.name)
                                            .font(.system(size: 12))
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button { appState.createTab(directory: recent.path) } label: {
                                        Label("Terminal", systemImage: "terminal.fill")
                                    }
                                    Button { appState.addExplorerTab(directory: recent.path) } label: {
                                        Label("Explorer", systemImage: "folder.fill")
                                    }
                                    Button { appState.addGitTab(directory: recent.path) } label: {
                                        Label("Git", systemImage: "arrow.triangle.branch")
                                    }
                                    Divider()
                                    Button("Remover dos Recentes") {
                                        recentStore.remove(recent.path)
                                    }
                                }
                            }
                        }
                    }

                    Section("Pastas") {
                        FolderTreeNode(
                            url: rootURL,
                            expandedFolders: $expandedFolders,
                            highlightedPath: activeExplorerDirectory,
                            depth: 0,
                            onOpenExplorer: { url in
                                navigateOrOpenExplorer(url.path)
                            },
                            onOpenTerminal: { url in
                                appState.createTab(directory: url.path)
                            },
                            onOpenGit: { url in
                                appState.addGitTab(directory: url.path)
                            }
                        )
                    }

                    Section("Tags") {
                        ForEach(MacOSTag.allTags) { tag in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(tag.color)
                                    .frame(width: 10, height: 10)
                                Text(tag.name)
                                    .font(.system(size: 11))
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(width: sidebarWidth)
            .onAppear {
                restoreSidebarState()
                expandToActiveTab()
            }
            .onChange(of: appState.activeTabId) { _, _ in
                expandToActiveTab()
            }
            .onChange(of: appState.tabStateVersion) { _, _ in
                expandToActiveTab()
            }
            .onChange(of: expandedFolders) { _, _ in
                persistSidebarState()
            }
            .onChange(of: sidebarWidth) { _, _ in
                persistSidebarState()
            }

            Rectangle()
                .fill(Color.clear)
                .frame(width: 5)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            let newWidth = sidebarWidth + value.translation.width
                            sidebarWidth = min(maxSidebarWidth, max(minSidebarWidth, newWidth))
                        }
                )
                .cursorOnHover(.resizeLeftRight)
        }
    }

    // MARK: - Header

    private var sidebarHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundColor(.accentColor)
            Text("Explorer")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    appState.isShowingFileBrowser = false
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.6))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Fechar Explorer")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Toolbar

    private var sidebarToolbar: some View {
        HStack(spacing: 2) {
            sidebarButton(icon: "scope", help: "Mostrar pasta ativa") {
                revealActiveFolder()
            }

            sidebarButton(icon: "arrow.up.left.and.arrow.down.right", help: "Expandir tudo") {
                expandAll()
            }

            sidebarButton(icon: "arrow.down.right.and.arrow.up.left", help: "Recolher tudo") {
                collapseAll()
            }

            Spacer()

            sidebarButton(icon: "arrow.clockwise", help: "Atualizar") {
                collapseAll()
                expandToActiveTab()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(NexTheme.surface.opacity(0.4))
    }

    private func sidebarButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(NexTheme.textSecondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Tree Actions

    private func revealActiveFolder() {
        guard let dir = activeTabDirectory else { return }
        let home = rootURL.path
        guard dir.hasPrefix(home) else { return }

        var current = home
        let suffix = String(dir.dropFirst(home.count))
        let components = suffix.split(separator: "/").map(String.init)

        for component in components {
            current += "/\(component)"
            expandedFolders.insert(current)
        }
    }

    private func expandAll() {
        let maxDepth = 3
        func expandRecursive(url: URL, depth: Int) {
            guard depth < maxDepth else { return }
            expandedFolders.insert(url.path)
            let fm = FileManager.default
            guard let contents = try? fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
                options: [.skipsHiddenFiles]
            ) else { return }
            for child in contents {
                if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    expandRecursive(url: child, depth: depth + 1)
                }
            }
        }
        expandRecursive(url: rootURL, depth: 0)
    }

    private func collapseAll() {
        expandedFolders.removeAll()
    }

    // MARK: - Persistence

    private func persistSidebarState() {
        let state = SidebarState(
            expandedFolders: Array(expandedFolders),
            sidebarWidth: Double(sidebarWidth),
            rootPath: rootURL.path
        )
        NexPersistence.shared.saveSidebarState(state)
    }

    private func restoreSidebarState() {
        guard let state = NexPersistence.shared.loadSidebarState() else { return }
        expandedFolders = Set(state.expandedFolders)
        sidebarWidth = CGFloat(state.sidebarWidth)
        let restoredRoot = URL(fileURLWithPath: state.rootPath)
        if FileManager.default.fileExists(atPath: restoredRoot.path) {
            rootURL = restoredRoot
        }
    }

    private func favoriteSidebarMenu(_ fav: FavoriteItem) -> some View {
        Group {
            if fav.isDirectory {
                Button { appState.createTab(directory: fav.path) } label: {
                    Label("Terminal", systemImage: "terminal.fill")
                }
                Button { appState.addExplorerTab(directory: fav.path) } label: {
                    Label("Explorer", systemImage: "folder.fill")
                }
                Button { appState.addGitTab(directory: fav.path) } label: {
                    Label("Git", systemImage: "arrow.triangle.branch")
                }
            } else {
                Button { FileItemProvider.openFile(URL(fileURLWithPath: fav.path)) } label: {
                    Label("Abrir", systemImage: "doc")
                }
                let parent = URL(fileURLWithPath: fav.path).deletingLastPathComponent().path
                Button { appState.createTab(directory: parent) } label: {
                    Label("Terminal", systemImage: "terminal.fill")
                }
                Button { appState.addExplorerTab(directory: parent) } label: {
                    Label("Explorer", systemImage: "folder.fill")
                }
                Button { appState.addGitTab(directory: parent) } label: {
                    Label("Git", systemImage: "arrow.triangle.branch")
                }
            }

            Menu("Abrir com...") {
                Button("VS Code") {
                    ExternalEditorLauncher.open(path: fav.path, editor: .vscode)
                }
                Button("Cursor") {
                    ExternalEditorLauncher.open(path: fav.path, editor: .cursor)
                }
            }

            Button("Copiar Path") {
                FileItemProvider.copyPath(URL(fileURLWithPath: fav.path))
            }
            Divider()
            Button("Renomear") {
                startRename(fav)
            }
            Button("Remover dos Favoritos") {
                favoritesStore.remove(fav.id)
            }
        }
    }

    private func startRename(_ fav: FavoriteItem) {
        renamingText = fav.name
        renamingFavoriteID = fav.id
    }

    private func commitRename(_ id: UUID) {
        favoritesStore.rename(id, to: renamingText)
        renamingFavoriteID = nil
        renamingText = ""
    }

    private func cancelRename() {
        renamingFavoriteID = nil
        renamingText = ""
    }

    private func navigateOrOpenExplorer(_ path: String) {
        if var tab = appState.activeTab, tab.isExplorer {
            tab.currentDirectory = path
            tab.title = URL(fileURLWithPath: path).lastPathComponent
            appState.activeTab = tab
        } else {
            appState.addExplorerTab(directory: path)
        }
    }

    private func expandToActiveTab() {
        guard let dir = activeExplorerDirectory else { return }
        let home = rootURL.path
        guard dir.hasPrefix(home) else { return }

        var current = home
        let suffix = String(dir.dropFirst(home.count))
        let components = suffix.split(separator: "/").map(String.init)

        for component in components {
            current += "/\(component)"
            expandedFolders.insert(current)
        }
    }
}

// MARK: - Sidebar Item

struct SidebarItem<MenuContent: View>: View {
    let icon: String
    let label: String
    let isFolder: Bool
    let onTap: () -> Void
    let onContextMenu: () -> MenuContent

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(isFolder ? .accentColor : .secondary)
                    .frame(width: 16)
                Text(label)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { onContextMenu() }
    }
}

// MARK: - Folder Tree Node

struct FolderTreeNode: View {
    let url: URL
    @Binding var expandedFolders: Set<String>
    let highlightedPath: String?
    let depth: Int
    let onOpenExplorer: (URL) -> Void
    let onOpenTerminal: (URL) -> Void
    var onOpenGit: ((URL) -> Void)? = nil

    @State private var children: [URL] = []
    @State private var isGitRepo = false

    private var isExpanded: Bool {
        expandedFolders.contains(url.path)
    }

    private var isHighlighted: Bool {
        guard let path = highlightedPath else { return false }
        return path == url.path || path.hasPrefix(url.path + "/")
    }

    private var isExactMatch: Bool {
        highlightedPath == url.path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                toggleExpand()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(isExactMatch ? .accentColor : (isHighlighted ? .accentColor.opacity(0.6) : .secondary))
                        .frame(width: 12)

                    Image(systemName: isExpanded ? "folder.fill" : "folder")
                        .font(.system(size: 11))
                        .foregroundColor(isExactMatch ? .accentColor : .accentColor.opacity(0.7))
                        .frame(width: 16)

                    Text(url.lastPathComponent)
                        .font(.system(size: 12, weight: isExactMatch ? .semibold : .regular))
                        .foregroundColor(isExactMatch ? .accentColor : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if isGitRepo {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.green)
                    }

                    Spacer()
                }
                .padding(.leading, CGFloat(depth) * 12 + 4)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(isExactMatch ? Color.accentColor.opacity(0.12) : Color.clear)
            .cornerRadius(4)
            .contextMenu {
                Button { onOpenTerminal(url) } label: {
                    Label("Terminal", systemImage: "terminal.fill")
                }
                Button { onOpenExplorer(url) } label: {
                    Label("Explorer", systemImage: "folder.fill")
                }
                if let openGit = onOpenGit {
                    Button { openGit(url) } label: {
                        Label("Git", systemImage: "arrow.triangle.branch")
                    }
                }

                Divider()

                Menu("Abrir com...") {
                    Button("VS Code") {
                        ExternalEditorLauncher.open(path: url.path, editor: .vscode)
                    }
                    Button("Cursor") {
                        ExternalEditorLauncher.open(path: url.path, editor: .cursor)
                    }
                }

                Button { FileItemProvider.openInFinder(url) } label: {
                    Label("Finder", systemImage: "macwindow")
                }

                Divider()

                Button("Copiar Path") { FileItemProvider.copyPath(url) }
                let isFav = FavoritesStore.shared.isFavorite(path: url.path)
                Button(isFav ? "Remover dos Favoritos" : "Adicionar aos Favoritos") {
                    FavoritesStore.shared.toggleFavorite(path: url.path)
                }
            }
            .onTapGesture(count: 2) {
                onOpenExplorer(url)
            }

            if isExpanded {
                ForEach(children, id: \.path) { child in
                    FolderTreeNode(
                        url: child,
                        expandedFolders: $expandedFolders,
                        highlightedPath: highlightedPath,
                        depth: depth + 1,
                        onOpenExplorer: onOpenExplorer,
                        onOpenTerminal: onOpenTerminal,
                        onOpenGit: onOpenGit
                    )
                }
            }
        }
        .onAppear { checkGitRepo() }
        .onChange(of: expandedFolders) { _, newValue in
            if newValue.contains(url.path) && children.isEmpty {
                loadChildren()
            }
        }
    }

    private func toggleExpand() {
        if isExpanded {
            expandedFolders.remove(url.path)
            children = []
        } else {
            expandedFolders.insert(url.path)
            loadChildren()
        }
    }

    private func checkGitRepo() {
        let gitDir = url.appendingPathComponent(".git")
        isGitRepo = FileManager.default.fileExists(atPath: gitDir.path)
    }

    private func loadChildren() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        ) else {
            children = []
            return
        }
        children = contents
            .filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }
}

// MARK: - macOS Tag Model

struct MacOSTag: Identifiable {
    let id: String
    let name: String
    let color: Color

    static let allTags: [MacOSTag] = [
        MacOSTag(id: "Red", name: "Vermelho", color: .red),
        MacOSTag(id: "Orange", name: "Laranja", color: .orange),
        MacOSTag(id: "Yellow", name: "Amarelo", color: .yellow),
        MacOSTag(id: "Green", name: "Verde", color: .green),
        MacOSTag(id: "Blue", name: "Azul", color: .blue),
        MacOSTag(id: "Purple", name: "Roxo", color: .purple),
        MacOSTag(id: "Gray", name: "Cinza", color: .gray),
    ]

    static func color(for tagName: String) -> Color {
        allTags.first { $0.id == tagName || $0.name == tagName }?.color ?? .gray
    }
}
