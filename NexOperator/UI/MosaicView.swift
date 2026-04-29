import SwiftUI

struct MosaicView: View {
    @EnvironmentObject var appState: AppState
    let node: MosaicNode
    let tabId: UUID
    let directory: String
    let onLayoutChange: (MosaicNode) -> Void

    var body: some View {
        renderNode(node)
    }

    @ViewBuilder
    private func renderNode(_ node: MosaicNode) -> some View {
        switch node {
        case .pane(let id, let content):
            MosaicPaneView(
                paneId: id,
                content: content,
                tabId: tabId,
                directory: directory,
                totalPanes: self.node.paneCount,
                onSplitH: { splitPane(id, axis: .horizontal) },
                onSplitV: { splitPane(id, axis: .vertical) },
                onClose: { closePane(id) },
                onChangeContent: { newContent in changePaneContent(id, to: newContent) }
            )

        case .split(let id, let axis, let ratio, let first, let second):
            MosaicSplitView(
                axis: axis,
                ratio: ratio,
                onRatioChange: { newRatio in
                    onLayoutChange(self.node.updatingRatio(splitId: id, newRatio: newRatio))
                },
                first: {
                    MosaicView(
                        node: first,
                        tabId: tabId,
                        directory: directory,
                        onLayoutChange: onLayoutChange
                    )
                    .environmentObject(appState)
                },
                second: {
                    MosaicView(
                        node: second,
                        tabId: tabId,
                        directory: directory,
                        onLayoutChange: onLayoutChange
                    )
                    .environmentObject(appState)
                }
            )
        }
    }

    private func splitPane(_ paneId: UUID, axis: MosaicAxis) {
        guard case .pane(_, let content) = findPane(paneId, in: node) else { return }
        let newContent: PaneContent = content.isTerminal ? .terminal(UUID()) : .explorer(directory)
        let newNode = MosaicNode.split(
            id: UUID(), axis: axis, ratio: 0.5,
            first: .pane(id: paneId, content: content),
            second: .pane(id: UUID(), content: newContent)
        )
        onLayoutChange(node.replacingPane(paneId, with: newNode))
    }

    private func closePane(_ paneId: UUID) {
        guard node.paneCount > 1,
              let newLayout = node.removingPane(paneId) else { return }
        onLayoutChange(newLayout)
    }

    private func changePaneContent(_ paneId: UUID, to newContent: PaneContent) {
        let updated = node.replacingPane(paneId, with: .pane(id: paneId, content: newContent))
        onLayoutChange(updated)
    }

    private func findPane(_ paneId: UUID, in node: MosaicNode) -> MosaicNode? {
        switch node {
        case .pane(let id, _):
            return id == paneId ? node : nil
        case .split(_, _, _, let first, let second):
            return findPane(paneId, in: first) ?? findPane(paneId, in: second)
        }
    }
}

// MARK: - Split Container with draggable divider

struct MosaicSplitView<First: View, Second: View>: View {
    let axis: MosaicAxis
    let ratio: CGFloat
    let onRatioChange: (CGFloat) -> Void
    @ViewBuilder let first: First
    @ViewBuilder let second: Second

    var body: some View {
        GeometryReader { geo in
            let isHorizontal = axis == .horizontal
            let totalSize = isHorizontal ? geo.size.width : geo.size.height

            if isHorizontal {
                HStack(spacing: 0) {
                    first
                        .frame(width: totalSize * ratio)

                    mosaicDivider(isHorizontal: true, totalSize: totalSize)

                    second
                        .frame(width: totalSize * (1 - ratio) - 6)
                }
            } else {
                VStack(spacing: 0) {
                    first
                        .frame(height: totalSize * ratio)

                    mosaicDivider(isHorizontal: false, totalSize: totalSize)

                    second
                        .frame(height: totalSize * (1 - ratio) - 6)
                }
            }
        }
    }

    private func mosaicDivider(isHorizontal: Bool, totalSize: CGFloat) -> some View {
        Rectangle()
            .fill(NexTheme.border.opacity(0.6))
            .frame(
                width: isHorizontal ? 6 : nil,
                height: isHorizontal ? nil : 6
            )
            .overlay(
                RoundedRectangle(cornerRadius: 1)
                    .fill(NexTheme.textSecondary.opacity(0.3))
                    .frame(
                        width: isHorizontal ? 2 : 24,
                        height: isHorizontal ? 24 : 2
                    )
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let delta = isHorizontal ? value.translation.width : value.translation.height
                        let newRatio = ratio + (delta / totalSize)
                        onRatioChange(min(0.85, max(0.15, newRatio)))
                    }
            )
            .cursorOnHover(isHorizontal ? .resizeLeftRight : .resizeUpDown)
    }
}
