import SwiftUI

struct RemoteExplorerView: View {
    @StateObject private var viewModel: RemoteExplorerViewModel
    @ObservedObject private var techDetector = RepoTechDetector.shared
    @Environment(\.dismiss) private var dismiss
    @State private var sidebarWidth: CGFloat = 220

    init(defaultClonePath: String? = nil) {
        _viewModel = StateObject(wrappedValue: {
            let vm = RemoteExplorerViewModel()
            vm.defaultClonePath = defaultClonePath
            return vm
        }())
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if viewModel.accounts.isEmpty {
                emptyAccountsView
            } else {
                mainContent
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(NexTheme.bg)
        .sheet(isPresented: $viewModel.isShowingAddAccount) {
            AddAccountSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isShowingDetail) {
            if let repo = viewModel.selectedRepo {
                RemoteRepoDetailView(viewModel: viewModel, repo: repo)
            }
        }
        .sheet(isPresented: $viewModel.isShowingCloneSheet) {
            RemoteCloneSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isShowingQuickSetup) {
            QuickSetupWizard(viewModel: viewModel)
        }
        .overlay(alignment: .bottom) {
            if let toast = viewModel.toastMessage {
                GitToastView(
                    message: toast,
                    isError: viewModel.toastIsError,
                    onDismiss: viewModel.toastIsError ? { viewModel.dismissToast() } : nil
                )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 16)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.toastMessage)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "globe")
                .font(.system(size: 16))
                .foregroundColor(NexTheme.accent)
            Text("Explorar Repositórios")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(NexTheme.textPrimary)

            Spacer()

            if !viewModel.selectedForClone.isEmpty {
                Button {
                    viewModel.prepareClone()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 12))
                        Text("Clonar \(viewModel.selectedForClone.count) selecionados")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(NexTheme.accent)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }

