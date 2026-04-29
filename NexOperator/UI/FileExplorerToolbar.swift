import SwiftUI

struct FileExplorerPathBar: View {
    let url: URL
    let onNavigate: (URL) -> Void

    @State private var isEditing = false
    @State private var editText = ""
    @State private var suggestions: [URL] = []
    @State private var selectedSuggestionIndex = -1
    @FocusState private var textFieldFocused: Bool

    private var components: [(name: String, url: URL)] {
        var parts: [(String, URL)] = []
        var current = url.standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL

        while current.path != "/" {
            let name = current == home ? "~" : current.lastPathComponent
            parts.insert((name, current), at: 0)
            current = current.deletingLastPathComponent()
        }
        if parts.isEmpty || parts.first?.1.path != "/" {
            parts.insert(("/", URL(fileURLWithPath: "/")), at: 0)
        }
        return parts
    }

    var body: some View {
        ZStack {
            if isEditing {
                editablePathBar
            } else {
                breadcrumbBar
            }
        }
        .frame(height: 28)
        .background(NexTheme.surface)
    }

    // MARK: - Breadcrumb mode

    private var breadcrumbBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8))
                                .foregroundColor(NexTheme.textSecondary.opacity(0.5))
                        }
                        Button {
                            onNavigate(component.url)
                        } label: {
                            Text(component.name)
                                .font(.system(size: 11, weight: component.url == url ? .semibold : .regular, design: .monospaced))
                                .foregroundColor(component.url == url ? NexTheme.textPrimary : NexTheme.textSecondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(component.url == url ? NexTheme.surfaceHover : Color.clear)
                                .cornerRadius(4)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                startEditing()
            }

            Spacer(minLength: 0)

            Button { copyPath() } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundColor(NexTheme.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copiar path (⌘⇧C)")

            Button { startEditing() } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 10))
                    .foregroundColor(NexTheme.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Editar path (⌘L)")
            .padding(.trailing, 4)
        }
    }

    // MARK: - Editable mode

    private var editablePathBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10))
                    .foregroundColor(NexTheme.accent)
                    .padding(.leading, 8)

                PathTextField(
                    text: $editText,
                    isFocused: $textFieldFocused,
                    onCommit: { commitPath() },
                    onCancel: { cancelEditing() },
                    onTab: { acceptSuggestion() },
                    onArrowDown: { moveSuggestion(1) },
                    onArrowUp: { moveSuggestion(-1) }
                )
                .font(.system(size: 11, design: .monospaced))

                Button { cancelEditing() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(NexTheme.textSecondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)
            }
            .frame(height: 28)

            if !suggestions.isEmpty {
                suggestionsPopup
            }
        }
        .onAppear {
            textFieldFocused = true
        }
        .onChange(of: editText) { _, newValue in
            updateSuggestions(for: newValue)
        }
    }

    private var suggestionsPopup: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(suggestions.prefix(8).enumerated()), id: \.element.path) { index, suggestion in
                    let isSelected = index == selectedSuggestionIndex
                    Button {
                        editText = suggestion.path
                        suggestions = []
                        commitPath()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 10))
                                .foregroundColor(NexTheme.accent.opacity(0.7))
                            Text(suggestion.lastPathComponent)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(NexTheme.textPrimary)
                            Spacer()
                            Text(shortenPath(suggestion.deletingLastPathComponent().path))
                                .font(.system(size: 10))
                                .foregroundColor(NexTheme.textSecondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(isSelected ? NexTheme.accent.opacity(0.15) : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: 200)
        .background(NexTheme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(NexTheme.border, lineWidth: 0.5)
        )
        .cornerRadius(6)
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        .padding(.horizontal, 4)
    }

    // MARK: - Actions

    private func startEditing() {
        editText = url.path
        isEditing = true
        selectedSuggestionIndex = -1
        suggestions = []
    }

    private func cancelEditing() {
        isEditing = false
        editText = ""
        suggestions = []
        textFieldFocused = false
    }

    private func commitPath() {
        let path = (editText as NSString).expandingTildeInPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { cancelEditing(); return }

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            onNavigate(URL(fileURLWithPath: path))
        }
        cancelEditing()
    }

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    private func acceptSuggestion() {
        if selectedSuggestionIndex >= 0, selectedSuggestionIndex < suggestions.count {
            editText = suggestions[selectedSuggestionIndex].path + "/"
            selectedSuggestionIndex = -1
            updateSuggestions(for: editText)
        } else if let first = suggestions.first {
            editText = first.path + "/"
            updateSuggestions(for: editText)
        }
    }

    private func moveSuggestion(_ delta: Int) {
        guard !suggestions.isEmpty else { return }
        let max = min(suggestions.count, 8)
        selectedSuggestionIndex = (selectedSuggestionIndex + delta + max) % max
    }

    private func updateSuggestions(for text: String) {
        let path = (text as NSString).expandingTildeInPath
        guard !path.isEmpty else { suggestions = []; return }

        let fm = FileManager.default
        let searchURL: URL
        let prefix: String

        if path.hasSuffix("/") {
            searchURL = URL(fileURLWithPath: path)
            prefix = ""
        } else {
            searchURL = URL(fileURLWithPath: path).deletingLastPathComponent()
            prefix = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        }

        guard fm.fileExists(atPath: searchURL.path) else {
            suggestions = []
            return
        }

        do {
            let contents = try fm.contentsOfDirectory(
                at: searchURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
                options: [.skipsHiddenFiles]
            )
            suggestions = contents
                .filter { url in
                    let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    guard isDir else { return false }
                    if prefix.isEmpty { return true }
                    return url.lastPathComponent.lowercased().hasPrefix(prefix)
                }
                .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        } catch {
            suggestions = []
        }
        selectedSuggestionIndex = -1
    }

    private func shortenPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// MARK: - Path TextField with keyboard handling

