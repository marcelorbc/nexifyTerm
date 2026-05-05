import SwiftUI

struct MosaicPaneView: View {
    @EnvironmentObject var appState: AppState
    let paneId: UUID
    let content: PaneContent
    let tabId: UUID
    let directory: String
    let totalPanes: Int
    let onSplitH: () -> Void
    let onSplitV: () -> Void
    let onClose: () -> Void
    let onChangeContent: (PaneContent) -> Void

    @State private var isHeaderHovered = false

    /// Wave 6 · A9: this pane is "focused" (i.e. the agent will route commands
    /// here). Visualised by an accent border + a dot in the header.
    private var isFocused: Bool {
        appState.focusedPane(in: tabId) == paneId
    }

    var body: some View {
        VStack(spacing: 0) {
            paneHeader

            Divider()

            paneContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(NexTheme.bg)
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(
                    isFocused ? Color.accentColor.opacity(0.85) : NexTheme.border.opacity(0.4),
                    lineWidth: isFocused ? 1.5 : 0.5
                )
        )
        // Wave 6 · A9: capture taps anywhere inside the pane to claim focus,
        // but use `simultaneousGesture` so the tap still reaches the terminal
        // (NSView underneath needs the click to gain keyboard focus).
        .simultaneousGesture(
            TapGesture().onEnded { _ in
                appState.setFocusedPane(paneId, in: tabId)
            }
        )
        .animation(.easeInOut(duration: 0.15), value: isFocused)
    }

    // MARK: - Header

    private var paneHeader: some View {
        HStack(spacing: 4) {
            // Wave 6 · A9: dot indicator. Solid accent when focused so it's
            // unambiguous which pane the agent will target.
            Circle()
                .fill(isFocused ? Color.accentColor : NexTheme.textSecondary.opacity(0.25))
                .frame(width: 6, height: 6)

            Image(systemName: content.icon)
                .font(.system(size: 9))
                .foregroundColor(.accentColor)

            Text(content.label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(NexTheme.textPrimary)
                .lineLimit(1)

            Spacer()

            if isHeaderHovered {
                paneControls
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(isFocused ? Color.accentColor.opacity(0.08) : Color.clear)
        .background(.bar)
        .onHover { isHeaderHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHeaderHovered)
    }

    private var paneControls: some View {
        HStack(spacing: 2) {
            Menu {
                Button {
                    onChangeContent(.terminal(UUID()))
                } label: {
                    Label("Terminal", systemImage: "terminal.fill")
                }
                Button {
                    onChangeContent(.explorer(directory))
                } label: {
                    Label("Explorer", systemImage: "folder.fill")
                }
            } label: {
                paneButton(icon: "square.on.square")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 20)

            paneActionButton(icon: "rectangle.split.1x2", help: "Split Vertical") {
                onSplitV()
            }

            paneActionButton(icon: "rectangle.split.2x1", help: "Split Horizontal") {
                onSplitH()
            }

            if totalPanes > 1 {
                paneActionButton(icon: "xmark", help: "Fechar Painel") {
                    onClose()
                }
            }
        }
    }

    private func paneActionButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            paneButton(icon: icon)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func paneButton(icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 9))
            .foregroundColor(NexTheme.textSecondary)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
    }

    // MARK: - Content

    @ViewBuilder
    private var paneContent: some View {
        switch content {
        case .terminal(let sessionId):
            let session = appState.sessionManager.session(for: sessionId, initialDirectory: directory)
            SwiftTermViewRepresentable(session: session)
                .id(sessionId)

        case .explorer(let dir):
            FileExplorerView(directory: dir)
                .environmentObject(appState)
                .id(paneId)
        }
    }
}