            Button {
                viewModel.isShowingQuickSetup = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 11))
                    Text("Setup Rápido")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(NexTheme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(NexTheme.accent.opacity(0.1))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(NexTheme.accent.opacity(0.3), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .help("Cole uma URL de repositório e configure tudo")

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(NexTheme.textSecondary)
                    .frame(width: NexTheme.hitTargetSmall, height: NexTheme.hitTargetSmall)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Fechar")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(NexTheme.surface)
    }

    // MARK: - Main Content

    private var mainContent: some View {
        HStack(spacing: 0) {
            accountsSidebar
                .frame(width: sidebarWidth)

            Divider()

            repositoryList
        }
    }

    // MARK: - Accounts Sidebar

    private var accountsSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("CONTAS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(NexTheme.textSecondary)
                Spacer()
                Button {
                    viewModel.isShowingAddAccount = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: NexTheme.iconSizeSmall, weight: .bold))
                        .foregroundColor(NexTheme.textSecondary)
                        .frame(width: NexTheme.hitTargetSmall, height: NexTheme.hitTargetSmall)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Adicionar Conta")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(viewModel.accounts) { account in
                        AccountRow(
                            account: account,
                            isSelected: viewModel.selectedAccount?.id == account.id,
                            onSelect: { viewModel.selectAccount(account) },
                            onRemove: { viewModel.removeAccount(account) }
                        )
                    }
                }
                .padding(8)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Repository List

    private var repositoryList: some View {
        VStack(spacing: 0) {
            repoToolbar
            Divider()

            if viewModel.isLoading && viewModel.repositories.isEmpty {
                loadingView
            } else if let error = viewModel.errorMessage {
                errorView(error)
            } else if viewModel.filteredRepositories.isEmpty {
                emptyReposView
            } else {
                repoScrollView
            }
        }
    }

    private var repoToolbar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: NexTheme.iconSizeSmall))
                        .foregroundColor(NexTheme.textSecondary)
                    TextField("Buscar por nome, descrição, tech…", text: $viewModel.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .onSubmit {
                            Task { await viewModel.searchRepositories() }
                        }
                    if !viewModel.searchQuery.isEmpty {
                        Button { viewModel.searchQuery = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(NexTheme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(NexTheme.surface)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(NexTheme.border, lineWidth: 0.5)
                )

                sortMenu

                Spacer()

                counterArea

                Button {
                    if viewModel.selectedForClone.count == viewModel.filteredRepositories.count {
                        viewModel.deselectAllForClone()
                    } else {
                        viewModel.selectAllForClone()
                    }
                } label: {
                    Text(viewModel.selectedForClone.count == viewModel.filteredRepositories.count ? "Deselecionar" : "Selecionar Todos")
                        .font(.system(size: 11))
                        .foregroundColor(NexTheme.accent)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.filteredRepositories.isEmpty)

                Button {
                    Task { await viewModel.loadRepositories() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: NexTheme.iconSizeSmall))
                        .foregroundColor(NexTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Recarregar tudo")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            techChipsRow
        }
        .background(NexTheme.surface.opacity(0.5))
    }

    private var sortMenu: some View {
        Menu {
            ForEach(RemoteExplorerViewModel.RepoSortOption.allCases) { opt in
                Button {
                    viewModel.sortOption = opt
                    viewModel.applyFilters()
                } label: {
                    HStack {
                        Text(opt.rawValue)
                        if viewModel.sortOption == opt {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 10))
                Text(viewModel.sortOption.rawValue)
                    .font(.system(size: 11))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundColor(NexTheme.textSecondary)
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

    private var counterArea: some View {
        HStack(spacing: 6) {
            if viewModel.filteredRepositories.count == viewModel.repositories.count {
                Text("\(viewModel.repositories.count) repos")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(NexTheme.textSecondary)
            } else {
                Text("\(viewModel.filteredRepositories.count) de \(viewModel.repositories.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(NexTheme.accent)
            }
            if viewModel.isDetectingTechs {
                HStack(spacing: 3) {
                    ProgressView().controlSize(.mini)
                    Text("Detectando tech…")
                        .font(.system(size: 9))
                        .foregroundColor(NexTheme.textSecondary)
                }
            }
        }
    }

    @ViewBuilder
    private var techChipsRow: some View {
        let availableTechs = viewModel.availableTechs
        let hasFilter = !viewModel.selectedTechFilters.isEmpty
        if !availableTechs.isEmpty || hasFilter {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    techChip(label: "Todas", isSelected: !hasFilter, color: NexTheme.accent) {
                        viewModel.clearTechFilters()
                    }
                    Divider().frame(height: 18)
                    ForEach(availableTechs) { tech in
                        techChip(
                            label: tech.label,
                            isSelected: viewModel.selectedTechFilters.contains(tech),
                            color: tech.color
                        ) {
                            viewModel.toggleTechFilter(tech)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
    }

    private func techChip(label: String, isSelected: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(label)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
            }
            .foregroundColor(isSelected ? .white : NexTheme.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(isSelected ? color : NexTheme.surface)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? color : NexTheme.border, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var repoScrollView: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(viewModel.filteredRepositories) { repo in
                    RemoteRepoRow(
                        repo: repo,
                        isSelected: viewModel.selectedForClone.contains(repo.id),
                        onToggleSelect: { viewModel.toggleCloneSelection(repo.id) },
                        onOpen: { viewModel.openRepoDetail(repo) },
                        onClone: {
                            viewModel.selectedForClone = [repo.id]
                            viewModel.prepareClone()
                        }
                    )
                    .environmentObject(techDetector)
                }
            }
            .padding(8)
        }
        // Re-aplica filtro quando o detector terminar de classificar repos
        // — assim os chips de tech aparecem na barra e a busca passa a
        // matchear "react"/"python"/etc.
        .onReceive(techDetector.$techsByRepo) { _ in
            viewModel.applyFilters()
        }
    }

    // MARK: - Empty / Loading / Error

    private var emptyAccountsView: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer().frame(height: 40)

                Image(systemName: "person.badge.plus")
                    .font(.system(size: 40))
                    .foregroundColor(NexTheme.textSecondary.opacity(0.5))
                Text("Nenhuma conta configurada")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(NexTheme.textSecondary)
                Text("Adicione uma conta GitHub ou Azure DevOps para explorar repositórios")
                    .font(.system(size: 12))
                    .foregroundColor(NexTheme.textSecondary.opacity(0.7))
                    .multilineTextAlignment(.center)

                Button {
                    viewModel.isShowingQuickSetup = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 14))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Setup Rápido")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Cole uma URL e configure tudo automaticamente")
                                .font(.system(size: 10))
                                .opacity(0.8)
                        }
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: 360)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        LinearGradient(
                            colors: [NexTheme.accent, NexTheme.accent.opacity(0.8)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)

                HStack(spacing: 10) {
                    Button {
                        viewModel.isShowingAddAccount = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle.fill")
                            Text("Adicionar Conta")
                        }
                        .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)

                    Button {
                        Task { await viewModel.scanLocalGitConfigs() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                            Text("Detectar Contas")
                        }
                        .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isScanning)
                }

                if viewModel.isScanning {
                    VStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Buscando configurações Git na máquina...")
                            .font(.system(size: 11))
                            .foregroundColor(NexTheme.textSecondary)
                    }
                    .padding(.top, 8)
                }

                if !viewModel.detectedAccounts.isEmpty {
                    detectedAccountsSection
                } else if viewModel.hasScanned && !viewModel.isScanning {
                    VStack(spacing: 8) {
                        Image(systemName: "questionmark.folder")
                            .font(.system(size: 24))
                            .foregroundColor(NexTheme.textSecondary.opacity(0.4))
                        Text("Nenhuma configuração Git detectada")
                            .font(.system(size: 12))
                            .foregroundColor(NexTheme.textSecondary.opacity(0.7))
                        Text("Configure manualmente usando o botão acima")
                            .font(.system(size: 10))
                            .foregroundColor(NexTheme.textSecondary.opacity(0.5))
                    }
                    .padding(.top, 8)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 40)
        }
    }

    private var detectedAccountsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkle")
                    .font(.system(size: 12))
                    .foregroundColor(.yellow)
                Text("Contas detectadas na máquina")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(NexTheme.textPrimary)
                Spacer()
                Text("\(viewModel.detectedAccounts.count) encontrada(s)")
                    .font(.system(size: 10))
                    .foregroundColor(NexTheme.textSecondary)
            }
            .padding(.horizontal, 4)

            ForEach(viewModel.detectedAccounts) { detected in
                DetectedAccountRow(detected: detected) {
                    Task { await viewModel.importDetectedAccount(detected) }
                } onManualSetup: {
                    viewModel.prefillFromDetected(detected)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(NexTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(NexTheme.border.opacity(0.5), lineWidth: 0.5)
                )
        )
        .frame(maxWidth: 500)
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Carregando repositórios...")
                .font(.system(size: 12))
                .foregroundColor(NexTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundColor(.orange)
            Text(error)
                .font(.system(size: 12))
                .foregroundColor(NexTheme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Tentar Novamente") {
                Task { await viewModel.loadRepositories() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyReposView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 32))
                .foregroundColor(NexTheme.textSecondary.opacity(0.5))
            Text(viewModel.searchQuery.isEmpty ? "Nenhum repositório encontrado" : "Nenhum resultado para \"\(viewModel.searchQuery)\"")
                .font(.system(size: 13))
                .foregroundColor(NexTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Account Row

struct AccountRow: View {
    let account: RemoteAccount
    let isSelected: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: account.provider.icon)
                .font(.system(size: 12))
                .foregroundColor(account.provider.color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(account.displayName)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? NexTheme.accent : NexTheme.textPrimary)
                    .lineLimit(1)
                Text(account.username)
                    .font(.system(size: 9))
                    .foregroundColor(NexTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            if isSelected {
                Circle()
                    .fill(NexTheme.accent)
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? NexTheme.accentDim : Color.clear)
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .contextMenu {
            Button(role: .destructive) {
                onRemove()
            } label: {
                Label("Remover Conta", systemImage: "trash")
            }
        }
    }
}

// MARK: - Repository Row

struct RemoteRepoRow: View {
    let repo: RemoteRepository
    let isSelected: Bool
    let onToggleSelect: () -> Void
    let onOpen: () -> Void
    let onClone: () -> Void

    @EnvironmentObject var techDetector: RepoTechDetector

    private let dateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "pt-BR")
        return f
    }()

    /// Up to 3 most relevant techs (frameworks first, then languages).
    private var displayTechs: [RepoTech] {
        let detected = techDetector.techs(for: repo) ?? []
        guard !detected.isEmpty else { return [] }
        // Priorize frameworks/UI sobre runtime — assim "Next.js" aparece
        // antes de "TypeScript" ou "Node.js".
        let priority: [RepoTech.Category] = [.frontend, .mobile, .backend, .infra, .other]
        let sorted = detected.sorted { lhs, rhs in
            let lp = priority.firstIndex(of: lhs.category) ?? 99
            let rp = priority.firstIndex(of: rhs.category) ?? 99
            if lp != rp { return lp < rp }
            return lhs.label < rhs.label
        }
        return Array(sorted.prefix(3))
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                onToggleSelect()
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundColor(isSelected ? NexTheme.accent : NexTheme.textSecondary.opacity(0.5))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(repo.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(NexTheme.textPrimary)
                        .lineLimit(1)

                    if repo.isPrivate {
                        Text("privado")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.1))
                            .cornerRadius(3)
                    }

                    // Tech badges — filled chips com cor da linguagem.
                    ForEach(displayTechs) { tech in
                        HStack(spacing: 3) {
                            Circle().fill(tech.color).frame(width: 5, height: 5)
                            Text(tech.label)
                                .font(.system(size: 9, weight: .medium))
                        }
                        .foregroundColor(tech.color)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(tech.color.opacity(0.12))
                        .cornerRadius(3)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(tech.color.opacity(0.35), lineWidth: 0.5))
                    }

                    // Pequeno spinner enquanto a detecção roda
                    if techDetector.isDetecting(repo) {
                        ProgressView().controlSize(.mini)
                    }
                }

                if let desc = repo.description, !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: 10))
                        .foregroundColor(NexTheme.textSecondary)
                        .lineLimit(1)
                }

                HStack(spacing: 10) {
                    if let lang = repo.language {
                        HStack(spacing: 3) {
                            Circle()
                                .fill(repo.languageColor)
                                .frame(width: 7, height: 7)
                            Text(lang)
                                .font(.system(size: 9))
                                .foregroundColor(NexTheme.textSecondary)
                        }
                    }

                    if repo.stars > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "star")
                                .font(.system(size: 8))
                            Text("\(repo.stars)")
                                .font(.system(size: 9))
                        }
                        .foregroundColor(NexTheme.textSecondary)
                    }

                    if repo.forks > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "tuningfork")
                                .font(.system(size: 8))
                            Text("\(repo.forks)")
                                .font(.system(size: 9))
                        }
                        .foregroundColor(NexTheme.textSecondary)
                    }

                    Text(dateFormatter.localizedString(for: repo.updatedAt, relativeTo: Date()))
                        .font(.system(size: 9))
                        .foregroundColor(NexTheme.textSecondary)
                }
            }

            Spacer()

            HStack(spacing: 6) {
                Button {
                    onOpen()
                } label: {
                    Image(systemName: "eye")
                        .font(.system(size: 11))
                        .foregroundColor(NexTheme.textSecondary)
                        .frame(width: 26, height: 26)
                        .background(NexTheme.surfaceHover)
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .help("Explorar")

                Button {
                    onClone()
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 11))
                        .foregroundColor(NexTheme.textSecondary)
                        .frame(width: 26, height: 26)
                        .background(NexTheme.surfaceHover)
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .help("Clonar")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? NexTheme.accentDim : NexTheme.surface.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(NexTheme.border.opacity(0.3), lineWidth: 0.5)
        )
    }
}