struct PathTextField: NSViewRepresentable {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let onCommit: () -> Void
    let onCancel: () -> Void
    let onTab: () -> Void
    let onArrowDown: () -> Void
    let onArrowUp: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        field.isBordered = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.delegate = context.coordinator
        field.stringValue = text
        field.cell?.lineBreakMode = .byTruncatingHead
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            field.selectText(nil)
        }
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: PathTextField

        init(_ parent: PathTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onCommit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                parent.onTab()
                return true
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                parent.onArrowDown()
                return true
            }
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                parent.onArrowUp()
                return true
            }
            return false
        }
    }
}

struct FileExplorerToolbar: View {
    @EnvironmentObject var appState: AppState
    let provider: FileItemProvider
    let canGoBack: Bool
    let canGoForward: Bool
    @Binding var viewMode: ExplorerViewMode
    @Binding var isSearching: Bool
    let onBack: () -> Void
    let onForward: () -> Void
    let onUp: () -> Void
    let onNewFolder: () -> Void
    let onTerminalHere: () -> Void
    let onToggleHidden: () -> Void
    let onAttachSelected: () -> Void
    let onRefresh: () -> Void
    let selectedCount: Int

    private var isCurrentDirGitRepo: Bool {
        FileManager.default.fileExists(atPath: provider.currentURL.appendingPathComponent(".git").path)
    }

