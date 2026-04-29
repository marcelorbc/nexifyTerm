import SwiftUI

struct GitBranchSidebar: View {
    @ObservedObject var viewModel: GitViewModel
    @State private var isShowingNewBranch = false
    @State private var newBranchName = ""
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
        CollapsibleSection(title: "TAGS", id: "tags", expandedSections: $expandedSections) {
            if viewModel.tags.isEmpty {
                Text("Nenhuma tag")
                    .font(.system(size: 11))
                    .foregroundColor(NexTheme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
            } else {
                ForEach(viewModel.tags) { tag in
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
                        Task { await viewModel.checkoutTag(tag.name) }
                    }
                    .contextMenu {
                        Button("Checkout tag") {
                            Task { await viewModel.checkoutTag(tag.name) }
                        }
                        Button("Copiar nome") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(tag.name, forType: .string)
                        }
                    }
                }
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
                    HStack(spacing: 6) {
                        Image(systemName: "tray")
                            .font(.system(size: 10))
                            .foregroundColor(.purple)
                            .frame(width: 14)
                        Text(stash.message)
                            .font(.system(size: 11))
                            .foregroundColor(NexTheme.textPrimary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .contextMenu {
                        Button("Aplicar (Pop)") {
                            Task { await viewModel.stashPop(stash.id) }
                        }
                        Button("Remover (Drop)") {
                            Task { await viewModel.stashDrop(stash.id) }
                        }
                    }
                }
            }
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
    @ViewBuilder let content: () -> Content

    private var isExpanded: Bool {
        expandedSections.contains(id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
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
                .padding(.leading, 4)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                content()
            }
        }
    }
}
