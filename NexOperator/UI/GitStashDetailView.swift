import SwiftUI

/// Full diff modal for a single stash. Loads `git stash show -p` lazily and
/// renders it with simple +/- syntax coloring (no need for the heavyweight
/// GitDiffView since stash diffs are read-only by definition).
struct GitStashDetailView: View {
    @ObservedObject var viewModel: GitViewModel
    let index: Int
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private var details: GitStashDetails? {
        viewModel.stashDetailsCache[index]
    }

    private var stash: GitStash? {
        viewModel.stashes.first(where: { $0.id == index })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 720, minHeight: 480)
        .frame(idealWidth: 900, idealHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await viewModel.loadStashDetails(index) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.full")
                .font(.title3)
                .foregroundColor(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text("stash@{\(index)}")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(NexTheme.textPrimary)
                if let msg = stash?.message {
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundColor(NexTheme.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer()

            if let details, !details.rawDiff.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(details.rawDiff, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                        Text(copied ? "Copiado!" : "Copiar diff")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(copied ? .green : NexTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }

            Menu {
                Button("Aplicar (pop)") {
                    Task {
                        await viewModel.stashPop(index)
                        dismiss()
                    }
                }
                Button("Remover (drop)", role: .destructive) {
                    Task {
                        await viewModel.stashDrop(index)
                        dismiss()
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 11))
                    Text("Ações")
                        .font(.system(size: 11))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .foregroundColor(NexTheme.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 80)

            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(NexTheme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.loadingStashDetails.contains(index) && details == nil {
            VStack(spacing: 8) {
                Spacer()
                ProgressView()
                Text("Carregando diff…")
                    .font(.system(size: 11))
                    .foregroundColor(NexTheme.textSecondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let details {
            HSplitView {
                fileList(details)
                    .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
                diffPane(details)
            }
        } else {
            VStack(spacing: 8) {
                Spacer()
                Text("Sem dados para este stash.")
                    .font(.system(size: 12))
                    .foregroundColor(NexTheme.textSecondary)
                Button("Recarregar") {
                    Task { await viewModel.loadStashDetails(index, force: true) }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func fileList(_ details: GitStashDetails) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("ARQUIVOS · \(details.files.count)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(NexTheme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(details.files) { f in
                        HStack(spacing: 6) {
                            Image(systemName: f.status.icon)
                                .font(.system(size: 9))
                                .foregroundColor(f.status.color)
                                .frame(width: 12)
                            Text(f.path)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(NexTheme.textPrimary)
                                .lineLimit(2)
                                .truncationMode(.head)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .background(NexTheme.surface.opacity(0.4))
    }

    private func diffPane(_ details: GitStashDetails) -> some View {
        ScrollView([.vertical, .horizontal]) {
            if details.rawDiff.isEmpty {
                Text("(diff vazio)")
                    .font(.system(size: 11))
                    .foregroundColor(NexTheme.textSecondary)
                    .padding()
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(details.rawDiff.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                        diffLine(String(line))
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func diffLine(_ line: String) -> some View {
        let kind = Self.diffLineKind(line)
        Text(line.isEmpty ? " " : line)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(kind.fg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(kind.bg)
            .textSelection(.enabled)
    }

    private static func diffLineKind(_ line: String) -> (fg: Color, bg: Color) {
        if line.hasPrefix("+++") || line.hasPrefix("---") {
            return (.secondary, Color.gray.opacity(0.08))
        }
        if line.hasPrefix("@@") {
            return (.cyan, Color.cyan.opacity(0.08))
        }
        if line.hasPrefix("+") {
            return (Color.green, Color.green.opacity(0.10))
        }
        if line.hasPrefix("-") {
            return (Color.red, Color.red.opacity(0.10))
        }
        if line.hasPrefix("diff ") || line.hasPrefix("index ") {
            return (.secondary, Color.clear)
        }
        return (.primary, .clear)
    }
}
