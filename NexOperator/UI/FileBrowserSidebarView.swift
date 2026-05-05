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
    /// Sinal para forçar scroll on-demand (botão "scope"). Toda vez que muda
    /// o sidebar consome o valor e scrolla até ele. Usar UUID + path em vez
    /// de só path evita não-disparar quando o usuário clica scope duas
    /// vezes seguidas no mesmo path.
    @State private var revealRequest: (id: UUID, path: String)? = nil

    private let minSidebarWidth: CGFloat = 180
    private let maxSidebarWidth: CGFloat = 400

    /// Diretório que o sidebar destaca/expande. Antes só refletia abas
    /// Explorer — agora qualquer aba (terminal, git, mosaic) propaga o
    /// `currentDirectory`, atendendo ao caso "estou no terminal e quero
    /// ver onde estou no sidebar". Normalizado via `standardizingPath`
    /// pra comparar bem com URLs do FileManager.
    private var activeTabDirectory: String? {
        guard let dir = appState.activeTab?.currentDirectory else { return nil }
        return (dir as NSString).standardizingPath
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                sidebarHeader

                sidebarToolbar

                activeTabBreadcrumb

                Divider()

                ScrollViewReader { proxy in
                List {
                    // "Pastas" fica no topo deliberadamente: é a seção mais
                    // alta e mais usada no dia-a-dia. Antes ficava embaixo
                    // de Favoritos+Recentes e o auto-scroll para a aba
                    // ativa caía numa posição confusa, com Favoritos
                    // ainda ocupando metade da viewport. Agora a árvore é
                    // a primeira coisa que o usuário vê.
                    Section("Pastas") {
                        FolderTreeNode(
                            url: rootURL,
                            expandedFolders: $expandedFolders,
                            highlightedPath: activeTabDirectory,
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
                                .onDrag {
                                    NSItemProvider(object: URL(fileURLWithPath: fav.path) as NSURL)
                                }
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
                                .onDrag {
                                    NSItemProvider(object: URL(fileURLWithPath: recent.path) as NSURL)
                                }
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
                                    Button { appState.addDiskAnalyzerTab(directory: recent.path) } label: {
                                        Label("Disk Analyzer", systemImage: "chart.pie.fill")
                                    }
                                    Divider()
                                    Button("Remover dos Recentes") {
                                        recentStore.remove(recent.path)
                                    }
                                }
                            }
                        }
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
                .onChange(of: activeTabDirectory) { oldDir, newDir in
                    // Reage à navegação dentro da mesma aba — antes só
                    // reagíamos a `tabStateVersion`, mas como `currentDirectory`
                    // pode mudar sem bumpar a version em alguns paths
                    // (mosaic/terminal), observamos o computed direto.
                    expandToActiveTab()
                    // Auto-scroll deliberadamente conservador. Antes
                    // (`anchor: .center`) o sidebar centralizava o item da
                    // aba — só que com Favoritos + Recentes acima da seção
                    // Pastas, "centralizar" jogava o foco visual num
                    // lugar confuso (o usuário relatou "ficar doido").
                    // Agora:
                    //   - SÓ scrolla quando o destino mudou DE FATO,
                    //   - usa .top (item vai pro topo visível) sem animação
                    //     para snap imediato, sem sensação de "deslizou e
                    //     perdi o lugar",
                    //   - delay maior (250ms) para garantir que os nodes
                    //     novos da árvore já existem antes do scrollTo.
                    guard let dir = newDir, dir != oldDir else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        proxy.scrollTo(dir, anchor: .top)
                    }
                }
                .onChange(of: revealRequest?.id) { _, _ in
                    // Scroll on-demand quando o usuário clica no botão "scope".
                    guard let req = revealRequest else { return }
                    expandToActiveTab()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(req.path, anchor: .top)
                        }
                    }
                }
                }
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

    /// Mini-breadcrumb que mostra QUAL aba está sendo refletida no sidebar.
    /// Sempre visível (mesmo quando o usuário rola pra fora) para o foco
    /// nunca se perder. Click leva o sidebar até a pasta da aba.
    @ViewBuilder
    private var activeTabBreadcrumb: some View {
        if let dir = activeTabDirectory {
            let url = URL(fileURLWithPath: dir)
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let display = dir.hasPrefix(home) ? "~" + dir.dropFirst(home.count) : dir
            let folderName = url.lastPathComponent

            Button {
                revealActiveFolder()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "scope")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.accentColor)
                    Text(folderName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.accentColor)
                        .lineLimit(1)
                    Text(display)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(NexTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                    Image(systemName: "arrow.right.to.line")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(NexTheme.textSecondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.10))
                .overlay(
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.4))
                        .frame(width: 2),
                    alignment: .leading
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Aba ativa: \(dir)\nClique para focar no sidebar")
        }
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
        // Sinaliza para o ScrollViewReader rolar até a pasta — usa um id
        // novo a cada chamada para que cliques repetidos no botão "scope"
        // sempre disparem o scroll (mesmo se o path não mudou).
        revealRequest = (UUID(), dir)
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
                Button { appState.addDiskAnalyzerTab(directory: fav.path) } label: {
                    Label("Disk Analyzer", systemImage: "chart.pie.fill")
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
    /// Pulsa o background quando este node se torna o destacado da aba
    /// ativa — chama atenção visual após o auto-scroll. Decai naturalmente
    /// para o highlight estável (opacity 0.12) em ~900 ms.
    @State private var pulseHighlight = false

    private var isExpanded: Bool {
        expandedFolders.contains(url.path)
    }

    private var isHighlighted: Bool {
        guard let path = highlightedPath else { return false }
        let normalized = (url.path as NSString).standardizingPath
        return path == normalized || path.hasPrefix(normalized + "/")
    }

    private var isExactMatch: Bool {
        guard let path = highlightedPath else { return false }
        return path == (url.path as NSString).standardizingPath
    }

    /// Path normalizado — usado como `.id` para o ScrollViewReader localizar
    /// este node pelo mesmo formato de string que o sidebar usa.
    private var normalizedPath: String {
        (url.path as NSString).standardizingPath
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

                    if isExactMatch {
                        // Tag visual deixando claro que ESTE é o path da
                        // aba atualmente focada. Ajuda quando o usuário
                        // abriu múltiplas abas e quer confirmar onde está.
                        Text("aba")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.accentColor)
                            .cornerRadius(3)
                    }

                    Spacer()
                }
                .padding(.leading, CGFloat(depth) * 12 + 4)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                Color.accentColor.opacity(
                    isExactMatch
                        ? (pulseHighlight ? 0.40 : 0.12)
                        : 0
                )
            )
            .cornerRadius(4)
            .id(normalizedPath)
            .onDrag {
                NSItemProvider(object: url as NSURL)
            }
            .onChange(of: isExactMatch) { _, newValue in
                guard newValue else { return }
                triggerPulse()
            }
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
        .onAppear {
            checkGitRepo()
            // Bug fix crítico: quando o sidebar pré-expande pastas para
            // chegar até o diretório da aba ativa, os FolderTreeNode dos
            // descendentes só aparecem APÓS o parent renderizar. Para esses
            // nodes, `expandedFolders` já contém seu path no momento do
            // primeiro render — `.onChange` não dispara para o valor
            // inicial, então sem isto eles ficavam vazios até o usuário
            // clicar manualmente.
            if isExpanded && children.isEmpty {
                loadChildren()
            }
            // Pulse inicial quando o node JÁ aparece destacado (caso de
            // troca de aba que pré-expandiu até ele).
            if isExactMatch {
                triggerPulse()
            }
        }
        .onChange(of: expandedFolders) { _, newValue in
            if newValue.contains(url.path) && children.isEmpty {
                loadChildren()
            }
        }
    }

    private func triggerPulse() {
        pulseHighlight = true
        // Delay mínimo pra garantir que o snap inicial seja visível
        // antes do decay começar.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeOut(duration: 0.9)) {
                pulseHighlight = false
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
