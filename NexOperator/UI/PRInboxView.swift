import SwiftUI

/// Aggregated PR inbox across every workspace project. Shows only repos
/// matched to a stored OAuth account; surfaces "skipped" repos so the user
/// understands why a project doesn't appear.
struct PRInboxView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @StateObject private var workspace = WorkspaceStore.shared
    @State private var rows: [PRInboxService.InboxRow] = []
    @State private var errors: [(repoName: String, message: String)] = []
    @State private var skippedNoAccount: [String] = []
    @State private var skippedNoRemote: [String] = []
    @State private var isLoading = false
    @State private var stateFilter: PRStatus = .open
    @State private var search: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controls
            Divider()
            content
            if !errors.isEmpty || !skippedNoAccount.isEmpty || !skippedNoRemote.isEmpty {
                Divider()
                footer
            }
        }
        .frame(minWidth: 760, minHeight: 540)
        .background(NexTheme.bg)
        .task { await reload() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.full.fill")
                .font(.system(size: 14))
                .foregroundColor(NexTheme.accent)
            Text("PR Inbox")
                .font(.system(size: 14, weight: .bold))
            Text("\(rows.count) PRs · \(workspace.projects.count) repos")
                .font(.system(size: 11))
                .foregroundColor(NexTheme.textSecondary)
            Spacer()
            if isLoading {
                ProgressView().controlSize(.mini)
                Text("Carregando…").font(.system(size: 11)).foregroundColor(NexTheme.textSecondary)
            }
            Button {
                Task { await reload() }
            } label: {
                Label("Atualizar", systemImage: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            Button("Fechar") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("Estado", selection: $stateFilter) {
                Label("Abertos", systemImage: "arrow.triangle.pull").tag(PRStatus.open)
                Label("Mergeados", systemImage: "arrow.triangle.merge").tag(PRStatus.merged)
                Label("Fechados", systemImage: "xmark.circle").tag(PRStatus.closed)
            }
            .pickerStyle(.segmented)
            .frame(width: 320)
            .onChange(of: stateFilter) { _, _ in Task { await reload() } }

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundColor(NexTheme.textSecondary)
                TextField("Filtrar por título, autor ou repo…", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(NexTheme.surface)
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(NexTheme.border, lineWidth: 0.5))

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let visible = filteredRows
        if isLoading && rows.isEmpty {
            ProgressView("Buscando PRs…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visible.isEmpty {
            empty
        } else {
                ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visible) { row in
                        PRInboxRow(row: row, openInGit: { openInGit(row) }, openInBrowser: { openInBrowser(row) })
                        Divider().opacity(0.4)
                    }
                }
                .padding(.horizontal, 14)
            }
        }
    }

    private var filteredRows: [PRInboxService.InboxRow] {
        let q = search.lowercased()
        guard !q.isEmpty else { return rows }
        return rows.filter {
            $0.pr.title.lowercased().contains(q) ||
            $0.pr.author.lowercased().contains(q) ||
            $0.repoName.lowercased().contains(q) ||
            String($0.pr.number).contains(q)
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundColor(NexTheme.textSecondary.opacity(0.5))
            Text("Sem PRs \(stateFilter == .open ? "abertos" : "")")
                .font(.system(size: 12, weight: .semibold))
            if workspace.projects.isEmpty {
                Text("Adicione repos no Cockpit primeiro.")
                    .font(.system(size: 10)).foregroundColor(NexTheme.textSecondary)
            } else if rows.isEmpty {
                Text("Nenhum repo no Cockpit tem conta OAuth conectada,\nou os PRs estão todos no estado oposto.")
                    .font(.system(size: 10)).foregroundColor(NexTheme.textSecondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Nenhum hit pelo filtro atual.")
                    .font(.system(size: 10)).foregroundColor(NexTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if !errors.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("\(errors.count) repo(s) com erro")
                        .font(.system(size: 10))
                        .foregroundColor(NexTheme.textSecondary)
                }
                .help(errors.map { "\($0.repoName): \($0.message)" }.joined(separator: "\n"))
            }
            if !skippedNoAccount.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .foregroundColor(NexTheme.textSecondary)
                    Text("\(skippedNoAccount.count) sem conta OAuth")
                        .font(.system(size: 10))
                        .foregroundColor(NexTheme.textSecondary)
                }
                .help(skippedNoAccount.joined(separator: ", "))
            }
            if !skippedNoRemote.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "link.badge.minus")
                        .foregroundColor(NexTheme.textSecondary)
                    Text("\(skippedNoRemote.count) sem remote conhecido")
                        .font(.system(size: 10))
                        .foregroundColor(NexTheme.textSecondary)
                }
                .help(skippedNoRemote.joined(separator: ", "))
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(NexTheme.surface.opacity(0.4))
    }

    // MARK: - Actions

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        let result = await PRInboxService.shared.loadInbox(
            projects: workspace.projects,
            state: stateFilter
        )
        rows = result.rows
        errors = result.perRepoErrors
        skippedNoAccount = result.skippedNoAccount
        skippedNoRemote = result.skippedNoRemote
    }

    private func openInGit(_ row: PRInboxService.InboxRow) {
        appState.addGitTab(directory: row.repoPath)
        dismiss()
    }

    private func openInBrowser(_ row: PRInboxService.InboxRow) {
        if let url = URL(string: row.pr.url) {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Row

private struct PRInboxRow: View {
    let row: PRInboxService.InboxRow
    let openInGit: () -> Void
    let openInBrowser: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            statusBadge

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("#\(row.pr.number)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(NexTheme.textSecondary)
                    Text(row.pr.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(NexTheme.textPrimary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Image(systemName: providerIcon)
                        .font(.system(size: 9))
                        .foregroundColor(NexTheme.textSecondary)
                    Text(row.repoName)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(NexTheme.accent)
                    Text("\(row.pr.sourceBranch) → \(row.pr.targetBranch)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(NexTheme.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                Text(row.pr.author)
                    .font(.system(size: 10))
                    .foregroundColor(NexTheme.textSecondary)
                Text(relative(row.pr.createdAt))
                    .font(.system(size: 9))
                    .foregroundColor(NexTheme.textSecondary.opacity(0.8))
            }
            .frame(width: 130, alignment: .trailing)

            HStack(spacing: 4) {
                Button(action: openInBrowser) {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 11))
                        .foregroundColor(NexTheme.textSecondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Abrir PR no navegador")
                Button(action: openInGit) {
                    Image(systemName: "arrow.right.square")
                        .font(.system(size: 11))
                        .foregroundColor(NexTheme.textSecondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Abrir aba Git deste repo")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isHovering ? NexTheme.surfaceHover : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { openInBrowser() }
    }

    private var statusBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: row.pr.status.icon)
                .font(.system(size: 9))
        }
        .foregroundColor(statusColor)
        .frame(width: 18, height: 18)
        .background(statusColor.opacity(0.15))
        .clipShape(Circle())
    }

    private var statusColor: Color {
        switch row.pr.status {
        case .open:   return .green
        case .merged: return .purple
        case .closed: return .red
        }
    }

    private var providerIcon: String {
        switch row.providerType {
        case .github:      return "chevron.left.forwardslash.chevron.right"
        case .azureDevOps: return "cloud"
        }
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}
