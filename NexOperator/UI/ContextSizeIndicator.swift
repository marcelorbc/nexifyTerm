import SwiftUI

/// Compact context-window usage chip, à la Cursor / Claude.
/// Shows fill bar + token count and a detailed tooltip with the breakdown.
struct ContextSizeIndicator: View {
    let breakdown: ContextEstimator.Breakdown

    private var fill: Double {
        min(max(breakdown.fillRatio, 0), 1)
    }

    private var color: Color {
        if breakdown.fillRatio >= 1.0  { return .red }
        if breakdown.isCritical        { return .red }
        if breakdown.isWarning         { return .orange }
        if breakdown.fillRatio >= 0.50 { return .yellow }
        return .green
    }

    private var percentLabel: String {
        let pct = Int((breakdown.fillRatio * 100).rounded())
        return "\(pct)%"
    }

    private var tokensLabel: String {
        let used = ContextEstimator.formatTokens(breakdown.usedTokens)
        let total = ContextEstimator.formatTokens(breakdown.contextWindow)
        return "\(used)/\(total)"
    }

    var body: some View {
        HStack(spacing: 5) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 28, height: 5)
                Capsule()
                    .fill(color)
                    .frame(width: 28 * fill, height: 5)
            }

            Text(tokensLabel)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.08))
        )
        .help(tooltipText)
        .accessibilityLabel("Contexto utilizado: \(percentLabel)")
    }

    private var tooltipText: String {
        let b = breakdown
        let lines = [
            "Janela: \(ContextEstimator.formatTokens(b.contextWindow)) tokens",
            "Usado: \(ContextEstimator.formatTokens(b.usedTokens)) (\(percentLabel))",
            "",
            "Detalhe:",
            "• Sistema: \(ContextEstimator.formatTokens(b.systemPromptTokens))",
            "• Histórico da aba: \(ContextEstimator.formatTokens(b.conversationTokens))",
            "• Anexos: \(ContextEstimator.formatTokens(b.attachmentTokens))",
            "• Terminal: \(ContextEstimator.formatTokens(b.terminalContextTokens))",
            "• Sua mensagem: \(ContextEstimator.formatTokens(b.userInputTokens))",
            "• Reserva p/ resposta: \(ContextEstimator.formatTokens(b.reservedOutputTokens))",
        ]
        let warning: String
        if b.fillRatio >= 1.0 {
            warning = "\n\n⚠️ Contexto cheio. Considere limpar o histórico ou usar um modelo com janela maior."
        } else if b.isCritical {
            warning = "\n\n⚠️ Próximo do limite. Mensagens longas podem ser truncadas."
        } else if b.isWarning {
            warning = "\n\nAtenção: histórico crescendo. Limpe se notar perda de qualidade."
        } else {
            warning = ""
        }
        return lines.joined(separator: "\n") + warning
    }
}
