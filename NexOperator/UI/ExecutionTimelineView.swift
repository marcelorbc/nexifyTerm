import SwiftUI
import AppKit

/// View principal da Execution Timeline — lista cronológica de tudo que o
/// agente fez (file actions, shell commands, git ops, etc.) com filtros,
/// detalhes expandidos e botão de rollback quando aplicável.
struct ExecutionTimelineView: View {
    @ObservedObject private var store = ExecutionLogStore.shared
    @State private var selectedSessionId: UUID?
    @State private var filter: TimelineFilter = .all
    @State private var expandedStepId: UUID?
    @State private var rollbackErrorMessage: String?
    @State private var showRollbackError = false

    private enum TimelineFilter: String, CaseIterable, Identifiable {
        case all
        case completed
        case failed
        case dryRun
        case rollbackable

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .all:           return "Tudo"
            case .completed:     return "Sucesso"
            case .failed:        return "Falhas"
            case .dryRun:        return "Dry-run"
            case .rollbackable:  return "Reversíveis"
            }
        }
    }

    var body: some View {
        HSplitView {
            sessionList
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)

            stepsPanel
                .frame(minWidth: 480)
        }
        .frame(minWidth: 800, minHeight: 500)
        .alert("Falha no rollback", isPresented: $showRollbackError, presenting: rollbackErrorMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { msg in
            Text(msg)
        }
    }

    // MARK: - Session list

    private var sessionList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sessões")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    confirmAndClear()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Limpar tudo")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if store.sessions().isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.sessions(), id: \.sessionId) { session in
                            sessionRow(session)
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 40))
                .foregroundColor(.secondary.opacity(0.4))
            Text("Sem execuções ainda")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            Text("Cada ação do agente aparecerá aqui — com riscos, output e botão de rollback quando possível.")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sessionRow(_ session: (sessionId: UUID, latest: Date, prompt: String?)) -> some View {
        let stepsCount = store.steps(for: session.sessionId).count
        let isSelected = selectedSessionId == session.sessionId
        let prompt = session.prompt ?? "(sessão sem prompt)"

        return Button {
            selectedSessionId = session.sessionId
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(prompt)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(NexTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 6) {
                    Text(formatRelative(session.latest))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text("•")
                        .foregroundColor(.secondary)
                    Text("\(stepsCount) step\(stepsCount == 1 ? "" : "s")")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? NexTheme.accentDim : Color.clear)
            .overlay(
                Rectangle()
                    .frame(width: 3)
                    .foregroundColor(isSelected ? NexTheme.accent : Color.clear),
                alignment: .leading
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Steps panel

    private var stepsPanel: some View {
        VStack(spacing: 0) {
            stepsHeader
            Divider()
            stepsList
        }
        .background(NexTheme.bg)
    }

    private var stepsHeader: some View {
        HStack(spacing: 8) {
            if let sessionId = selectedSessionId {
                let steps = store.steps(for: sessionId)
                let prompt = steps.compactMap(\.userPrompt).first ?? "Sessão"
                VStack(alignment: .leading, spacing: 2) {
                    Text(prompt)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text("\(steps.count) ações registradas")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Picker("", selection: $filter) {
                    ForEach(TimelineFilter.allCases) { f in
                        Text(f.displayName).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            } else {
                Text("Selecione uma sessão")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var stepsList: some View {
        Group {
            if let sessionId = selectedSessionId {
                let filtered = filteredSteps(for: sessionId)
                if filtered.isEmpty {
                    Text("Nenhum step com esse filtro.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(filtered) { step in
                                stepCard(step)
                            }
                        }
                        .padding(12)
                    }
                }
            } else {
                Color.clear
            }
        }
    }

    private func filteredSteps(for sessionId: UUID) -> [ExecutionStep] {
        let all = store.steps(for: sessionId).sorted { $0.timestamp < $1.timestamp }
        switch filter {
        case .all:           return all
        case .completed:     return all.filter { $0.status == .completed }
        case .failed:        return all.filter { $0.status == .failed || $0.status == .blocked }
        case .dryRun:        return all.filter { $0.dryRun }
        case .rollbackable:  return all.filter { $0.canRollback }
        }
    }

    // MARK: - Step card

    private func stepCard(_ step: ExecutionStep) -> some View {
        let isExpanded = expandedStepId == step.id
        return VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: step.kind.icon)
                    .font(.system(size: 14))
                    .foregroundColor(step.risk.color)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Label(step.kind.displayName, systemImage: "")
                            .labelStyle(.titleOnly)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text("·")
                            .foregroundColor(.secondary)
                        Label(step.status.displayName, systemImage: step.status.icon)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(step.status.color)
                        Text("·")
                            .foregroundColor(.secondary)
                        Label(step.risk.displayName, systemImage: step.risk.icon)
                            .font(.system(size: 10))
                            .foregroundColor(step.risk.color)
                        if step.dryRun {
                            Text("· dry-run")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.purple)
                        }
                    }
                }
                Spacer()

                if step.canRollback {
                    Button {
                        executeRollback(step)
                    } label: {
                        Label("Reverter", systemImage: "arrow.uturn.backward")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(step.rollback?.summary ?? "Reverter")
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.15)) {
                    expandedStepId = isExpanded ? nil : step.id
                }
            }

            if isExpanded {
                Divider()
                detailsSection(for: step)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(NexTheme.border.opacity(0.4), lineWidth: 0.5)
                )
        )
    }

    @ViewBuilder
    private func detailsSection(for step: ExecutionStep) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !step.detail.isEmpty {
                detailField("Razão", value: step.detail)
            }

            if !step.affectedPaths.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Caminhos afetados")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    ForEach(step.affectedPaths, id: \.self) { path in
                        Text(path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(NexTheme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .textSelection(.enabled)
                    }
                }
            }

            if !step.output.isEmpty {
                detailField("Saída", value: step.output, monospaced: true)
            }

            if let err = step.errorMessage, !err.isEmpty {
                detailField("Erro", value: err, color: .red)
            }

            if let rolledAt = step.rolledBackAt {
                Label("Revertido em \(formatRelative(rolledAt))", systemImage: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.purple)
            }

            HStack(spacing: 8) {
                Spacer()
                Button {
                    copyStepDetails(step)
                } label: {
                    Label("Copiar detalhes", systemImage: "doc.on.doc")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func detailField(_ label: String, value: String, monospaced: Bool = false, color: Color = NexTheme.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 11, design: monospaced ? .monospaced : .default))
                .foregroundColor(color)
                .textSelection(.enabled)
                .lineLimit(8)
        }
    }

    // MARK: - Actions

    private func executeRollback(_ step: ExecutionStep) {
        guard let op = step.rollback else { return }
        do {
            try RollbackStore.shared.execute(op)
            ExecutionLogStore.shared.markRolledBack(id: step.id)
        } catch {
            rollbackErrorMessage = error.localizedDescription
            showRollbackError = true
        }
    }

    private func copyStepDetails(_ step: ExecutionStep) {
        var text = "[\(step.kind.displayName)] \(step.title)\n"
        text += "Status: \(step.status.displayName) · Risco: \(step.risk.displayName)\n"
        if !step.detail.isEmpty { text += "\nRazão: \(step.detail)\n" }
        if !step.affectedPaths.isEmpty {
            text += "\nCaminhos:\n" + step.affectedPaths.joined(separator: "\n") + "\n"
        }
        if !step.output.isEmpty { text += "\nSaída:\n\(step.output)\n" }
        if let err = step.errorMessage { text += "\nErro: \(err)\n" }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func confirmAndClear() {
        let alert = NSAlert()
        alert.messageText = "Limpar timeline"
        alert.informativeText = "Isto remove TODO o histórico de execuções e backups disponíveis para rollback. Continuar?"
        alert.addButton(withTitle: "Limpar")
        alert.addButton(withTitle: "Cancelar")
        if alert.runModal() == .alertFirstButtonReturn {
            store.clearAll()
            selectedSessionId = nil
        }
    }

    private func formatRelative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
