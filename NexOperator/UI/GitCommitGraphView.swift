import SwiftUI

struct GitCommitGraphView: View {
    @ObservedObject var viewModel: GitViewModel

    @State private var confirmAction: DangerousAction?
    @State private var showConfirm = false

    private let rowHeight: CGFloat = 32
    private let laneWidth: CGFloat = 20
    private let nodeRadius: CGFloat = 6
    private let graphPadding: CGFloat = 14

    private var graphColumnWidth: CGFloat {
        CGFloat(max(viewModel.maxLaneCount, 1)) * laneWidth + graphPadding * 2
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(viewModel.filteredCommits.enumerated()), id: \.element.id) { index, commit in
                    commitRow(commit, row: index)
                        .onAppear {
                            if index == viewModel.filteredCommits.count - 10 {
                                Task { await viewModel.loadMoreCommits() }
                            }
                        }
                }
            }
            .background(
                graphCanvas
                    .frame(width: graphColumnWidth)
                    .offset(x: 0),
                alignment: .leading
            )
        }
        .background(NexTheme.bg)
        .alert("Ação Destrutiva", isPresented: $showConfirm) {
            if let action = confirmAction {
                Button("Cancelar", role: .cancel) { confirmAction = nil }
                Button(action.confirmLabel, role: .destructive) {
                    let act = action
                    confirmAction = nil
                    Task { await act.execute(viewModel: viewModel) }
                }
            }
        } message: {
            if let action = confirmAction {
                Text(action.warningMessage)
            }
        }
    }

    // MARK: - Commit Row

    private func commitRow(_ commit: GitCommit, row: Int) -> some View {
        let isSelected = viewModel.selectedCommitId == commit.id

        return HStack(spacing: 0) {
            Color.clear
                .frame(width: graphColumnWidth, height: rowHeight)

            HStack(spacing: 8) {
                Text(commit.shortHash)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(NexTheme.textSecondary)
                    .frame(width: 56, alignment: .leading)

                HStack(spacing: 3) {
                    if commit.isHead {
                        headBadge
                    }

                    ForEach(localBranches(commit), id: \.self) { branch in
                        localBranchBadge(branch, hasRemote: hasMatchingRemote(branch, in: commit))
                    }
                    ForEach(remoteBranches(commit), id: \.self) { branch in
                        remoteBranchBadge(branch)
                    }
                    ForEach(commit.tags, id: \.self) { tag in
                        tagBadge(tag)
                    }

                    if isLocalOnly(commit) {
                        localOnlyIndicator
                    }
                }

                Text(commit.subject)
                    .font(.system(size: 12))
                    .foregroundColor(NexTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                Text(commit.authorName)
                    .font(.system(size: 11))
                    .foregroundColor(NexTheme.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: 120, alignment: .trailing)

                Text(Self.relativeDateFormatter.localizedString(for: commit.date, relativeTo: Date()))
                    .font(.system(size: 11))
                    .foregroundColor(NexTheme.textSecondary.opacity(0.7))
                    .frame(width: 70, alignment: .trailing)
            }
            .padding(.trailing, 12)
        }
        .frame(height: rowHeight)
        .background(
            isSelected
                ? NexTheme.accentDim
                : (row % 2 == 0 ? Color.clear : NexTheme.surface.opacity(0.3))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.selectedCommitId = commit.id
        }
        .contextMenu {
            Section {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(commit.id, forType: .string)
                } label: {
                    Label("Copiar Hash", systemImage: "doc.on.doc")
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(commit.shortHash, forType: .string)
                } label: {
                    Label("Copiar Hash Curto", systemImage: "doc.on.clipboard")
                }
            }

            Divider()

            Section("Navegar") {
                Button {
                    Task { await viewModel.checkoutBranch(commit.shortHash) }
                } label: {
                    Label("Checkout neste commit", systemImage: "arrow.uturn.right")
                }

                if !commit.branches.isEmpty {
                    ForEach(commit.branches, id: \.self) { branch in
                        Button {
                            Task { await viewModel.checkoutBranch(branch) }
                        } label: {
                            Label("Checkout \(branch)", systemImage: "arrow.triangle.branch")
                        }
                    }
                }
            }

            Section("Aplicar") {
                Button {
                    Task { await viewModel.cherryPick(commit.id) }
                } label: {
                    Label("Cherry-pick", systemImage: "plus.circle")
                }

                Button {
                    confirmAction = .revert(hash: commit.id, shortHash: commit.shortHash)
                    showConfirm = true
                } label: {
                    Label("Revert commit", systemImage: "arrow.uturn.backward")
                }
            }

            let mergeable = commit.branches.filter { !$0.contains("HEAD") && $0 != viewModel.currentBranch }
            if !mergeable.isEmpty {
                Section("Merge / Rebase") {
                    ForEach(mergeable, id: \.self) { branch in
                        Button {
                            Task { await viewModel.mergeBranch(branch) }
                        } label: {
                            Label("Merge \(branch) → \(viewModel.currentBranch)", systemImage: "arrow.triangle.merge")
                        }
                    }
                    ForEach(mergeable, id: \.self) { branch in
                        Button {
                            Task { await viewModel.rebaseBranch(branch) }
                        } label: {
                            Label("Rebase em \(branch)", systemImage: "arrow.triangle.swap")
                        }
                    }
                }
            }

            Divider()

            Section("Reset") {
                Button {
                    Task { await viewModel.resetSoft(to: commit.id) }
                } label: {
                    Label("Soft Reset aqui", systemImage: "arrow.counterclockwise")
                }

                Button {
                    Task { await viewModel.resetMixed(to: commit.id) }
                } label: {
                    Label("Mixed Reset aqui", systemImage: "arrow.counterclockwise.circle")
                }

                Button(role: .destructive) {
                    confirmAction = .hardReset(hash: commit.id, shortHash: commit.shortHash)
                    showConfirm = true
                } label: {
                    Label("⚠️ Hard Reset aqui", systemImage: "exclamationmark.triangle")
                }
            }
        }
    }

    // MARK: - Branch Helpers

    private func localBranches(_ commit: GitCommit) -> [String] {
        commit.branches.filter { !$0.contains("/") }
    }

    private func remoteBranches(_ commit: GitCommit) -> [String] {
        commit.branches.filter { $0.contains("/") }
    }

    private func hasMatchingRemote(_ localBranch: String, in commit: GitCommit) -> Bool {
        commit.branches.contains(where: { $0.hasSuffix("/\(localBranch)") })
    }

    private func isLocalOnly(_ commit: GitCommit) -> Bool {
        let locals = localBranches(commit)
        guard !locals.isEmpty else { return false }
        return locals.contains(where: { !hasMatchingRemote($0, in: commit) })
    }

    // MARK: - Badges

    private func localBranchBadge(_ name: String, hasRemote: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: hasRemote ? "checkmark.circle.fill" : "arrow.up.circle")
                .font(.system(size: 7, weight: .bold))
            Text(name)
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(hasRemote ? Color.blue : Color.teal)
        )
        .lineLimit(1)
        .help(hasRemote ? "\(name) (sincronizado com remoto)" : "\(name) (somente local)")
    }

    private func remoteBranchBadge(_ name: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "cloud.fill")
                .font(.system(size: 7))
            Text(name)
                .font(.system(size: 9, weight: .medium))
        }
        .foregroundColor(.white.opacity(0.9))
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.indigo.opacity(0.8))
        )
        .lineLimit(1)
        .help("\(name) (remoto)")
    }

    private func tagBadge(_ name: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "tag.fill")
                .font(.system(size: 7))
            Text(name)
                .font(.system(size: 9, weight: .medium))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.orange)
        )
        .lineLimit(1)
    }

    private var headBadge: some View {
        HStack(spacing: 2) {
            Image(systemName: "smallcircle.filled.circle.fill")
                .font(.system(size: 7))
            Text("HEAD")
                .font(.system(size: 9, weight: .bold))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.red)
        )
    }

    private var localOnlyIndicator: some View {
        HStack(spacing: 2) {
            Image(systemName: "arrow.up")
                .font(.system(size: 7, weight: .bold))
            Text("local")
                .font(.system(size: 8, weight: .semibold))
        }
        .foregroundColor(.teal)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color.teal, lineWidth: 1)
        )
        .help("Commit ainda não está no remoto")
    }

    // MARK: - Graph Canvas

    private var graphCanvas: some View {
        Canvas { context, size in
            let commits = viewModel.filteredCommits
            let lineStyle = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
            let glowStyle = StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)

            for line in viewModel.graphLines {
                guard line.fromRow < commits.count && line.toRow < commits.count else { continue }
                let linePath = buildLinePath(line)
                context.stroke(linePath, with: .color(line.color.opacity(0.15)), style: glowStyle)
            }

            for line in viewModel.graphLines {
                guard line.fromRow < commits.count && line.toRow < commits.count else { continue }
                let linePath = buildLinePath(line)
                context.stroke(linePath, with: .color(line.color), style: lineStyle)
            }

            for (row, commit) in commits.enumerated() {
                let x = graphPadding + CGFloat(commit.lane) * laneWidth + laneWidth / 2
                let y = CGFloat(row) * rowHeight + rowHeight / 2
                let color = GitGraphLine.color(for: commit.lane)
                let isSpecial = commit.isHead || !commit.branches.isEmpty
                let r: CGFloat = isSpecial ? nodeRadius + 1 : nodeRadius

                let outerCircle = Path(ellipseIn: CGRect(
                    x: x - r, y: y - r, width: r * 2, height: r * 2
                ))
                context.fill(outerCircle, with: .color(color))

                if commit.isMerge {
                    let dotR: CGFloat = 2.5
                    let dot = Path(ellipseIn: CGRect(
                        x: x - dotR, y: y - dotR, width: dotR * 2, height: dotR * 2
                    ))
                    context.fill(dot, with: .color(.white.opacity(0.85)))
                } else if isSpecial {
                    let innerR = r - 2.5
                    let innerCircle = Path(ellipseIn: CGRect(
                        x: x - innerR, y: y - innerR, width: innerR * 2, height: innerR * 2
                    ))
                    context.fill(innerCircle, with: .color(Color(nsColor: .windowBackgroundColor)))
                }
            }
        }
        .frame(height: CGFloat(viewModel.filteredCommits.count) * rowHeight)
    }

    private func buildLinePath(_ line: GitGraphLine) -> Path {
        let startX = graphPadding + CGFloat(line.fromLane) * laneWidth + laneWidth / 2
        let startY = CGFloat(line.fromRow) * rowHeight + rowHeight / 2
        let endX = graphPadding + CGFloat(line.toLane) * laneWidth + laneWidth / 2
        let endY = CGFloat(line.toRow) * rowHeight + rowHeight / 2

        var path = Path()
        path.move(to: CGPoint(x: startX, y: startY))

        if line.fromLane == line.toLane {
            path.addLine(to: CGPoint(x: endX, y: endY))
        } else {
            let totalHeight = endY - startY
            let curveHeight = min(rowHeight * 1.2, totalHeight * 0.45)

            if line.isMerge {
                let curveEndY = startY + curveHeight
                path.addCurve(
                    to: CGPoint(x: endX, y: curveEndY),
                    control1: CGPoint(x: startX, y: startY + curveHeight * 0.55),
                    control2: CGPoint(x: endX, y: curveEndY - curveHeight * 0.15)
                )
                if curveEndY < endY {
                    path.addLine(to: CGPoint(x: endX, y: endY))
                }
            } else {
                let curveStartY = endY - curveHeight
                if curveStartY > startY {
                    path.addLine(to: CGPoint(x: startX, y: curveStartY))
                }
                path.addCurve(
                    to: CGPoint(x: endX, y: endY),
                    control1: CGPoint(x: startX, y: curveStartY + curveHeight * 0.15),
                    control2: CGPoint(x: endX, y: endY - curveHeight * 0.55)
                )
            }
        }

        return path
    }
}

// MARK: - Dangerous Action Confirmation

enum DangerousAction {
    case hardReset(hash: String, shortHash: String)
    case revert(hash: String, shortHash: String)

    var confirmLabel: String {
        switch self {
        case .hardReset: return "Hard Reset"
        case .revert: return "Revert"
        }
    }

    var warningMessage: String {
        switch self {
        case .hardReset(_, let short):
            return "Hard Reset para \(short) vai APAGAR todas as mudanças não commitadas e remover commits posteriores. Essa ação é IRREVERSÍVEL."
        case .revert(_, let short):
            return "Isso criará um novo commit que desfaz as mudanças do commit \(short). Mudanças não commitadas podem ser perdidas."
        }
    }

    @MainActor
    func execute(viewModel: GitViewModel) async {
        switch self {
        case .hardReset(let hash, _):
            await viewModel.resetHard(to: hash)
        case .revert(let hash, _):
            await viewModel.revertCommit(hash)
        }
    }
}
