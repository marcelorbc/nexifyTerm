import SwiftUI
import AppKit

struct GlobalSearchView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var searchEngine = FileSearchEngine()
    @State private var selectedIndex = 0
    @FocusState private var isFieldFocused: Bool
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            searchField

            Divider()

            if searchEngine.results.isEmpty && searchEngine.searchText.isEmpty {
                emptyState
            } else if searchEngine.isSearching && searchEngine.results.isEmpty {
                loadingState
            } else if !searchEngine.searchText.isEmpty && searchEngine.results.isEmpty && !searchEngine.isSearching {
                noResults
            } else {
                resultsList
            }
        }
        .frame(width: 620, height: 440)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(NexTheme.border.opacity(0.5), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.35), radius: 30, y: 10)
        .onAppear { isFieldFocused = true }
        .onDisappear { searchEngine.cancel() }
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(NexTheme.accent)

            GlobalSearchTextField(
                text: $searchEngine.searchText,
                isFocused: $isFieldFocused,
                onArrowUp: { moveSelection(-1) },
                onArrowDown: { moveSelection(1) },
                onSubmit: { openSelected() },
                onEscape: { onDismiss() }
            )
            .font(.system(size: 15))

            if searchEngine.isSearching {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.8)
            }

            if !searchEngine.searchText.isEmpty {
                Button {
                    searchEngine.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(NexTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .onChange(of: searchEngine.searchText) { _, newValue in
            selectedIndex = 0
            searchEngine.searchGlobal(query: newValue)
        }
    }

    // MARK: - States

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 36))
                .foregroundColor(NexTheme.textSecondary.opacity(0.3))

            Text("Buscar arquivos no sistema")
                .font(.system(size: 14))
                .foregroundColor(NexTheme.textSecondary)

            HStack(spacing: 16) {
                shortcutHint(key: "↑↓", label: "Navegar")
                shortcutHint(key: "↩", label: "Abrir")
                shortcutHint(key: "⌘↩", label: "Revelar")
                shortcutHint(key: "esc", label: "Fechar")
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Buscando com Spotlight...")
                .font(.system(size: 12))
                .foregroundColor(NexTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResults: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundColor(NexTheme.textSecondary.opacity(0.3))
            Text("Nenhum resultado para \"\(searchEngine.searchText)\"")
                .font(.system(size: 13))
                .foregroundColor(NexTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Results

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(searchEngine.results.enumerated()), id: \.element.id) { index, result in
                        resultRow(result, isSelected: index == selectedIndex)
                            .id(index)
                            .onTapGesture {
                                selectedIndex = index
                                openResult(result)
                            }
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: selectedIndex) { _, newValue in
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    private func resultRow(_ result: FileSearchEngine.FileSearchResult, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: result.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                highlightedName(result.name, query: searchEngine.searchText)
                    .lineLimit(1)

                Text(result.displayPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(NexTheme.textSecondary.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if result.isDirectory {
                    Text("Pasta")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(NexTheme.accent.opacity(0.8))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(NexTheme.accent.opacity(0.1))
                        .cornerRadius(3)
                } else {
                    Text(result.url.pathExtension.uppercased())
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(NexTheme.textSecondary)
                }

                if !result.isDirectory && result.size > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: result.size, countStyle: .file))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(NexTheme.textSecondary.opacity(0.6))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? NexTheme.accent.opacity(0.12) : Color.clear)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
    }

    // MARK: - Highlighted Name

    private func highlightedName(_ name: String, query: String) -> some View {
        let lowerName = name.lowercased()
        let lowerQuery = query.lowercased()

        if let range = lowerName.range(of: lowerQuery) {
            let startIndex = name.index(name.startIndex, offsetBy: lowerName.distance(from: lowerName.startIndex, to: range.lowerBound))
            let endIndex = name.index(startIndex, offsetBy: query.count)

            let before = String(name[name.startIndex..<startIndex])
            let match = String(name[startIndex..<endIndex])
            let after = String(name[endIndex...])

            return Text(before)
                .font(.system(size: 13))
                .foregroundColor(NexTheme.textPrimary)
            + Text(match)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(NexTheme.accent)
            + Text(after)
                .font(.system(size: 13))
                .foregroundColor(NexTheme.textPrimary)
        }

        return Text(name)
            .font(.system(size: 13))
            .foregroundColor(NexTheme.textPrimary)
        + Text("")
    }

    // MARK: - Navigation

    private func moveSelection(_ delta: Int) {
        guard !searchEngine.results.isEmpty else { return }
        selectedIndex = max(0, min(searchEngine.results.count - 1, selectedIndex + delta))
    }

    private func openSelected() {
        guard selectedIndex >= 0, selectedIndex < searchEngine.results.count else { return }
        let result = searchEngine.results[selectedIndex]

        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.command) {
            FileItemProvider.openInFinder(result.url)
        } else {
            openResult(result)
        }
    }

    private func openResult(_ result: FileSearchEngine.FileSearchResult) {
        onDismiss()

        if result.isDirectory {
            appState.addExplorerTab(directory: result.url.path)
        } else {
            let parentDir = result.url.deletingLastPathComponent().path
            appState.addExplorerTab(directory: parentDir)
        }
    }

    // MARK: - Helpers

    private func shortcutHint(key: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(NexTheme.textSecondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(NexTheme.surface)
                .cornerRadius(3)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(NexTheme.border, lineWidth: 0.5)
                )

            Text(label)
                .font(.system(size: 10))
                .foregroundColor(NexTheme.textSecondary.opacity(0.7))
        }
    }
}

// MARK: - Global Search TextField (handles keyboard navigation)

struct GlobalSearchTextField: NSViewRepresentable {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let onArrowUp: () -> Void
    let onArrowDown: () -> Void
    let onSubmit: () -> Void
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.font = .systemFont(ofSize: 15, weight: .regular)
        field.isBordered = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.placeholderString = "Buscar arquivos, pastas..."
        field.delegate = context.coordinator
        field.stringValue = text
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
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
        let parent: GlobalSearchTextField

        init(_ parent: GlobalSearchTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                parent.onArrowUp()
                return true
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                parent.onArrowDown()
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onEscape()
                return true
            }
            return false
        }
    }
}
