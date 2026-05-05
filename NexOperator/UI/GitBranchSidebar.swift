import SwiftUI

struct GitBranchSidebar: View {
    @ObservedObject var viewModel: GitViewModel
    @State private var isShowingNewBranch = false
    @State private var newBranchName = ""
    @State private var isShowingNewTag = false
    @State private var newTagSourceName: String = ""
    @State private var isShowingPerf = false
    @State private var isShowingHygiene = false
    @State private var expandedStashIds: Set<Int> = []
    @State private var stashShowingDiff: Int? = nil
    @State private var expandedSections: Set<String> = ["local", "remote", "tags"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarHeader
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    localBranchesSection
                    Divider().padding(.vertical, 6)
                    remoteBranchesSection
                    Divider().padding(.vertical, 6)
                    tagsSection
                    Divider().padding(.vertical, 6)
                    stashesSection
                }
                .padding(8)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $isShowingPerf) {
            GitPerformanceView(viewModel: viewModel)
        }
        .sheet(isPresented: $isShowingHygiene) {
            GitBranchHygieneView(viewModel: viewModel)
        }
        .sheet(item: stashSheetBinding) { idx in
            GitStashDetailView(
                viewModel: viewModel,
                index: idx.value
            )
        }
    }

    // MARK: - Header

    private var sidebarHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11))
                .foregroundColor(.accentColor)
            Text("Git")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(NexTheme.textPrimary)
            Spacer()
            Button {
                isShowingHygiene = true
            } label: {
                Image(systemName: "scissors")
                    .font(.system(size: NexTheme.iconSizeSmall, weight: .medium))
                    .foregroundColor(NexTheme.textSecondary)
                    .frame(width: NexTheme.hitTargetSmall, height: NexTheme.hitTargetSmall)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Higiene de branches (mergeadas / stale)")
            Button {
                isShowingPerf = true
            } label: {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.system(size: NexTheme.iconSizeSmall, weight: .medium))
                    .foregroundColor(NexTheme.textSecondary)
                    .frame(width: NexTheme.hitTargetSmall, height: NexTheme.hitTargetSmall)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Diagnóstico de performance Git")
            Button {
                isShowingNewBranch = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: NexTheme.iconSizeSmall, weight: .bold))
                    .foregroundColor(NexTheme.textSecondary)
                    .frame(width: NexTheme.hitTargetSmall, height: NexTheme.hitTargetSmall)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Nova Branch")
            .popover(isPresented: $isShowingNewBranch) {
                newBranchPopover
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // Wraps the optional stash id in an `Identifiable` so we can drive
    // `.sheet(item:)` from the row's "Ver diff" button.
    private var stashSheetBinding: Binding<IdentifiedInt?> {
        Binding(
            get: { stashShowingDiff.map(IdentifiedInt.init(value:)) },
            set: { stashShowingDiff = $0?.value }
        )
    }

    // MARK: - Sections

    private var localBranchesSection: some View {
        CollapsibleSection(title: "BRANCHES", id: "local", expandedSections: $expandedSections) {
            ForEach(viewModel.localBranches) { branch in
                BranchRow(
                    name: branch.name,
                    isCurrent: branch.isCurrent,
                    icon: "arrow.triangle.branch"
                )
                .contextMenu { branchContextMenu(branch) }
                .onTapGesture {
                    if !branch.isCurrent {
                        Task { await viewModel.checkoutBranch(branch.name) }
                    }
                }
            }
        }
    }

    private var remoteBranchesSection: some View {
        CollapsibleSection(title: "REMOTES", id: "remote", expandedSections: $expandedSections) {
            ForEach(viewModel.remoteBranches) { branch in
                BranchRow(
                    name: branch.displayName,
                    isCurrent: false,
                    icon: "cloud"
                )
                .contextMenu {
                    Button {
                        Task { await viewModel.checkoutBranch(branch.name) }
                    } label: {
                        Label("Checkout", systemImage: "arrow.triangle.branch")
                    }

                    Divider()

                    Button {
                        Task { await viewModel.mergeBranch(branch.name) }
                    } label: {
                        Label("Merge \(branch.displayName) → \(viewModel.currentBranch)", systemImage: "arrow.triangle.merge")
                    }

                    Button {
                        Task { await viewModel.rebaseBranch(branch.name) }
                    } label: {
                        Label("Rebase \(viewModel.currentBranch) em \(branch.displayName)", systemImage: "arrow.triangle.swap")
                    }
                }
            }
        }
    }

    private var tagsSection: some View {
        CollapsibleSection(
            title: "TAGS",
            id: "tags",
            expandedSections: $expandedSections,
            trailing: AnyView(
                Button {
                    newTagSourceName = ""
                    isShowingNewTag = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(NexTheme.textSecondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Criar nova tag")
                .popover(isPresented: $isShowingNewTag) {
                    NewTagPopover(
                        viewModel: viewModel,
                        seedTag: newTagSourceName,
                        isPresented: $isShowingNewTag
                    )
                }
            )
        ) {
            if viewModel.tags.isEmpty {
                Text("Nenhuma tag")
                    .font(.system(size: 11))
                    .foregroundColor(NexTheme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
            } else {
                ForEach(viewModel.tags) { tag in
                    tagRow(tag)
                }
            }
        }
    }

    @ViewBuilder
    private func tagRow(_ tag: GitTag) -> some View {
        let suggestions = TagBumpSuggester.suggestions(from: tag.name)

        HStack(spacing: 6) {
            Image(systemName: "tag")
                .font(.system(size: 10))
                .foregroundColor(.orange)
                .frame(width: 14)
            Text(tag.name)
                .font(.system(size: 11))
                .foregroundColor(NexTheme.textPrimary)
                .lineLimit(1)
            Spacer()
            if !suggestions.isEmpty {
                // Tiny indicator that a bump is available.
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.orange.opacity(0.6))
            }
            if let msg = tag.message, !msg.isEmpty {
                Text(msg)
                    .font(.system(size: 9))
                    .foregroundColor(NexTheme.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .cursorOnHover(.pointingHand)
        .onTapGesture {
            // Click → open the "create next" popover seeded with this tag,
            // matching the behavior the user described in the task.
            newTagSourceName = tag.name
            isShowingNewTag = true
        }
        .contextMenu {
            Button("Checkout tag") {
                Task { await viewModel.checkoutTag(tag.name) }
            }
            Divider()
            if suggestions.isEmpty {
                Button("Criar nova tag a partir desta…") {
                    newTagSourceName = tag.name
                    isShowingNewTag = true
                }
            } else {
                Section("Criar próxima tag") {
                    ForEach(suggestions) { s in
                        Button {
                            Task { await viewModel.createTag(name: s.name) }
                        } label: {
                            Text("\(s.label) → \(s.name)")
                        }
                    }
                    Divider()
                    Button("Personalizar nome…") {
                        newTagSourceName = tag.name
                        isShowingNewTag = true
                    }
                }
            }
            Divider()
            Button("Copiar nome") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tag.name, forType: .string)
            }
        }
    }

    private var stashesSection: some View {
        CollapsibleSection(title: "STASHES", id: "stashes", expandedSections: $expandedSections) {
            if viewModel.stashes.isEmpty {
                Text("Nenhum stash")
                    .font(.system(size: 11))
                    .foregroundColor(NexTheme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
            } else {
                ForEach(viewModel.stashes) { stash in
                    stashRow(stash)
                }
            }
        }
    }

    @ViewBuilder
    private func stashRow(_ stash: GitStash) -> some View {
        let isExpanded = expandedStashIds.contains(stash.id)
        let details = viewModel.stashDetailsCache[stash.id]
        let isLoading = viewModel.loadingStashDetails.contains(stash.id)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    toggleStash(stash.id)
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(NexTheme.textSecondary)
                        .frame(width: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Image(systemName: "tray")
                    .font(.system(size: 10))
                    .foregroundColor(.purple)
                    .frame(width: 14)

                Text(stash.message)
                    .font(.system(size: 11))
                    .foregroundColor(NexTheme.textPrimary)
                    .lineLimit(1)

                Spacer()

                if let count = details?.files.count {
                    Text("\(count)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(NexTheme.textSecondary)
                        .padding(.horizontal, 4)
                        .background(NexTheme.surface)
                        .cornerRadius(3)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onTapGesture { toggleStash(stash.id) }
            .contextMenu {
                Button("Ver diff completo…") { stashShowingDiff = stash.id }
                Divider()
                Button("Aplicar (Pop)") {
                    Task { await viewModel.stashPop(stash.id) }
                }
                Button("Remover (Drop)") {
                    Task { await viewModel.stashDrop(stash.id) }
                }
            }

            if isExpanded {
                stashExpandedContent(stash: stash, details: details, isLoading: isLoading)
            }
        }
    }

    @ViewBuilder
    private func stashExpandedContent(stash: GitStash, details: GitStashDetails?, isLoading: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if isLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Carregando arquivos…")
                        .font(.system(size: 10))
                        .foregroundColor(NexTheme.textSecondary)
                }
                .padding(.leading, 32)
                .padding(.vertical, 3)
            } else if let details {
                if details.files.isEmpty {
                    Text("Sem arquivos detectados")
                        .font(.system(size: 10))
                        .foregroundColor(NexTheme.textSecondary)
                        .padding(.leading, 32)
                        .padding(.vertical, 3)
                } else {
                    ForEach(details.files) { f in
                        HStack(spacing: 4) {
                            Image(systemName: f.status.icon)
                                .font(.system(size: 8))
                                .foregroundColor(f.status.color)
                                .frame(width: 10)
                            Text(f.path)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(NexTheme.textPrimary.opacity(0.85))
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        .padding(.leading, 32)
                        .padding(.vertical, 1)
                    }
                }
                Button {
                    stashShowingDiff = stash.id
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 9))
                        Text("Ver diff completo")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 24)
                .padding(.top, 2)
            }
        }
        .padding(.bottom, 4)
    }

    private func toggleStash(_ id: Int) {
        if expandedStashIds.contains(id) {
            expandedStashIds.remove(id)
        } else {
            expandedStashIds.insert(id)
            // Lazy load on first expand.
            Task { await viewModel.loadStashDetails(id) }
        }
    }

    // MARK: - Context Menus

    @ViewBuilder
    private func branchContextMenu(_ branch: GitBranch) -> some View {
        if !branch.isCurrent {
            Button {
                Task { await viewModel.checkoutBranch(branch.name) }
            } label: {
                Label("Checkout", systemImage: "arrow.triangle.branch")
            }

            Divider()

            Button {
                Task { await viewModel.mergeBranch(branch.name) }
            } label: {
                Label("Merge \(branch.name) → \(viewModel.currentBranch)", systemImage: "arrow.triangle.merge")
            }

            Button {
                Task { await viewModel.rebaseBranch(branch.name) }
            } label: {
                Label("Rebase \(viewModel.currentBranch) em \(branch.name)", systemImage: "arrow.triangle.swap")
            }

            Divider()

            Button(role: .destructive) {
                Task { await viewModel.deleteBranch(branch.name) }
            } label: {
                Label("Deletar Branch", systemImage: "trash")
            }

            Button(role: .destructive) {
                Task { await viewModel.deleteBranch(branch.name, force: true) }
            } label: {
                Label("Forçar Delete (⚠️)", systemImage: "trash.fill")
            }
        } else {
            Label("Branch atual", systemImage: "checkmark.circle.fill")
                .foregroundColor(NexTheme.accent)
        }
    }

    // MARK: - New Branch Popover

    private var newBranchPopover: some View {
        VStack(spacing: 8) {
            Text("Nova Branch")
                .font(.system(size: 12, weight: .semibold))
            TextField("Nome da branch", text: $newBranchName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(width: 200)
                .onSubmit { createBranch() }
            HStack {
                Button("Cancelar") {
                    isShowingNewBranch = false
                    newBranchName = ""
                }
                .buttonStyle(.plain)
                Button("Criar") { createBranch() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(newBranchName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
    }

    private func createBranch() {
        let name = newBranchName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        Task { await viewModel.createBranch(name) }
        isShowingNewBranch = false
        newBranchName = ""
    }
}

// MARK: - Reusable Components

struct BranchRow: View {
    let name: String
    let isCurrent: Bool
    let icon: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(isCurrent ? NexTheme.accent : NexTheme.textSecondary)
                .frame(width: 14)
            Text(name)
                .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                .foregroundColor(isCurrent ? NexTheme.accent : NexTheme.textPrimary)
                .lineLimit(1)
            Spacer()
            if isCurrent {
                Circle()
                    .fill(NexTheme.accent)
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(isCurrent ? NexTheme.accentDim : Color.clear)
        .cornerRadius(4)
        .cursorOnHover(.pointingHand)
    }
}

struct CollapsibleSection<Content: View>: View {
    let title: String
    let id: String
    @Binding var expandedSections: Set<String>
    var trailing: AnyView? = nil
    @ViewBuilder let content: () -> Content

    private var isExpanded: Bool {
        expandedSections.contains(id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if isExpanded {
                            expandedSections.remove(id)
                        } else {
                            expandedSections.insert(id)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(NexTheme.textSecondary)
                            .frame(width: 12)
                        Text(title)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(NexTheme.textSecondary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if let trailing { trailing }
            }
            .padding(.leading, 4)
            .padding(.vertical, 2)

            if isExpanded {
                content()
            }
        }
    }
}

// Tiny wrapper so we can drive `.sheet(item:)` from a stash index without
// having to pollute the model with Identifiable conformance.
struct IdentifiedInt: Identifiable, Equatable {
    let value: Int
    var id: Int { value }
}

// MARK: - New Tag Popover

/// Popover used both by the section "+" button (free-form name) and by
/// clicking on an existing tag row (seeded with the source tag and showing
/// quick-bump buttons).
struct NewTagPopover: View {
    @ObservedObject var viewModel: GitViewModel
    let seedTag: String
    @Binding var isPresented: Bool

    @State private var name: String = ""
    @State private var message: String = ""
    @FocusState private var nameFocused: Bool

    private var suggestions: [TagBumpSuggester.Suggestion] {
        guard !seedTag.isEmpty else { return [] }
        return TagBumpSuggester.suggestions(from: seedTag)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "tag.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                Text(seedTag.isEmpty ? "Nova tag" : "Próxima tag a partir de \(seedTag)")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }

            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sugestões")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(NexTheme.textSecondary)
                    ForEach(suggestions) { s in
                        Button {
                            name = s.name
                        } label: {
                            HStack(spacing: 6) {
                                Text(s.label)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.orange)
                                    .frame(width: 50, alignment: .leading)
                                Text(s.name)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(NexTheme.textPrimary)
                                Spacer()
                                Text(s.hint)
                                    .font(.system(size: 9))
                                    .foregroundColor(NexTheme.textSecondary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(name == s.name ? NexTheme.accentDim : Color.clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Nome")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(NexTheme.textSecondary)
                TextField("v1.2.3", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($nameFocused)
                    .onSubmit { commit() }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Mensagem (opcional, cria tag anotada)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(NexTheme.textSecondary)
                TextField("Release notes…", text: $message)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
            }

            HStack {
                Spacer()
                Button("Cancelar") { isPresented = false }
                    .buttonStyle(.plain)
                Button("Criar") { commit() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 360)
        .onAppear {
            if !suggestions.isEmpty, let first = suggestions.first {
                name = first.name
            }
            nameFocused = true
        }
    }

    private func commit() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        let m = message.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await viewModel.createTag(name: n, message: m.isEmpty ? nil : m) }
        isPresented = false
    }
}
