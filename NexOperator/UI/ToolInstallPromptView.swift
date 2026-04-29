import SwiftUI

struct ToolInstallPromptView: View {
    @EnvironmentObject var appState: AppState
    let request: ToolInstallRequest

    private var tool: MissingToolInfo { request.missingTool }
    private var suggestion: ToolInstallSuggestion? { tool.installSuggestion }
    private var hasAlternative: Bool { suggestion?.alternativeCommand != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Label("Command that failed:", systemImage: "xmark.circle")
                    .font(.caption.bold())
                    .foregroundColor(.red)

                Text(tool.failedCommand)
                    .font(.system(.caption, design: .monospaced))
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.06))
                    .cornerRadius(4)
            }

            if let suggestion {
                VStack(alignment: .leading, spacing: 6) {
                    Label(suggestion.description, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if hasAlternative {
                        Label("Full path available: \(suggestion.alternativeCommand!)", systemImage: "arrow.right.circle")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.blue)
                    } else {
                        Label("Install: \(suggestion.installCommand)", systemImage: "arrow.down.circle")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.orange)
                    }
                }
            }

            Divider()

            actionButtons
        }
        .padding(12)
        .background(NexTheme.surface)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text("Tool not found: \(tool.toolName)")
                    .font(.headline)

                Text("This tool is required to complete the task")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 8) {
            if hasAlternative {
                Button {
                    appState.respondToToolInstall(.useAlternative)
                } label: {
                    Label("Use full path", systemImage: "arrow.right.circle.fill")
                        .font(.caption.bold())
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
            }

            if !hasAlternative, suggestion != nil {
                Button {
                    appState.respondToToolInstall(.installTool)
                } label: {
                    Label("Install", systemImage: "arrow.down.circle.fill")
                        .font(.caption.bold())
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }

            Button {
                appState.respondToToolInstall(.skip)
            } label: {
                Label("Skip", systemImage: "forward.fill")
                    .font(.caption.bold())
            }
            .buttonStyle(.bordered)

            Spacer()
        }
    }
}
