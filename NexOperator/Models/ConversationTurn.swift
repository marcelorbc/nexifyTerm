import Foundation

/// A single turn (user message + agent response + outputs) within a tab's conversation.
/// Used to give the LLM continuity across multiple user messages in the same tab,
/// so the user does not need to restate context every prompt.
struct ConversationTurn: Identifiable {
    let id: UUID
    let timestamp: Date
    let userMessage: String
    let planTitle: String
    let planExplanation: String
    let summary: String
    let stepBriefs: [StepBrief]
    let succeeded: Bool
    /// Compact text representation of any RichOutput rendered for the user
    /// (table rows, metrics, html). Captured because the visible answer to the
    /// user often lives there — not in stdout — and follow-up references like
    /// "1", "o primeiro item", "aquele PDF" must resolve against it.
    let richOutputDigest: String

    struct StepBrief {
        let command: String
        let exitCode: Int32
        let stdoutHead: String
        let stderrHead: String

        var succeeded: Bool { exitCode == 0 }
    }

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        userMessage: String,
        planTitle: String,
        planExplanation: String,
        summary: String,
        stepBriefs: [StepBrief],
        succeeded: Bool,
        richOutputDigest: String = ""
    ) {
        self.id = id
        self.timestamp = timestamp
        self.userMessage = userMessage
        self.planTitle = planTitle
        self.planExplanation = planExplanation
        self.summary = summary
        self.stepBriefs = stepBriefs
        self.succeeded = succeeded
        self.richOutputDigest = richOutputDigest
    }

    static func from(
        userMessage: String,
        plan: AgentPlan?,
        results: [StepResult],
        summary: String,
        richOutput: RichOutput? = nil,
        succeeded: Bool
    ) -> ConversationTurn {
        // Larger heads so list-style outputs (ls, find, ps...) survive into the
        // next turn — a 600-char cap silently dropped enumerations and broke
        // follow-ups like "exclua o item 1".
        let briefs = results.prefix(8).map { r in
            StepBrief(
                command: String(r.command.prefix(280)),
                exitCode: r.output.exitCode,
                stdoutHead: String(r.output.stdout.prefix(2500)),
                stderrHead: String(r.output.stderr.prefix(800))
            )
        }
        return ConversationTurn(
            userMessage: userMessage,
            planTitle: plan?.title ?? "",
            planExplanation: String((plan?.explanation ?? "").prefix(600)),
            summary: String(summary.prefix(1200)),
            stepBriefs: Array(briefs),
            succeeded: succeeded,
            richOutputDigest: digest(of: richOutput)
        )
    }

    /// Renders an LLM-friendly summary of any RichOutput attached to this turn.
    /// Tables become numbered rows so the model can resolve positional references
    /// like "exclua o item 3" or "abra o segundo".
    private static func digest(of rich: RichOutput?) -> String {
        guard let rich else { return "" }
        var out = ""

        if let metrics = rich.metrics, !metrics.isEmpty {
            out += "Métricas: "
            out += metrics.prefix(10).map { "\($0.label)=\($0.value)" }.joined(separator: ", ")
            out += "\n"
        }

        if let table = rich.table, !table.rows.isEmpty {
            if let title = table.title { out += "Tabela: \(title)\n" }
            if !table.headers.isEmpty {
                out += "Colunas: " + table.headers.joined(separator: " | ") + "\n"
            }
            for (idx, row) in table.rows.prefix(40).enumerated() {
                let joined = row.joined(separator: " | ")
                out += "\(idx + 1). \(joined)\n"
            }
            if table.rows.count > 40 {
                out += "(+ \(table.rows.count - 40) linha(s) omitida(s))\n"
            }
        }

        if let chart = rich.chart, !chart.items.isEmpty {
            out += "Gráfico (\(chart.type))"
            if let t = chart.title { out += ": \(t)" }
            out += "\n"
            for (idx, item) in chart.items.prefix(20).enumerated() {
                out += "\(idx + 1). \(item.label)=\(item.value)\n"
            }
        }

        if let html = rich.html, !html.isEmpty {
            let stripped = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            out += "Conteúdo: " + String(stripped.prefix(800)) + "\n"
        }

        if let url = rich.openUrl, !url.isEmpty {
            out += "URL aberta: \(url)\n"
        }

        return String(out.prefix(2500))
    }
}
