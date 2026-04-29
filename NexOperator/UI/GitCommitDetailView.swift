import SwiftUI

struct GitCommitDetailView: View {
    @ObservedObject var viewModel: GitViewModel
    let onClose: () -> Void

    @State private var fileListWidth: CGFloat = 300

    private static let fullDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.locale = Locale(identifier: "pt_BR")
        return f
    }()

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        f.locale = Locale(identifier: "pt_BR")
        return f
    }()

    var body: some View {
        Group {
            if viewModel.isLoadingDetail {
                loadingState
            } else if let detail = viewModel.commitDetail {
                horizontalLayout(detail)
            } else {
                emptyState
            }
        }
        .background(NexTheme.bg)
    }

    // MARK: - Horizontal Layout (files left | diff right)

    private func horizontalLayout(_ detail: GitCommitDetail) -> some View {
        HStack(spacing: 0) {
            leftPanel(detail)
                .frame(width: fileListWidth)

            fileListResizeHandle

            rightPanel
        }
    }

    // MARK: - Left Panel (info + files)

    private func leftPanel(_ detail: GitCommitDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            compactMetadata(detail)
            Divider()
            changedFilesHeader(detail)
            Divider()
            changedFilesList(detail)
        }
    }

    private func compactMetadata(_ detail: GitCommitDetail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(detail.subject)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(NexTheme.textPrimary)
                .lineLimit(2)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                HStack(spacing: 3) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 9))
                    Text(detail.authorName)
                        .font(.system(size: 10))
                }
                .foregroundColor(NexTheme.textSecondary)

                HStack(spacing: 3) {
                    Image(systemName: "calendar")
                        .font(.system(size: 9))
                    Text(Self.relativeDateFormatter.localizedString(for: detail.date, relativeTo: Date()))
                        .font(.system(size: 10))
                }
                .foregroundColor(NexTheme.textSecondary)

                Text(detail.shortHash)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(NexTheme.textSecondary)
                    .textSelection(.enabled)
            }

            HStack(spacing: 4) {
                ForEach(detail.branches, id: \.self) { branch in
                    refBadge(branch, color: .blue, icon: "arrow.triangle.branch")
                }
                ForEach(detail.tags, id: \.self) { tag in
                    refBadge(tag, color: .orange, icon: "tag.fill")
                }

                Spacer()

                HStack(spacing: 8) {
                    if detail.additions > 0 {
                        Text("+\(detail.additions)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.green)
                    }
                    if detail.deletions > 0 {
                        Text("-\(detail.deletions)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.red)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func changedFilesHeader(_ detail: GitCommitDetail) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 9))
                .foregroundColor(NexTheme.textSecondary)
            Text("Arquivos (\(detail.changedFiles.count))")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(NexTheme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(NexTheme.surface.opacity(0.5))
    }

    private func changedFilesList(_ detail: GitCommitDetail) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(detail.changedFiles) { file in
                    fileRow(file, hash: detail.hash)
                }
            }
        }
    }

    private func fileRow(_ file: GitFileStatus, hash: String) -> some View {
        let isSelected = viewModel.detailSelectedFile == file.path

        return Button {
            if isSelected {
                viewModel.closeDetailDiff()
            } else {
                Task { await viewModel.loadDetailFileDiff(hash: hash, path: file.path) }
            }
        } label: {
            HStack(spacing: 6) {
                statusBadge(file.status)

                Text(file.fileName)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(NexTheme.textPrimary)
                    .lineLimit(1)

                Spacer()

                if file.path.contains("/") {
                    Text(file.path.components(separatedBy: "/").dropLast().joined(separator: "/"))
                        .font(.system(size: 9))
                        .foregroundColor(NexTheme.textSecondary.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(isSelected ? NexTheme.accentDim : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func statusBadge(_ status: GitFileStatusKind) -> some View {
        Text(status.rawValue)
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundColor(.white)
            .frame(width: 16, height: 16)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(status.color)
            )
    }

    private func refBadge(_ name: String, color: Color, icon: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 7))
            Text(name)
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 3).fill(color))
        .lineLimit(1)
    }

    // MARK: - Right Panel (diff view)

    private var rightPanel: some View {
        Group {
            if let diff = viewModel.detailFileDiff {
                diffContent(diff)
            } else {
                diffPlaceholder
            }
        }
    }

    private func diffContent(_ diff: GitFileDiff) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            diffFileHeader(diff)
            Divider()

            if diff.hunks.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Image(systemName: "doc.plaintext")
                        .font(.system(size: 24))
                        .foregroundColor(NexTheme.textSecondary.opacity(0.3))
                    Text("Arquivo binário ou sem diferenças textuais")
                        .font(.system(size: 11))
                        .foregroundColor(NexTheme.textSecondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(diff.hunks) { hunk in
                            ForEach(hunk.lines) { line in
                                diffLineView(line)
                            }
                        }
                    }
                    .padding(4)
                }
            }
        }
        .background(NexTheme.bg)
    }

    private func diffFileHeader(_ diff: GitFileDiff) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 10))
                .foregroundColor(NexTheme.accent)
            Text(diff.filePath)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(NexTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            diffStats(diff)
            Button {
                viewModel.closeDetailDiff()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(NexTheme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Fechar diff")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(NexTheme.surface.opacity(0.5))
    }

    private func diffStats(_ diff: GitFileDiff) -> some View {
        let additions = diff.hunks.flatMap(\.lines).filter { $0.type == .addition }.count
        let deletions = diff.hunks.flatMap(\.lines).filter { $0.type == .deletion }.count
        return HStack(spacing: 4) {
            if additions > 0 {
                Text("+\(additions)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.green)
            }
            if deletions > 0 {
                Text("-\(deletions)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.red)
            }
        }
    }

    private func diffLineView(_ line: GitDiffLine) -> some View {
        HStack(spacing: 0) {
            Text(diffPrefix(line.type))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(line.color.opacity(0.6))
                .frame(width: 14, alignment: .center)
            Text(line.content)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(line.color)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 0.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(line.backgroundColor)
    }

    private func diffPrefix(_ type: GitDiffLine.LineType) -> String {
        switch type {
        case .addition: return "+"
        case .deletion: return "-"
        case .header:   return "@"
        case .context:  return " "
        }
    }

    private var diffPlaceholder: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "arrow.left.circle")
                .font(.system(size: 28))
                .foregroundColor(NexTheme.textSecondary.opacity(0.3))
            Text("Clique em um arquivo\npara ver o diff")
                .font(.system(size: 12))
                .foregroundColor(NexTheme.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NexTheme.bg)
    }

    // MARK: - Resize Handle

    private var fileListResizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: NexTheme.dragHandleThickness)
            .overlay(
                Rectangle()
                    .fill(NexTheme.border)
                    .frame(width: 1)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let newWidth = fileListWidth + value.translation.width
                        fileListWidth = min(500, max(200, newWidth))
                    }
            )
            .cursorOnHover(.resizeLeftRight)
    }

    // MARK: - States

    private var loadingState: some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Carregando detalhes...")
                    .font(.system(size: 11))
                    .foregroundColor(NexTheme.textSecondary)
            }
            Spacer()
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "arrow.up.circle")
                    .font(.system(size: 28))
                    .foregroundColor(NexTheme.textSecondary.opacity(0.3))
                Text("Selecione um commit no grafo\npara ver os detalhes")
                    .font(.system(size: 12))
                    .foregroundColor(NexTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxHeight: .infinity)
    }
}