// MARK: - Add Account Sheet

struct AddAccountSheet: View {
    @ObservedObject var viewModel: RemoteExplorerViewModel
    @Environment(\.dismiss) private var dismiss

    private var relevantDetected: [DetectedGitAccount] {
        viewModel.detectedAccounts.filter { $0.provider == viewModel.newAccountProvider && !$0.hasToken }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title
            HStack {
                Text("Adicionar Conta")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(NexTheme.textPrimary)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(NexTheme.textSecondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(spacing: 14) {
                    // Provider picker
                    providerPicker
                        .padding(.top, 14)

                    // Auth method picker
                    authMethodPicker

                    // Detected hints
                    if viewModel.authMethod == .pat && !relevantDetected.isEmpty && viewModel.newAccountName.isEmpty {
                        detectedHintBanner
                    }

                    // Auth content
                    if viewModel.authMethod == .browser {
                        browserAuthContent
                    } else {
                        patAuthContent
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
        }
        .frame(width: 440, height: viewModel.isWaitingForOAuth ? 420 : 380)
        .background(NexTheme.bg)
        .onDisappear {
            viewModel.cancelBrowserLogin()
        }
    }

    // MARK: - Provider Picker

    private var providerPicker: some View {
        HStack(spacing: 0) {
            ForEach(RemoteProviderType.allCases) { type in
                Button {
                    viewModel.newAccountProvider = type
                    viewModel.cancelBrowserLogin()
                } label: {
                    HStack(spacing: 6) {
                        Text(type.displayName)
                            .font(.system(size: 12, weight: viewModel.newAccountProvider == type ? .semibold : .regular))
                    }
                    .foregroundColor(viewModel.newAccountProvider == type ? .white : NexTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(viewModel.newAccountProvider == type ? NexTheme.accent : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(NexTheme.surface)
        )
    }

    // MARK: - Auth Method Picker

    private var authMethodPicker: some View {
        HStack(spacing: 8) {
            authMethodButton(
                method: .browser,
                icon: "safari",
                title: "Entrar pelo Navegador",
                subtitle: viewModel.newAccountProvider == .github
                    ? "Autorizar via GitHub"
                    : "Criar token no Azure"
            )
            authMethodButton(
                method: .pat,
                icon: "key",
                title: "Token (PAT)",
                subtitle: "Colar manualmente"
            )
        }
    }

    private func authMethodButton(method: AddAccountAuthMethod, icon: String, title: String, subtitle: String) -> some View {
        Button {
            viewModel.authMethod = method
            viewModel.cancelBrowserLogin()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(viewModel.authMethod == method ? NexTheme.accent : NexTheme.textSecondary)
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(viewModel.authMethod == method ? NexTheme.textPrimary : NexTheme.textSecondary)
                Text(subtitle)
                    .font(.system(size: 8))
                    .foregroundColor(NexTheme.textSecondary.opacity(0.7))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(viewModel.authMethod == method ? NexTheme.accent.opacity(0.08) : NexTheme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(viewModel.authMethod == method ? NexTheme.accent.opacity(0.4) : NexTheme.border.opacity(0.3), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Browser Auth

    @ViewBuilder
    private var browserAuthContent: some View {
        if viewModel.newAccountProvider == .github {
            githubBrowserAuth
        } else {
            azureBrowserAuth
        }
    }

    private var githubBrowserAuth: some View {
        VStack(spacing: 12) {
            if viewModel.isWaitingForOAuth {
                // Waiting state
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Aguardando autorização no navegador...")
                        .font(.system(size: 11))
                        .foregroundColor(NexTheme.textSecondary)

                    if let code = viewModel.oauthUserCode {
                        VStack(spacing: 4) {
                            Text("Cole este código no GitHub:")
                                .font(.system(size: 10))
                                .foregroundColor(NexTheme.textSecondary)
                            Text(code)
                                .font(.system(size: 22, weight: .bold, design: .monospaced))
                                .foregroundColor(NexTheme.accent)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(NexTheme.accent.opacity(0.08))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(NexTheme.accent.opacity(0.3), lineWidth: 1)
                                        )
                                )
                            Text("Copiado para o clipboard automaticamente")
                                .font(.system(size: 9))
                                .foregroundColor(NexTheme.textSecondary.opacity(0.6))
                        }
                    }

                    Button("Cancelar") {
                        viewModel.cancelBrowserLogin()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(NexTheme.textSecondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(NexTheme.surface)
                )
            } else {
                // Start button
                VStack(spacing: 8) {
                    Text("O GitHub vai abrir no navegador para você autorizar o NexifyTerm.")
                        .font(.system(size: 11))
                        .foregroundColor(NexTheme.textSecondary)
                        .multilineTextAlignment(.center)

                    Button {
                        viewModel.startGitHubBrowserLogin()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "safari")
                                .font(.system(size: 12))
                            Text("Abrir GitHub no Navegador")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(NexTheme.accent)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: 4) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 8))
                        Text("Permissões: repo, read:org, read:user")
                            .font(.system(size: 9))
                    }
                    .foregroundColor(NexTheme.textSecondary.opacity(0.5))
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(NexTheme.surface)
                )
            }

            if let err = viewModel.oauthError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text(err)
                        .font(.system(size: 10))
                }
                .foregroundColor(.red)
            }
        }
    }

    private var azureBrowserAuth: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Organização Azure DevOps", text: $viewModel.newAccountOrg)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))

            VStack(spacing: 8) {
                Text("O Azure DevOps vai abrir no navegador para você criar um Personal Access Token.")
                    .font(.system(size: 11))
                    .foregroundColor(NexTheme.textSecondary)

                Button {
                    viewModel.openAzurePATCreationPage()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "safari")
                            .font(.system(size: 12))
                        Text("Abrir Azure DevOps no Navegador")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Color.blue)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.newAccountOrg.isEmpty)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(NexTheme.surface)
            )

            VStack(alignment: .leading, spacing: 6) {
                Text("Depois de criar, cole o token aqui:")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(NexTheme.textSecondary)

                HStack(spacing: 6) {
                    SecureField("Colar Personal Access Token", text: $viewModel.newAccountToken)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))

                    Button {
                        openPATCreationPage()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 11))
                            Text("Criar token")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(NexTheme.accent))
                    }
                    .buttonStyle(.plain)
                    .help("Abrir página de criação de token no navegador")
                }
            }

            HStack {
                Spacer()
                Button {
                    Task {
                        await viewModel.addAccountWithToken()
                        if viewModel.accounts.last != nil { dismiss() }
                    }
                } label: {
                    if viewModel.isAuthenticating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Conectar")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(viewModel.newAccountToken.isEmpty || viewModel.newAccountOrg.isEmpty || viewModel.isAuthenticating)
            }
        }
    }

    // MARK: - PAT Auth

    private var patAuthContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Nome da conta (opcional)", text: $viewModel.newAccountName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))

            if viewModel.newAccountProvider == .azureDevOps {
                TextField("Organização (obrigatório)", text: $viewModel.newAccountOrg)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }

            HStack(spacing: 6) {
                SecureField("Personal Access Token", text: $viewModel.newAccountToken)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))

                Button {
                    openPATCreationPage()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 11))
                        Text("Criar token")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(NexTheme.accent))
                }
                .buttonStyle(.plain)
                .help("Abrir página de criação de token no navegador")
            }

            tokenHelp

            HStack {
                Spacer()
                Button {
                    Task {
                        await viewModel.addAccountWithToken()
                        if viewModel.accounts.last != nil { dismiss() }
                    }
                } label: {
                    if viewModel.isAuthenticating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Conectar")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(viewModel.newAccountToken.isEmpty || viewModel.isAuthenticating)
            }
        }
    }

    // MARK: - Token Help

    @ViewBuilder
    private var tokenHelp: some View {
        switch viewModel.newAccountProvider {
        case .github:
            tokenHelpBox(
                title: "Como criar um token GitHub:",
                steps: "Settings \u{2192} Developer Settings \u{2192} Personal Access Tokens \u{2192} Fine-grained tokens",
                scopes: "Permissões: repo, read:org, read:user",
                linkLabel: "Criar token no GitHub",
                linkURL: "https://github.com/settings/tokens/new?scopes=repo,read:org,read:user&description=NexifyTerm"
            )
        case .azureDevOps:
            tokenHelpBox(
                title: "Como criar um token Azure DevOps:",
                steps: "User Settings \u{2192} Personal Access Tokens \u{2192} New Token",
                scopes: "Scopes: Code (Read), Work Items (Read)",
                linkLabel: "Criar token no Azure DevOps",
                linkURL: "https://dev.azure.com/\(viewModel.newAccountOrg.isEmpty ? "_" : viewModel.newAccountOrg)/_usersSettings/tokens"
            )
        }
    }

    private func tokenHelpBox(title: String, steps: String, scopes: String, linkLabel: String, linkURL: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(NexTheme.textSecondary)
            Text(steps)
                .font(.system(size: 9))
                .foregroundColor(NexTheme.textSecondary)
            Text(scopes)
                .font(.system(size: 9))
                .foregroundColor(NexTheme.textSecondary)
            Button {
                if let u = URL(string: linkURL) { NSWorkspace.shared.open(u) }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 8))
                    Text(linkLabel)
                        .font(.system(size: 9))
                }
                .foregroundColor(NexTheme.accent)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .padding(8)
        .background(NexTheme.surface)
        .cornerRadius(6)
    }

    private func openPATCreationPage() {
        let urlString: String
        switch viewModel.newAccountProvider {
        case .github:
            urlString = "https://github.com/settings/tokens/new?scopes=repo,read:org,read:user&description=NexifyTerm"
        case .azureDevOps:
            let org = viewModel.newAccountOrg.isEmpty ? "_" : viewModel.newAccountOrg
            urlString = "https://dev.azure.com/\(org)/_usersSettings/tokens"
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Detected Hint Banner

    @ViewBuilder
    private var detectedHintBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "sparkle")
                    .font(.system(size: 9))
                    .foregroundColor(.yellow)
                Text("Contas detectadas \u{2014} clique para preencher:")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(NexTheme.textSecondary)
            }

            ForEach(relevantDetected) { det in
                Button {
                    viewModel.newAccountName = det.username
                    viewModel.newAccountOrg = det.organization ?? viewModel.newAccountOrg
                } label: {
                    HStack(spacing: 6) {
                        Text(det.username)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(NexTheme.accent)
                        if let email = det.email {
                            Text("(\(email))")
                                .font(.system(size: 9))
                                .foregroundColor(NexTheme.textSecondary)
                        }
                        if let org = det.organization {
                            Text("org: \(org)")
                                .font(.system(size: 9))
                                .foregroundColor(NexTheme.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.right.circle")
                            .font(.system(size: 10))
                            .foregroundColor(NexTheme.textSecondary.opacity(0.5))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(NexTheme.bg)
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(NexTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(NexTheme.border.opacity(0.3), lineWidth: 0.5)
                )
        )
    }
}

// MARK: - Detected Account Row

struct DetectedAccountRow: View {
    let detected: DetectedGitAccount
    let onImport: () -> Void
    let onManualSetup: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: detected.provider.icon)
                    .font(.system(size: 16))
                    .foregroundColor(detected.provider.color)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(detected.provider.color.opacity(0.1))
                    )

                Image(systemName: detected.source.icon)
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(NexTheme.textSecondary)
                    .padding(2)
                    .background(Circle().fill(NexTheme.bg))
                    .offset(x: 3, y: 3)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(detected.username)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(NexTheme.textPrimary)
                        .lineLimit(1)

                    Text(detected.provider.displayName)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(detected.provider.color)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(detected.provider.color.opacity(0.1))
                        .cornerRadius(3)
                }

                HStack(spacing: 6) {
                    if let email = detected.email {
                        Text(email)
                            .font(.system(size: 9))
                            .foregroundColor(NexTheme.textSecondary)
                            .lineLimit(1)
                    }

                    if let org = detected.organization {
                        HStack(spacing: 2) {
                            Image(systemName: "building.2")
                                .font(.system(size: 7))
                            Text(org)
                                .font(.system(size: 9))
                        }
                        .foregroundColor(NexTheme.textSecondary)
                    }

                    HStack(spacing: 2) {
                        Image(systemName: detected.source.icon)
                            .font(.system(size: 7))
                        Text(detected.displaySource)
                            .font(.system(size: 9))
                    }
                    .foregroundColor(NexTheme.textSecondary.opacity(0.7))
                }
            }

            Spacer()

            if detected.hasToken {
                Button {
                    onImport()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 10))
                        Text("Importar")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(NexTheme.accent)
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .help("Importar com token detectado")
            } else {
                Button {
                    onManualSetup()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil")
                            .font(.system(size: 10))
                        Text("Configurar")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(NexTheme.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(NexTheme.accent.opacity(0.1))
                    .cornerRadius(5)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(NexTheme.accent.opacity(0.3), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .help("Token não encontrado — configurar manualmente")
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(NexTheme.bg)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(NexTheme.border.opacity(0.3), lineWidth: 0.5)
                )
        )
    }
}
