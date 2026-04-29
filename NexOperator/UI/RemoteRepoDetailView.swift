import SwiftUI

struct RemoteRepoDetailView: View {
    @ObservedObject var viewModel: RemoteExplorerViewModel
    let repo: RemoteRepository
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            detailHeader
            Divider()

            Picker("", selection: $selectedTab) {
                Label("Arquivos", systemImage: "folder").tag(0)
                Label("Pull Requests", systemImage: "arrow.triangle.pull").tag(1)
                Label("Issues", systemImage: "circle.fill").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            switch selectedTab {
            case 0: fileTreeView
            case 1: pullRequestsView
            case 2: issuesView
            default: EmptyView()
            }
        }
        .frame(minWidth: 800, minHeight: 550)
        .background(NexTheme.bg)
    }

    // MARK: - Header

    private var detailHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: repo.provider == .github ? "cat" : "cloud.fill")
                .font(.system(size: 14))
                .foregroundColor(repo.provider.color)

            VStack(alignment: .leading, spacing: 2) {
                Text(repo.fullName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(NexTheme.textPrimary)

                if let desc = repo.description {
                    Text(desc)
                        .font(.system(size: 10))
                        .foregroundColor(NexTheme.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            repoStats

            Button {
                if let url = URL(string: repo.htmlURL) {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "safari")
                        .font(.system(size: 10))
                    Text("Abrir no Browser")
                        .font(.system(size: 10))
                }
                .foregroundColor(NexTheme.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(NexTheme.accentDim)
                .cornerRadius(5)
            }
            .buttonStyle(.plain)

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(NexTheme.textSecondary)
                    .frame(width: NexTheme.hitTargetSmall, height: NexTheme.hitTargetSmall)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(NexTheme.surface)
    }

    private var repoStats: some View {
        HStack(spacing: 12) {
            if let lang = repo.language {
                HStack(spacing: 3) {
                    Circle().fill(repo.languageColor).frame(width: 8, height: 8)
                    Text(lang).font(.system(size: 10))
                }
                .foregroundColor(NexTheme.textSecondary)
            }

            if repo.stars > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "star.fill").font(.system(size: 9))
                    Text("\(repo.stars)").font(.system(size: 10))
                }
                .foregroundColor(.yellow)
            }

            HStack(spacing: 2) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 9))
                Text(repo.defaultBranch).font(.system(size: 10))
            }
            .foregroundColor(NexTheme.textSecondary)
        }
    }

    // MARK: - File Tree

    private var fileTreeView: some View {
        HSplitView {
            VStack(spacing: 0) {
                breadcrumb
                Divider()

                if viewModel.isLoadingContent && viewModel.fileTree.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    fileList
                }
            }
            .frame(minWidth: 280)

            VStack(spacing: 0) {
                if let path = viewModel.selectedFilePath {
                    HStack {
                        Image(systemName: "doc.text")
                            .font(.system(size: 10))
                            .foregroundColor(NexTheme.textSecondary)
                        Text(path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(NexTheme.textPrimary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(NexTheme.surface)

                    Divider()
                }

                if viewModel.isLoadingContent && viewModel.selectedFilePath != nil {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let content = viewModel.fileContent {
                    fileContentView(content)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 28))
                            .foregroundColor(NexTheme.textSecondary.opacity(0.3))
                        Text("Selecione um arquivo para visualizar")
                            .font(.system(size: 11))
                            .foregroundColor(NexTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 400)
        }
    }

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            Button {
                viewModel.navigateToRoot()
            } label: {
                Image(systemName: "house")
                    .font(.system(size: 10))
                    .foregroundColor(NexTheme.accent)
            }
            .buttonStyle(.plain)

            if !viewModel.currentPath.isEmpty {
                Image(systemName: "chevron.right")
                    .font(.system(size: 7))
                    .foregroundColor(NexTheme.textSecondary)

                ForEach(Array(viewModel.currentPath.enumerated()), id: \.offset) { index, segment in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 7))
                            .foregroundColor(NexTheme.textSecondary)
                    }
                    Text(segment)
                        .font(.system(size: 10))
                        .foregroundColor(index == viewModel.currentPath.count - 1 ? NexTheme.textPrimary : NexTheme.accent)
                }
            }

            Spacer()

            if !viewModel.currentPath.isEmpty {
                Button {
                    viewModel.navigateBack()
                } label: {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 10))
                        .foregroundColor(NexTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Voltar")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(NexTheme.surface.opacity(0.5))
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(viewModel.fileTree) { node in
                    FileNodeRow(node: node) {
                        if node.type == .directory {
                            viewModel.navigateToDirectory(node)
                        } else {
                            Task { await viewModel.loadFileContent(node) }
                        }
                    }
                }
            }
            .padding(4)
        }
    }

    private func fileContentView(_ content: String) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Text(content)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(NexTheme.textPrimary)
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Pull Requests

    private var pullRequestsView: some View {
        Group {
            if viewModel.isLoadingPRs {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.pullRequests.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.pull")
                        .font(.system(size: 28))
                        .foregroundColor(NexTheme.textSecondary.opacity(0.3))
                    Text("Nenhum Pull Request encontrado")
                        .font(.system(size: 12))
                        .foregroundColor(NexTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(viewModel.pullRequests) { pr in
                            PRRow(pr: pr)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    // MARK: - Issues

    private var issuesView: some View {
        Group {
            if viewModel.isLoadingIssues {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.issues.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "circle")
                        .font(.system(size: 28))
                        .foregroundColor(NexTheme.textSecondary.opacity(0.3))
                    Text("Nenhuma Issue encontrada")
                        .font(.system(size: 12))
                        .foregroundColor(NexTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(viewModel.issues) { issue in
                            IssueRow(issue: issue)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }
}

// MARK: - File Node Row

struct FileNodeRow: View {
    let node: RemoteFileNode
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: node.icon)
                .font(.system(size: 11))
                .foregroundColor(node.iconColor)
                .frame(width: 16)

            Text(node.name)
                .font(.system(size: 11))
                .foregroundColor(NexTheme.textPrimary)
                .lineLimit(1)

            Spacer()

            if let size = node.size, node.type == .file {
                Text(formatSize(size))
                    .font(.system(size: 9))
                    .foregroundColor(NexTheme.textSecondary)
            }

            if node.type == .directory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8))
                    .foregroundColor(NexTheme.textSecondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.clear)
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onTapGesture { action() }
        .cursorOnHover(.pointingHand)
    }

    private func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }
}

// MARK: - PR Row

struct PRRow: View {
    let pr: RemotePullRequest

    private let dateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "pt-BR")
        return f
    }()

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: pr.status.icon)
                .font(.system(size: 13))
                .foregroundColor(pr.status.color)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("#\(pr.number)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(NexTheme.textSecondary)
                    Text(pr.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(NexTheme.textPrimary)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    Text(pr.author)
                        .font(.system(size: 9))
                        .foregroundColor(NexTheme.textSecondary)

                    HStack(spacing: 2) {
                        Text(pr.sourceBranch)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(NexTheme.accent)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 7))
                            .foregroundColor(NexTheme.textSecondary)
                        Text(pr.targetBranch)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(NexTheme.textSecondary)
                    }

                    Text(dateFormatter.localizedString(for: pr.createdAt, relativeTo: Date()))
                        .font(.system(size: 9))
                        .foregroundColor(NexTheme.textSecondary)
                }
            }

            Spacer()

            Button {
                if let url = URL(string: pr.url) {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 10))
                    .foregroundColor(NexTheme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Abrir no browser")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(NexTheme.surface.opacity(0.5))
        .cornerRadius(6)
    }
}

// MARK: - Issue Row

struct IssueRow: View {
    let issue: RemoteIssue

    private let dateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "pt-BR")
        return f
    }()

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: issue.state.icon)
                .font(.system(size: 12))
                .foregroundColor(issue.state.color)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("#\(issue.number)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(NexTheme.textSecondary)
                    Text(issue.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(NexTheme.textPrimary)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    Text(issue.author)
                        .font(.system(size: 9))
                        .foregroundColor(NexTheme.textSecondary)

                    if !issue.labels.isEmpty {
                        ForEach(issue.labels.prefix(3), id: \.self) { label in
                            Text(label)
                                .font(.system(size: 8))
                                .foregroundColor(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(NexTheme.accent.opacity(0.7))
                                .cornerRadius(3)
                        }
                    }

                    Text(dateFormatter.localizedString(for: issue.createdAt, relativeTo: Date()))
                        .font(.system(size: 9))
                        .foregroundColor(NexTheme.textSecondary)
                }
            }

            Spacer()

            Button {
                if let url = URL(string: issue.url) {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 10))
                    .foregroundColor(NexTheme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Abrir no browser")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(NexTheme.surface.opacity(0.5))
        .cornerRadius(6)
    }
}
