import SwiftUI

struct PlanPreviewView: View {
    @EnvironmentObject var appState: AppState
    let plan: AgentPlan
    let guardResults: [CommandGuard.GuardResult]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            scrollContent
            Divider()
            actionBar
        }
        .background(NexTheme.bg)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundColor(.accentColor)
                .font(.caption)
            Text("Plano do Agente")
                .font(.caption.bold())
                .foregroundColor(NexTheme.textPrimary)

            Spacer()

            riskBadge(plan.maxRiskLevel)

            Text("\(plan.commands.count) comandos")
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            Button { appState.dismissPlanPreview() } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .background(.ultraThinMaterial)
    }

    private var scrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(plan.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(plan.explanation)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Comandos a executar:")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)

                    ForEach(Array(zip(plan.commands.indices, plan.commands)), id: \.0) { index, command in
                        let result = guardResults.indices.contains(index) ? guardResults[index] : nil
                        let blocked = result?.isBlocked ?? false
                        let risk = result?.classifiedRisk ?? command.riskLevel

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text("\(index + 1)")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .frame(width: 16)

                                Image(systemName: risk.icon)
                                    .font(.system(size: 9))
                                    .foregroundColor(risk.color)

                                Text(command.command)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(blocked ? .secondary : .primary)
                                    .strikethrough(blocked)
                                    .textSelection(.enabled)

                                Spacer()

                                HStack(spacing: 3) {
                                    Text(risk.displayName)
                                        .font(.system(size: 9, weight: .medium))
                                }
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(risk.color.opacity(0.1))
                                .foregroundColor(risk.color)
                                .cornerRadius(3)
                            }

                            Text(command.reason)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .padding(.leading, 22)

                            if blocked {
                                HStack(spacing: 3) {
                                    Image(systemName: "xmark.octagon.fill")
                                        .font(.system(size: 8))
                                    Text("Bloqueado pela política de segurança")
                                        .font(.system(size: 9))
                                }
                                .foregroundColor(.red.opacity(0.8))
                                .padding(.leading, 22)
                            }
                        }
                        .padding(8)
                        .background(NexTheme.surface.opacity(blocked ? 0.3 : 0.6))
                        .cornerRadius(6)
                    }
                }

                if !plan.finalNote.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Observação:")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                        Text(plan.finalNote)
                            .font(.caption)
                            .foregroundColor(.primary.opacity(0.8))
                            .italic()
                    }
                    .padding(8)
                    .background(Color.blue.opacity(0.04))
                    .cornerRadius(6)
                }
            }
            .padding(12)
        }
        .frame(maxHeight: 300)
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            let blockedCount = guardResults.filter(\.isBlocked).count
            if blockedCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .font(.system(size: 9))
                    Text("\(blockedCount) bloqueado(s)")
                        .font(.system(size: 10))
                }
                .foregroundColor(.red)
            }

            Spacer()

            Button("Copiar") {
                let text = plan.commands
                    .filter { cmd in !guardResults.contains { $0.command == cmd.command && $0.isBlocked } }
                    .map(\.command)
                    .joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("Cancelar") {
                appState.dismissPlanPreview()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                appState.approvePlanPreview()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9))
                    Text("Executar")
                }
                .font(.caption.bold())
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(NexTheme.surface)
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
