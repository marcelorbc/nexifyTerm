import SwiftUI

enum BottomPanelMode: String, CaseIterable {
    case staging = "Staging"
    case commitDetail = "Commit"
}

struct GitTabView: View {
    @ObservedObject var viewModel: GitViewModel
    @EnvironmentObject var appState: AppState
    @State private var sidebarWidth: CGFloat = 200
    @State private var bottomRatio: CGFloat = 0.38
    @State private var showTerminal = true
    @State private var terminalRatio: CGFloat = 0.25
    @State private var isShowingRemoteExplorer = false
    @State private var bottomPanelMode: BottomPanelMode = .staging

    private let minSidebarWidth: CGFloat = 160
    private let maxSidebarWidth: CGFloat = 320

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.commits.isEmpty {
                loadingView
            } else if !viewModel.isGitRepo {
                notARepoView
            } else {
                mainContent
            }
        }
        .onAppear { viewModel.onAppear() }
        .onDisappear { viewModel.onDisappear() }
        .onChange(of: viewModel.selectedCommitId) { newValue in
            if newValue != nil {
                withAnimation(.easeInOut(duration: 0.15)) {
                    bottomPanelMode = .commitDetail
                }
            }
        }
    }

    // MARK: - Main Layout

    private var mainContent: some View {
        HStack(spacing: 0) {
            GitBranchSidebar(viewModel: viewModel)
                .frame(width: sidebarWidth)

            sidebarResizeHandle

            VStack(spacing: 0) {
                gitToolbar
                Divider()

                GeometryReader { geo in
                    let totalHeight = geo.size.height
                    let mainHeight = showTerminal
                        ? totalHeight * (1 - terminalRatio)
                        : totalHeight
                    let termHeight = showTerminal
                        ? totalHeight * terminalRatio - NexTheme.dragHandleThickness
                        : 0
                    let graphHeight = mainHeight * (1 - bottomRatio)
                    let bottomHeight = mainHeight * bottomRatio - NexTheme.dragHandleThickness

                    VStack(spacing: 0) {
                        GitCommitGraphView(viewModel: viewModel)
                            .frame(height: graphHeight)

                        bottomDragHandle(totalHeight: mainHeight)

                        bottomPanel
                            .frame(height: bottomHeight)

                        if showTerminal {
                            terminalDragHandle(totalHeight: totalHeight)
                            gitTerminalPanel
                                .frame(height: max(termHeight, 60))
                        }
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = viewModel.toastMessage {
                GitToastView(message: toast, isError: viewModel.toastIsError)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, showTerminal ? 16 : 16)
                    .onTapGesture { viewModel.toastMessage = nil }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.toastMessage)
        .animation(.easeInOut(duration: 0.2), value: showTerminal)
        .sheet(isPresented: $isShowingRemoteExplorer) {
            RemoteExplorerView()
        }
        .alert("Erro Git", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    // MARK: - Bottom Panel (context-sensitive)

    private var bottomPanel: some View {
        VStack(spacing: 0) {
            bottomPanelTabs
            Divider()

            switch bottomPanelMode {
            case .staging:
                GitStagingView(viewModel: viewModel)
            case .commitDetail:
                GitCommitDetailView(viewModel: viewModel) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        bottomPanelMode = .staging
                        viewModel.selectedCommitId = nil
                    }
                }
            }
        }
        .background(NexTheme.bg)
    }

    private var bottomPanelTabs: some View {
        HStack(spacing: 0) {
            ForEach(BottomPanelMode.allCases, id: \.self) { mode in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        bottomPanelMode = mode
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: mode == .staging ? "checklist" : "doc.text.magnifyingglass")
                            .font(.system(size: 10))
                        Text(mode.rawValue)
                            .font(.system(size: 11, weight: bottomPanelMode == mode ? .semibold : .regular))

                        if mode == .staging {
                            let count = viewModel.stagedFiles.count + viewModel.unstagedFiles.count
                            if count > 0 {
                                Text("\(count)")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(NexTheme.accent))
                            }
                        }

                        if mode == .commitDetail, let detail = viewModel.commitDetail {
                            Text(detail.shortHash)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(NexTheme.textSecondary)
                        }
                    }
                    .foregroundColor(bottomPanelMode == mode ? NexTheme.accent : NexTheme.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        bottomPanelMode == mode
                            ? NexTheme.accentDim
                            : Color.clear
                    )
                    .overlay(alignment: .bottom) {
                        if bottomPanelMode == mode {
                            Rectangle()
                                .fill(NexTheme.accent)
                                .frame(height: 2)
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            Spacer()

            toolbarButton(icon: "arrow.clockwise", label: "Refresh") {
                Task { await viewModel.refreshAll() }
            }

            toolbarButton(
                icon: showTerminal ? "terminal.fill" : "terminal",
                label: "Terminal"
            ) {
                withAnimation { showTerminal.toggle() }
            }
        }
        .background(NexTheme.surface)
    }

    // MARK: - Toolbar

    private var gitToolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: NexTheme.iconSizeSmall))
                    .foregroundColor(NexTheme.accent)
                Text(viewModel.currentBranch)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(NexTheme.textPrimary)
            }

            Spacer()

            HStack(spacing: 4) {
                toolbarButton(icon: "arrow.down.circle", label: "Pull") {
                    Task { await viewModel.pull() }
                }
                toolbarButton(icon: "arrow.up.circle", label: "Push") {
                    Task { await viewModel.push() }
                }
                mergeRebaseMenu
            }

            Spacer()

            toolbarButton(icon: "globe", label: "Explorar Repos") {
                isShowingRemoteExplorer = true
            }

            Divider().frame(height: 16)

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: NexTheme.iconSizeSmall))
                    .foregroundColor(NexTheme.textSecondary)
                TextField("Buscar commits...", text: $viewModel.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(maxWidth: 180)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(NexTheme.surface)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(NexTheme.border, lineWidth: 0.5)
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(NexTheme.surface)
    }

    private var mergeRebaseMenu: some View {
        Menu {
            Section("Merge → \(viewModel.currentBranch)") {
                ForEach(viewModel.localBranches.filter { !$0.isCurrent }) { branch in
                    Button {
                        Task { await viewModel.mergeBranch(branch.name) }
                    } label: {
                        Label(branch.name, systemImage: "arrow.triangle.merge")
                    }
                }
                ForEach(viewModel.remoteBranches) { branch in
                    Button {
                        Task { await viewModel.mergeBranch(branch.name) }
                    } label: {
                        Label(branch.name, systemImage: "cloud")
                    }
                }
            }

            Divider()

            Section("Rebase \(viewModel.currentBranch) em") {
                ForEach(viewModel.localBranches.filter { !$0.isCurrent }) { branch in
                    Button {
                        Task { await viewModel.rebaseBranch(branch.name) }
                    } label: {
                        Label(branch.name, systemImage: "arrow.triangle.swap")
                    }
                }
                ForEach(viewModel.remoteBranches) { branch in
                    Button {
                        Task { await viewModel.rebaseBranch(branch.name) }
                    } label: {
                        Label(branch.name, systemImage: "cloud")
                    }
                }
            }

            Divider()

            Button(role: .destructive) {
                Task { await viewModel.rebaseAbort() }
            } label: {
                Label("Abortar Rebase", systemImage: "xmark.octagon")
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.merge")
                    .font(.system(size: NexTheme.iconSizeSmall))
                Text("Merge / Rebase")
                    .font(.system(size: 11))
            }
            .foregroundColor(NexTheme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(NexTheme.surfaceHover)
            .cornerRadius(5)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Merge ou Rebase de branches")
    }

    private func toolbarButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: NexTheme.iconSizeSmall))
                Text(label)
                    .font(.system(size: 11))
            }
            .foregroundColor(NexTheme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(NexTheme.surfaceHover)
            .cornerRadius(5)
        }
        .buttonStyle(.plain)
        .cursorOnHover(.pointingHand)
        .help(label)
    }

    // MARK: - Resize Handles

    private var sidebarResizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: NexTheme.dragHandleThickness)
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

    private func bottomDragHandle(totalHeight: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: NexTheme.dragHandleThickness)
            .overlay(
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(NexTheme.textSecondary.opacity(0.3))
                    .frame(width: 40, height: 3)
            )
            .background(NexTheme.border.opacity(0.5))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let newRatio = bottomRatio - (value.translation.height / totalHeight)
                        bottomRatio = min(0.7, max(0.15, newRatio))
                    }
            )
            .cursorOnHover(.resizeUpDown)
    }

    // MARK: - Embedded Terminal

    private var gitTerminalPanel: some View {
        VStack(spacing: 0) {
            gitTerminalHeader
            Divider()
            if let tabId = appState.activeTabId {
                let session = appState.sessionManager.session(
                    for: tabId,
                    initialDirectory: viewModel.repoPath
                )
                SwiftTermViewRepresentable(session: session)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var gitTerminalHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 10))
                .foregroundColor(NexTheme.accent)
            Text("Terminal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(NexTheme.textPrimary)

            Text(viewModel.repoPath.components(separatedBy: "/").suffix(2).joined(separator: "/"))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(NexTheme.textSecondary)
                .lineLimit(1)

            Spacer()

            Button {
                withAnimation { showTerminal = false }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(NexTheme.textSecondary)
                    .frame(width: NexTheme.hitTargetSmall, height: NexTheme.hitTargetSmall)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Fechar terminal")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(NexTheme.surface.opacity(0.8))
    }

    private func terminalDragHandle(totalHeight: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: NexTheme.dragHandleThickness)
            .overlay(
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(NexTheme.textSecondary.opacity(0.3))
                    .frame(width: 40, height: 3)
            )
            .background(NexTheme.border.opacity(0.5))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let newRatio = terminalRatio - (value.translation.height / totalHeight)
                        terminalRatio = min(0.7, max(0.1, newRatio))
                    }
            )
            .cursorOnHover(.resizeUpDown)
    }

    // MARK: - Placeholder Views

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Carregando repositório...")
                .font(.system(size: 14))
                .foregroundColor(NexTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var notARepoView: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 40))
                .foregroundColor(NexTheme.textSecondary.opacity(0.5))
            Text("Diretório não é um repositório Git")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(NexTheme.textSecondary)
            Text(viewModel.repoPath)
                .font(.system(size: 11))
                .foregroundColor(NexTheme.textSecondary.opacity(0.7))
            Button("Inicializar git init") {
                // TODO: Phase 4 - git init support
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Toast Component

struct GitToastView: View {
    let message: String
    let isError: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(isError ? .red : .green)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(NexTheme.textPrimary)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(NexTheme.surface)
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isError ? Color.red.opacity(0.3) : Color.green.opacity(0.3), lineWidth: 1)
        )
    }
}
