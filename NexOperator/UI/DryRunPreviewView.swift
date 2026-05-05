import SwiftUI

/// Preview rico de um `ExecutionPlan` antes da execução real.
/// Mostra cards agrupados por categoria, paths afetados e badge de risco
/// dominante. Botões: **Executar**, **Cancelar**.
struct DryRunPreviewView: View {
    let plan: ExecutionPlan
    let onApprove: () -> Void
    let onCancel: () -> Void

    @State private var expandedKinds: Set<ExecutionStepKind> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 540)
        .background(NexTheme.bg)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "eye.circle.fill")
                .font(.system(size: 28))
                .foregroundColor(.purple)

            VStack(alignment: .leading, spacing: 4) {
                Text("Pré-visualização (Dry Run)")
                    .font(.system(size: 14, weight: .semibold))
                Text(plan.userPrompt)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(3)
            }

            Spacer()

            riskBadge
        }
        .padding(16)
    }

    private var riskBadge: some View {
        let risk = plan.maxRisk
        return Label(risk.displayName, systemImage: risk.icon)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(risk.color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(risk.color.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(risk.color.opacity(0.4), lineWidth: 0.5)
            )
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                summaryCards

                ForEach(plan.stepsByKind, id: \.0.rawValue) { kind, steps in
                    sectionCard(kind: kind, steps: steps)
                }

                if !plan.allAffectedPaths.isEmpty {
                    affectedPathsCard
                }
            }
            .padding(16)
        }
    }

    private var summaryCards: some View {
        HStack(spacing: 8) {
            summaryCard(
                title: "Total de ações",
                value: "\(plan.steps.count)",
                icon: "list.bullet.rectangle",
                color: .accentColor
            )
            summaryCard(
                title: "Caminhos afetados",
                value: "\(plan.allAffectedPaths.count)",
                icon: "doc.text",
                color: .blue
            )
            summaryCard(
                title: "Reversíveis",
                value: "\(plan.steps.filter { $0.kind.supportsRollback }.count)",
                icon: "arrow.uturn.backward.circle",
                color: .green
            )
        }
    }

    private func summaryCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(color)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            }
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(NexTheme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(color.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(color.opacity(0.2), lineWidth: 0.5)
                )
        )
    }

    private func sectionCard(kind: ExecutionStepKind, steps: [ExecutionStep]) -> some View {
        let isExpanded = expandedKinds.contains(kind)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    if isExpanded { expandedKinds.remove(kind) } else { expandedKinds.insert(kind) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: kind.icon)
                        .font(.system(size: 13))
                        .foregroundColor(.accentColor)
                    Text(kind.displayName)
                        .font(.system(size: 12, weight: .semibold))
                    Text("(\(steps.count))")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(steps) { step in
                        stepRow(step)
                    }
                }
                .padding(10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.4))
        )
    }

    private func stepRow(_ step: ExecutionStep) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(step.risk.color.opacity(0.6))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                if !step.detail.isEmpty {
                    Text(step.detail)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Text(step.risk.displayName)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(step.risk.color)
        }
    }

    private var affectedPathsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Caminhos afetados (\(plan.allAffectedPaths.count))", systemImage: "doc.text")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(plan.allAffectedPaths.prefix(15), id: \.self) { path in
                        Text(path)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(NexTheme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .textSelection(.enabled)
                    }
                    if plan.allAffectedPaths.count > 15 {
                        Text("… e mais \(plan.allAffectedPaths.count - 15)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(maxHeight: 100)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.4))
        )
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Label("Nada será modificado até você aprovar", systemImage: "lock.shield")
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            Spacer()

            Button("Cancelar", role: .cancel) {
                onCancel()
            }
            .keyboardShortcut(.cancelAction)

            Button {
                onApprove()
            } label: {
                Label("Executar", systemImage: "play.fill")
                    .font(.system(size: 12, weight: .semibold))
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
        }
        .padding(16)
    }
}
