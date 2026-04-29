import SwiftUI

struct InlinePlanView: View {
    @EnvironmentObject var appState: AppState
    let plan: AgentPlan
    let guardResults: [CommandGuard.GuardResult]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundColor(.accentColor)
                    .font(.caption)

                Text(plan.title)
                    .font(.caption.bold())
                    .foregroundColor(.primary)

                Spacer()

                riskBadge(plan.maxRiskLevel)

                Button {
                    appState.dismissPlan()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }

            Text(plan.explanation)
                .font(.caption2)
                .foregroundColor(.secondary)

            VStack(spacing: 4) {
                ForEach(Array(zip(plan.commands.indices, plan.commands)), id: \.0) { index, command in
                    let result = guardResults.indices.contains(index) ? guardResults[index] : nil
                    let blocked = result?.isBlocked ?? false
                    let risk = result?.classifiedRisk ?? command.riskLevel

                    HStack(spacing: 6) {
                        Image(systemName: risk.icon)
                            .font(.system(size: 8))
                            .foregroundColor(risk.color)

                        Text(command.command)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(blocked ? .secondary : .primary)
                            .strikethrough(blocked)
                            .lineLimit(1)

                        Spacer()

                        Text(command.reason)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: 200, alignment: .trailing)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(NexTheme.bg.opacity(blocked ? 0.3 : 0.5))
                    .cornerRadius(4)
                }
            }

            if plan.hasBlockedCommands {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.red)
                    Text("Some commands blocked for safety")
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                }
            }

            if !plan.finalNote.isEmpty {
                Text(plan.finalNote)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .italic()
            }

            HStack(spacing: 8) {
                Button {
                    appState.approvePlan()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9))
                        Text("Run")
                    }
                    .font(.caption2.bold())
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Copy") {
                    let text = plan.commands
                        .filter { cmd in !guardResults.contains { $0.command == cmd.command && $0.isBlocked } }
                        .map(\.command)
                        .joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                Button("Dismiss") {
                    appState.dismissPlan()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                Spacer()
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .background(.ultraThinMaterial)
    }

    private func riskBadge(_ risk: RiskLevel) -> some View {
        Text(risk.displayName)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(risk.color.opacity(0.15))
            .foregroundColor(risk.color)
            .cornerRadius(3)
    }
}
