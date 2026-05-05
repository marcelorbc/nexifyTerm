import SwiftUI
import UniformTypeIdentifiers

/// Multi-repo Cockpit. One row per project, grouped by `group`. Bulk
/// fetch/pull, "needs my attention" filter, drag-and-drop add, click-to-open.
struct CockpitView: View {
    @StateObject private var viewModel = CockpitViewModel()
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var isShowingSearch = false
    @State private var isShowingPRInbox = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            kpiRow
            Divider()
            if !viewModel.allTags.isEmpty {
                tagChipsRow
                Divider()
            }
            ZStack(alignment: .bottom) {
                bodyContent
                if !viewModel.bulkResults.isEmpty {
                    bulkResultsBanner
                        .padding(12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(NexTheme.bg)
        .onAppear { viewModel.onAppear() }
        .onDisappear { viewModel.onDisappear() }
        .sheet(isPresented: $viewModel.isShowingAddSheet) { addProjectSheet }
        .sheet(isPresented: $isShowingSearch) {
            CrossRepoSearchView()
                .environmentObject(appState)
        }
        .sheet(isPresented: $isShowingPRInbox) {
            PRInboxView()
                .environmentObject(appState)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(NexTheme.accent)
            Text("Cockpit")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(NexTheme.textPrimary)

            Text("\(viewModel.stats.total) repos")
                .font(.system(size: 11))
                .foregroundColor(NexTheme.textSecondary)

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(NexTheme.textSecondary)
                TextField("Buscar repo, grupo ou tag…", text: $viewModel.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 220)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(NexTheme.surface)
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(NexTheme.border, lineWidth: 0.5))

            filterMenu
            bulkActionsMenu

            Button {
                isShowingSearch = true
            } label: {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(NexTheme.textSecondary)
                    .frame(width: NexTheme.hitTargetSmall, height: NexTheme.hitTargetSmall)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Buscar commits cross-repo")
            .disabled(viewModel.store.projects.isEmpty)

            Button {
                isShowingPRInbox = true
            } label: {
                Image(systemName: "tray.full")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(NexTheme.textSecondary)
                    .frame(width: NexTheme.hitTargetSmall, height: NexTheme.hitTargetSmall)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("PR Inbox agregado")
            .disabled(viewModel.store.projects.isEmpty)

            Button {
                viewModel.isShowingAddSheet = true
            } label: {
                Label("Adicionar", systemImage: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(NexTheme.accent)
                    .foregroundColor(.white)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .help("Adicionar repositório (ou arraste uma pasta)")

            Button {
                Task { await viewModel.refreshAll() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(NexTheme.textSecondary)
                    .frame(width: NexTheme.hitTargetSmall, height: NexTheme.hitTargetSmall)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Atualizar todos os snapshots")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private var filterMenu: some View {
        Menu {
            ForEach(CockpitViewModel.Filter.allCases) { f in
                Button {
                    viewModel.filter = f
                } label: {
                    Label(f.rawValue, systemImage: f.systemImage)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: viewModel.filter.systemImage)
                    .font(.system(size: 10))
                Text(viewModel.filter.rawValue)
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundColor(NexTheme.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(NexTheme.surface)
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(NexTheme.border, lineWidth: 0.5))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var bulkActionsMenu: some View {
        Menu {
            Section(viewModel.selection.isEmpty ? "Em todos os repos" : "Em \(viewModel.selection.count) selecionados") {
                Button {
                    Task { await viewModel.runBulk(.fetchPrune) }
                } label: {
                    Label("Fetch + prune", systemImage: "scissors")
                }
                Button {
                    Task { await viewModel.runBulk(.fetch) }
                } label: {
                    Label("Fetch", systemImage: "arrow.clockwise")
                }
                Divider()
                Button {
                    Task { await viewModel.runBulk(.pull) }
                } label: {
                    Label("Pull --ff-only", systemImage: "arrow.down.to.line")
                }
                Button {
                    Task { await viewModel.runBulk(.pullRebase) }
                } label: {
                    Label("Pull --rebase", systemImage: "arrow.triangle.swap")
                }
            }
        } label: {
            HStack(spacing: 4) {
                if viewModel.isBulkRunning {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 10))
                }
                Text("Em lote")
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundColor(.orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.orange.opacity(0.12))
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.orange.opacity(0.4), lineWidth: 0.5))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(viewModel.store.projects.isEmpty)
        .help("Executar fetch/pull em todos ou nos selecionados")
    }

    // MARK: - KPIs

    private var kpiRow: some View {
        HStack(spacing: 10) {
            kpi(icon: "tray.full", label: "Total", value: viewModel.stats.total, color: NexTheme.textPrimary)
            kpi(icon: "exclamationmark.bubble.fill", label: "Atenção", value: viewModel.stats.attention, color: .orange, action: { viewModel.filter = .attention })
            kpi(icon: "pencil.tip.crop.circle", label: "Com mudanças", value: viewModel.stats.dirty, color: .yellow, action: { viewModel.filter = .dirty })
            kpi(icon: "arrow.down.circle.fill", label: "Atrás", value: viewModel.stats.behind, color: .orange, action: { viewModel.filter = .behind })
            kpi(icon: "arrow.up.circle.fill", label: "À frente", value: viewModel.stats.ahead, color: .green, action: { viewModel.filter = .ahead })
            kpi(icon: "xmark.octagon.fill", label: "Erros", value: viewModel.stats.errors, color: .red, action: { viewModel.filter = .errors })
            Spacer()
            if !viewModel.selection.isEmpty {
                Button("Limpar seleção (\(viewModel.selection.count))") {
                    viewModel.clearSelection()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(NexTheme.accent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func kpi(
        icon: String,
        label: String,
        value: Int,
        color: Color,
        action: (() -> Void)? = nil
    ) -> some View {
        Button {
            action?()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(color)
                Text("\(value)")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(NexTheme.textPrimary)
                Text(label)
                    .font(.system(size: 10))
                    .foregroundColor(NexTheme.textSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(NexTheme.surface)
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.25), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }

    // MARK: - Tag chips

    private var tagChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                tagChip(label: "Todas", isSelected: viewModel.selectedTag == nil) {
                    viewModel.selectedTag = nil
                }
                ForEach(viewModel.allTags, id: \.self) { tag in
                    tagChip(label: tag, isSelected: viewModel.selectedTag == tag) {
                        viewModel.selectedTag = (viewModel.selectedTag == tag) ? nil : tag
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
    }

    private func tagChip(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .white : NexTheme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(isSelected ? NexTheme.accent : NexTheme.surface)
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isSelected ? NexTheme.accent : NexTheme.border, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Body

    @ViewBuilder
    private var bodyContent: some View {
        if viewModel.store.projects.isEmpty {
            emptyState
        } else if viewModel.filteredProjects.isEmpty {
            emptyFiltered
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(viewModel.groupedFiltered, id: \.group) { entry in
                        groupSection(title: entry.group, projects: entry.projects)
                    }
                }
                .padding(14)
            }
        }
    }

    private func groupSection(title: String, projects: [WorkspaceProject]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundColor(NexTheme.textSecondary)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(NexTheme.textSecondary)
                Text("\(projects.count)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(NexTheme.textSecondary)
                    .padding(.horizontal, 5)
                    .background(NexTheme.surface)
                    .cornerRadius(8)
                Spacer()
            }
            VStack(spacing: 0) {
                ForEach(projects) { project in
                    CockpitRow(
                        project: project,
                        snapshot: viewModel.snapshots[project.path],
                        isInFlight: viewModel.inFlightPaths.contains(project.path),
                        isSelected: viewModel.selection.contains(project.id),
                        onToggleSelect: { viewModel.toggleSelection(project) },
                        onTogglePin: { viewModel.togglePin(project) },
                        onOpen: { openInGitTab(project) },
                        onOpenInFinder: { openInFinder(project) },
                        onRefresh: { Task { await viewModel.refresh(project: project) } },
                        onRemove: { viewModel.remove(project) }
                    )
                    if project.id != projects.last?.id {
                        Divider().opacity(0.4)
                    }
                }
            }
            .background(NexTheme.surface.opacity(0.4))
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(NexTheme.border, lineWidth: 0.5))
        }
    }

    // MARK: - Empty / fallback states

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 42))
                .foregroundColor(NexTheme.textSecondary.opacity(0.4))
            Text("Nenhum repositório no Cockpit")
                .font(.system(size: 14, weight: .semibold))
            Text("Adicione seus 25 sistemas para acompanhar o status de todos\nem um único painel — branch, ahead/behind e mudanças locais.")
                .font(.system(size: 11))
                .foregroundColor(NexTheme.textSecondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Button {
                    viewModel.isShowingAddSheet = true
                } label: {
                    Label("Adicionar manualmente", systemImage: "plus.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button {
                    pickDirectoryAndAdd()
                } label: {
                    Label("Escolher pasta…", systemImage: "folder.badge.plus")
                }
                .controlSize(.small)
            }
            Text("Dica: você também pode arrastar pastas direto aqui.")
                .font(.system(size: 10))
                .foregroundColor(NexTheme.textSecondary.opacity(0.8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyFiltered: some View {
        VStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 30))
                .foregroundColor(NexTheme.textSecondary.opacity(0.4))
            Text("Nenhum repo bate com o filtro atual")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(NexTheme.textSecondary)
            Button("Limpar filtros") {
                viewModel.searchQuery = ""
                viewModel.filter = .all
                viewModel.selectedTag = nil
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Bulk results

    private var bulkResultsBanner: some View {
        let succ = viewModel.bulkResults.filter { $0.success }.count
        let fail = viewModel.bulkResults.count - succ
        let action = viewModel.lastBulkAction?.rawValue ?? ""
        return HStack(spacing: 10) {
            Image(systemName: fail == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(fail == 0 ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(action): \(succ) ok / \(fail) erro")
                    .font(.system(size: 12, weight: .semibold))
                if fail > 0 {
                    Text(viewModel.bulkResults.filter { !$0.success }.prefix(2).map(\.message).joined(separator: " · "))
                        .font(.system(size: 10))
                        .foregroundColor(NexTheme.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Button {
                withAnimation { viewModel.bulkResults = [] }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(NexTheme.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassCard(cornerRadius: 8)
    }

    // MARK: - Add sheet

    private var addProjectSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Adicionar repositório")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button {
                    viewModel.isShowingAddSheet = false
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Caminho").font(.system(size: 10, weight: .semibold))
                HStack {
                    TextField("/Users/marcelo/dev/...", text: $viewModel.addPathInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    Button("Escolher…") { pickDirectoryAndAdd() }
                        .controlSize(.small)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Nome (opcional)").font(.system(size: 10, weight: .semibold))
                TextField("Padrão: nome da pasta", text: $viewModel.addNameInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Grupo (opcional)").font(.system(size: 10, weight: .semibold))
                TextField("Backend, Frontend, Mobile…", text: $viewModel.addGroupInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }

            HStack {
                Spacer()
                Button("Cancelar") {
                    viewModel.isShowingAddSheet = false
                }
                Button("Adicionar") {
                    viewModel.addCurrentInput()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.addPathInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 460)
    }

    // MARK: - Actions

    private func openInGitTab(_ project: WorkspaceProject) {
        appState.addGitTab(directory: project.path)
        dismiss()
    }

    private func openInFinder(_ project: WorkspaceProject) {
        NSWorkspace.shared.open(URL(fileURLWithPath: project.path))
    }

    private func pickDirectoryAndAdd() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Adicionar"
        if panel.runModal() == .OK {
            for url in panel.urls {
                viewModel.addPathFromDrop(url.path)
            }
            viewModel.isShowingAddSheet = false
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var didAdd = false
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    viewModel.addPathFromDrop(url.path)
                }
            }
            didAdd = true
        }
        return didAdd
    }
}

// MARK: - Row

private struct CockpitRow: View {
    let project: WorkspaceProject
    let snapshot: RepoSnapshot?
    let isInFlight: Bool
    let isSelected: Bool
    let onToggleSelect: () -> Void
    let onTogglePin: () -> Void
    let onOpen: () -> Void
    let onOpenInFinder: () -> Void
    let onRefresh: () -> Void
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            checkbox
            pinButton

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(project.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(NexTheme.textPrimary)
                    if !project.tags.isEmpty {
                        ForEach(project.tags.prefix(2), id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 9))
                                .foregroundColor(NexTheme.textSecondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(NexTheme.surface)
                                .cornerRadius(8)
                        }
                    }
                }
                Text(project.path)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(NexTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            branchCell
            aheadBehindCell
            dirtyCell
            lastCommitCell
            actionsCell
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { onOpen() }
        .contextMenu { contextMenu }
    }

    private var rowBackground: some View {
        ZStack {
            if isSelected {
                NexTheme.accentDim
            } else if isHovering {
                NexTheme.surfaceHover
            } else {
                Color.clear
            }
        }
    }

    private var checkbox: some View {
        Button(action: onToggleSelect) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13))
                .foregroundColor(isSelected ? NexTheme.accent : NexTheme.textSecondary.opacity(0.5))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isSelected ? "Remover da seleção" : "Selecionar para ações em lote")
    }

    private var pinButton: some View {
        Button(action: onTogglePin) {
            Image(systemName: project.isPinned ? "star.fill" : "star")
                .font(.system(size: 11))
                .foregroundColor(project.isPinned ? .yellow : NexTheme.textSecondary.opacity(0.4))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(project.isPinned ? "Desafixar" : "Fixar no topo")
    }

    @ViewBuilder
    private var branchCell: some View {
        if isInFlight && snapshot == nil {
            ProgressView().controlSize(.mini).frame(width: 140, alignment: .leading)
        } else if let snap = snapshot {
            switch snap.state {
            case .ok:
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9))
                        .foregroundColor(NexTheme.accent)
                    Text(snap.branch.isEmpty ? "(detached)" : snap.branch)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(NexTheme.textPrimary)
                        .lineLimit(1)
                }
                .frame(width: 140, alignment: .leading)
            case .notARepo:
                Text("não é repo")
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                    .frame(width: 140, alignment: .leading)
            case .error(let msg):
                Text(msg)
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                    .lineLimit(1)
                    .frame(width: 140, alignment: .leading)
                    .help(msg)
            }
        } else {
            Text("—")
                .font(.system(size: 11))
                .foregroundColor(NexTheme.textSecondary)
                .frame(width: 140, alignment: .leading)
        }
    }

    @ViewBuilder
    private var aheadBehindCell: some View {
        if let snap = snapshot, snap.state == .ok {
            if snap.hasUpstream, let ab = snap.aheadBehind {
                HStack(spacing: 4) {
                    if ab.behind > 0 {
                        Label("\(ab.behind)", systemImage: "arrow.down")
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(.orange)
                    }
                    if ab.ahead > 0 {
                        Label("\(ab.ahead)", systemImage: "arrow.up")
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(.green)
                    }
                    if ab.ahead == 0 && ab.behind == 0 {
                        Text("≡")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.green.opacity(0.7))
                    }
                }
                .frame(width: 70, alignment: .leading)
            } else {
                Text("sem upstream")
                    .font(.system(size: 9))
                    .foregroundColor(NexTheme.textSecondary)
                    .frame(width: 70, alignment: .leading)
            }
        } else {
            Text("—").font(.system(size: 11)).foregroundColor(NexTheme.textSecondary).frame(width: 70, alignment: .leading)
        }
    }

    @ViewBuilder
    private var dirtyCell: some View {
        if let snap = snapshot, snap.state == .ok {
            if snap.isDirty {
                HStack(spacing: 4) {
                    Circle().fill(.yellow).frame(width: 6, height: 6)
                    Text("\(snap.totalChanges)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.yellow)
                    Text("\(snap.stagedCount)S · \(snap.unstagedCount)U · \(snap.untrackedCount)?")
                        .font(.system(size: 9))
                        .foregroundColor(NexTheme.textSecondary)
                }
                .frame(width: 130, alignment: .leading)
                .help("Staged · Unstaged · Untracked")
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 10))
                        .foregroundColor(.green)
                    Text("limpo")
                        .font(.system(size: 11))
                        .foregroundColor(.green)
                }
                .frame(width: 130, alignment: .leading)
            }
        } else {
            Text("—").font(.system(size: 11)).foregroundColor(NexTheme.textSecondary).frame(width: 130, alignment: .leading)
        }
    }

    @ViewBuilder
    private var lastCommitCell: some View {
        if let snap = snapshot, snap.state == .ok, !snap.lastCommitSubject.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                Text(snap.lastCommitSubject)
                    .font(.system(size: 11))
                    .foregroundColor(NexTheme.textPrimary)
                    .lineLimit(1)
                Text("\(snap.lastCommitAuthor) · \(snap.lastCommitRelative)")
                    .font(.system(size: 9))
                    .foregroundColor(NexTheme.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: 220, alignment: .leading)
        } else {
            Text("—").font(.system(size: 11)).foregroundColor(NexTheme.textSecondary).frame(maxWidth: 220, alignment: .leading)
        }
    }

    private var actionsCell: some View {
        HStack(spacing: 2) {
            if isInFlight {
                ProgressView().controlSize(.mini)
            }
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
                    .foregroundColor(NexTheme.textSecondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Atualizar este repo")

            Button(action: onOpenInFinder) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundColor(NexTheme.textSecondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Abrir no Finder")
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Abrir aba Git") { onOpen() }
        Button("Abrir no Finder") { onOpenInFinder() }
        Divider()
        Button("Atualizar agora") { onRefresh() }
        Button(project.isPinned ? "Desafixar" : "Fixar no topo") { onTogglePin() }
        Divider()
        Button(role: .destructive) { onRemove() } label: {
            Text("Remover do Cockpit")
        }
    }
}
