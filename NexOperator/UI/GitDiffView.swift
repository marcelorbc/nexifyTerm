import SwiftUI

struct GitDiffView: View {
    let diff: GitFileDiff
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            diffContent
        }
        .frame(minWidth: 500, minHeight: 300)
        .frame(idealWidth: 700, idealHeight: 500)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: NexTheme.iconSizeMedium))
                .foregroundColor(NexTheme.accent)

            Text(diff.filePath)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(NexTheme.textPrimary)
                .lineLimit(1)

            Spacer()

            diffStats

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: NexTheme.iconSizeSmall, weight: .bold))
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

    private var diffStats: some View {
        let additions = diff.hunks.flatMap(\.lines).filter { $0.type == .addition }.count
        let deletions = diff.hunks.flatMap(\.lines).filter { $0.type == .deletion }.count

        return HStack(spacing: 6) {
            if additions > 0 {
                Text("+\(additions)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.green)
            }
            if deletions > 0 {
                Text("-\(deletions)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.red)
            }
        }
    }

    // MARK: - Content

    private var diffContent: some View {
        Group {
            if diff.hunks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 30))
                        .foregroundColor(.green.opacity(0.5))
                    Text("Nenhuma diferença")
                        .font(.system(size: 13))
                        .foregroundColor(NexTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(diff.hunks) { hunk in
                            hunkView(hunk)
                        }
                    }
                    .padding(8)
                }
                .background(NexTheme.bg)
            }
        }
    }

    private func hunkView(_ hunk: GitDiffHunk) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(hunk.lines) { line in
                lineView(line)
            }
        }
    }

    private func lineView(_ line: GitDiffLine) -> some View {
        HStack(spacing: 0) {
            Text(linePrefix(line.type))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(line.color.opacity(0.7))
                .frame(width: 16, alignment: .center)

            Text(line.content)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(line.color)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(line.backgroundColor)
    }

    private func linePrefix(_ type: GitDiffLine.LineType) -> String {
        switch type {
        case .addition: return "+"
        case .deletion: return "-"
        case .header:   return "@"
        case .context:  return " "
        }
    }
}
