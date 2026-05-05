import SwiftUI

/// Cross-repo commit search. Lets the architect answer "em qual dos meus 25
/// repos eu commitei isso?" sem ter que abrir cada um. Modes: subject text,
/// commit hash, author name.
struct CrossRepoSearchView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @StateObject private var store = WorkspaceStore.shared
    private let service = CrossRepoSearchService.shared

    @State private var query: String = ""
    @State private var mode: CrossRepoSearchService.Mode = .message
    @State private var results: [CrossRepoSearchService.RepoResult] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchBar
            Divider()
            content
        }
        .frame(minWidth: 720, minHeight: 520)
        .background(NexTheme.bg)
        .onAppear { queryFocused = true }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 14))
                .foregroundColor(NexTheme.accent)
            Text("Busca cross-repo")
                .font(.system(size: 14, weight: .bold))
            Text("\(store.projects.count) repos")
                .font(.system(size: 11))
                .foregroundColor(NexTheme.textSecondary)
            Spacer()
            if isSearching {
                ProgressView().controlSize(.mini)
                Text("Buscando…").font(.system(size: 11)).foregroundColor(NexTheme.textSecondary)
            }
            Button("Fechar") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Picker("Modo", selection: $mode) {
                ForEach(CrossRepoSearchService.Mode.allCases) { m in
                    Label(m.rawValue, systemImage: m.systemImage).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 280)

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(NexTheme.textSecondary)
                TextField(placeholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: mode == .hash ? .monospaced : .default))
                    .focused($queryFocused)
                    .onSubmit { runSearch() }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(NexTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(NexTheme.surface)
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(NexTheme.border, lineWidth: 0.5))

            Button {
                runSearch()
            } label: {
                Label("Buscar", systemImage: "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(NexTheme.accent)
                    .foregroundColor(.white)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var placeholder: String {
        switch mode {
        case .message: return "Texto do commit (ex: 'fix login')"
        case .hash:    return "SHA completo ou abreviado (ex: a1b2c3d)"
        case .author:  return "Nome ou email do autor"
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if results.isEmpty && !isSearching {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(filteredResults) { repoResult in
                        repoSection(repoResult)
                    }
                }
                .padding(14)
            }
        }
    }

    private var filteredResults: [CrossRepoSearchService.RepoResult] {
        results.filter { !$0.hits.isEmpty || $0.error != nil }
    }

    private func repoSection(_ r: CrossRepoSearchService.RepoResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10))
                    .foregroundColor(NexTheme.accent)
                Text(r.repoName)
                    .font(.system(size: 12, weight: .semibold))
                if let err = r.error {
                    Text("erro: \(err)")
                        .font(.system(size: 9))
                        .foregroundColor(.red)
                } else {
                    Text("\(r.hits.count) hit\(r.hits.count == 1 ? "" : "s")")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(NexTheme.textSecondary)
                        .padding(.horizontal, 5)
                        .background(NexTheme.surface)
                        .cornerRadius(8)
                }
                Spacer()
                Button {
                    appState.addGitTab(directory: r.repoPath)
                    dismiss()
                } label: {
                    Label("Abrir aba Git", systemImage: "arrow.up.right.square")
                        .font(.system(size: 10))
                        .foregroundColor(NexTheme.accent)
                }
                .buttonStyle(.plain)
            }
            VStack(spacing: 0) {
                ForEach(r.hits) { hit in
                    hitRow(hit, repoPath: r.repoPath)
                    if hit.id != r.hits.last?.id {
                        Divider().opacity(0.4)
                    }
                }
            }
            .background(NexTheme.surface.opacity(0.4))
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(NexTheme.border, lineWidth: 0.5))
        }
    }

    private func hitRow(_ hit: CrossRepoSearchService.Hit, repoPath: String) -> some View {
        HStack(spacing: 10) {
            Text(hit.shortHash)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(NexTheme.accent)
                .frame(width: 60, alignment: .leading)

            Text(hit.subject)
                .font(.system(size: 12))
                .foregroundColor(NexTheme.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(hit.authorName)
                .font(.system(size: 10))
                .foregroundColor(NexTheme.textSecondary)
                .frame(width: 120, alignment: .leading)
                .lineLimit(1)

            Text(relativeDate(hit.date))
                .font(.system(size: 10))
                .foregroundColor(NexTheme.textSecondary)
                .frame(width: 80, alignment: .trailing)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(hit.hash, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 9))
                    .foregroundColor(NexTheme.textSecondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copiar SHA completo")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture {
            appState.addGitTab(directory: repoPath)
            dismiss()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass.circle")
                .font(.system(size: 36))
                .foregroundColor(NexTheme.textSecondary.opacity(0.5))
            Text(query.isEmpty ? "Digite uma consulta" : "Nenhum hit encontrado")
                .font(.system(size: 12, weight: .semibold))
            Text(query.isEmpty
                 ? "Busca em paralelo nos \(store.projects.count) repos do Cockpit."
                 : "Tente outro modo (Mensagem, Hash, Autor) ou ajuste o termo.")
                .font(.system(size: 10))
                .foregroundColor(NexTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searchTask?.cancel()
        searchTask = Task { @MainActor in
            isSearching = true
            results = []
            let res = await service.search(mode: mode, query: q, projects: store.projects)
            if !Task.isCancelled {
                results = res
                isSearching = false
            }
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}