    var body: some View {
        HStack(spacing: 2) {
            Group {
                toolbarButton(icon: "chevron.left", action: onBack, disabled: !canGoBack, help: "Voltar")
                toolbarButton(icon: "chevron.right", action: onForward, disabled: !canGoForward, help: "Avançar")
                toolbarButton(icon: "arrow.up", action: onUp, help: "Pasta pai")
            }

            Divider().frame(height: 16).padding(.horizontal, 4)

            toolbarButton(icon: "folder.badge.plus", action: onNewFolder, help: "Nova pasta")
            toolbarButton(icon: "terminal.fill", action: onTerminalHere, help: "Terminal aqui")
            gitToolbarButton

            Divider().frame(height: 16).padding(.horizontal, 2)

            editorButton(editor: .vscode)
            editorButton(editor: .cursor)

            if selectedCount > 0 {
                toolbarButton(icon: "paperclip", action: onAttachSelected, help: "Anexar ao prompt")

                Text("\(selectedCount) selecionado(s)")
                    .font(.system(size: 10))
                    .foregroundColor(NexTheme.textSecondary)
            }

            Divider().frame(height: 16).padding(.horizontal, 2)

            toolbarButton(
                icon: isSearching ? "magnifyingglass.circle.fill" : "magnifyingglass",
                action: { isSearching.toggle() },
                help: "Buscar na pasta (⌘F)"
            )

            Spacer()

            toolbarButton(icon: "arrow.clockwise", action: onRefresh, help: "Atualizar (⌘R)")

            toolbarButton(
                icon: provider.showHidden ? "eye.slash" : "eye",
                action: onToggleHidden,
                help: provider.showHidden ? "Ocultar arquivos ocultos" : "Mostrar arquivos ocultos"
            )

            Divider().frame(height: 16).padding(.horizontal, 2)

            viewModeToggle

            sortMenu
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
        .background(NexTheme.surface.opacity(0.6))
    }

    private func editorButton(editor: ExternalEditor) -> some View {
        let installed = editor.appBundleIds.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        return Button {
            ExternalEditorLauncher.open(path: provider.currentURL.path, editor: editor)
        } label: {
            Text(editor == .vscode ? "VS" : "{ }")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(installed ? NexTheme.textSecondary : NexTheme.textSecondary.opacity(0.3))
                .frame(width: NexTheme.hitTargetSmall, height: NexTheme.hitTargetSmall)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!installed)
        .help("Abrir em \(editor.displayName)")
    }

    private var gitToolbarButton: some View {
        Button {
            appState.addGitTab(directory: provider.currentURL.path)
        } label: {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: NexTheme.iconSizeSmall))
                .foregroundColor(isCurrentDirGitRepo ? .green : NexTheme.textSecondary)
                .frame(width: NexTheme.hitTargetSmall, height: NexTheme.hitTargetSmall)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isCurrentDirGitRepo ? "Abrir em Git (repositório detectado)" : "Abrir em Git")
    }

    private func toolbarButton(icon: String, action: @escaping () -> Void, disabled: Bool = false, help: String) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: NexTheme.iconSizeSmall))
                .foregroundColor(disabled ? NexTheme.textSecondary.opacity(0.3) : NexTheme.textSecondary)
                .frame(width: NexTheme.hitTargetSmall, height: NexTheme.hitTargetSmall)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }

    private var viewModeToggle: some View {
        HStack(spacing: 0) {
            viewModeButton(icon: "list.bullet", mode: .list, help: "Lista")
            viewModeButton(icon: "square.grid.2x2", mode: .gallery, help: "Galeria")
        }
        .background(NexTheme.surface.opacity(0.6))
        .cornerRadius(4)
    }

    private func viewModeButton(icon: String, mode: ExplorerViewMode, help: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                viewMode = mode
            }
        } label: {
            Image(systemName: icon)
                .font(.system(size: NexTheme.iconSizeSmall))
                .foregroundColor(viewMode == mode ? NexTheme.accent : NexTheme.textSecondary)
                .frame(width: NexTheme.hitTargetSmall, height: NexTheme.hitTargetSmall)
                .background(viewMode == mode ? NexTheme.accent.opacity(0.15) : Color.clear)
                .cornerRadius(3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var sortMenu: some View {
        Menu {
            ForEach(FileSortField.allCases, id: \.self) { field in
                Button {
                    if provider.sortField == field {
                        provider.sortOrder = provider.sortOrder.toggled
                    } else {
                        provider.sortField = field
                        provider.sortOrder = .ascending
                    }
                    provider.sortItems()
                } label: {
                    HStack {
                        Text(sortLabel(field))
                        if provider.sortField == field {
                            Image(systemName: provider.sortOrder == .ascending ? "chevron.up" : "chevron.down")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: NexTheme.iconSizeSmall))
                .foregroundColor(NexTheme.textSecondary)
                .frame(width: NexTheme.hitTargetSmall, height: NexTheme.hitTargetSmall)
        }
        .menuStyle(.borderlessButton)
        .frame(width: NexTheme.hitTargetSmall)
        .help("Ordenar")
    }

    private func sortLabel(_ field: FileSortField) -> String {
        switch field {
        case .name: return "Nome"
        case .size: return "Tamanho"
        case .modified: return "Modificado"
        case .created: return "Criado"
        case .type: return "Tipo"
        }
    }
}
