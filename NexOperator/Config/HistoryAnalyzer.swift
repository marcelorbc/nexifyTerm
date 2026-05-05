import Foundation
import Combine

/// Inspects the history file produced by `HistoryStore` and emits a curated
/// `HistoryAnalysisReport` highlighting friction points: promises without
/// execution, truncated replies, repeated failures, etc.
///
/// Cached at `~/Library/Application Support/NexOperator/history_analysis.json`.
final class HistoryAnalyzer: ObservableObject {
    static let shared = HistoryAnalyzer()

    @Published private(set) var report: HistoryAnalysisReport = .empty
    @Published private(set) var isAnalyzing: Bool = false

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.nexia.historyanalyzer", qos: .utility)
    private var debounceTask: DispatchWorkItem?

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("NexOperator", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("history_analysis.json")
        loadFromDisk()
    }

    // MARK: - Public API

    /// Triggers a re-analysis after the next quiet window. Safe to call after
    /// every appended entry — the actual work runs at most once every ~3s.
    func scheduleAnalysis(entries: [HistoryEntry], delay: TimeInterval = 3.0) {
        debounceTask?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.analyze(entries: entries)
        }
        debounceTask = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Synchronous analysis — used by manual "Re-analisar" button.
    @discardableResult
    func analyze(entries: [HistoryEntry]) -> HistoryAnalysisReport {
        DispatchQueue.main.async { [weak self] in self?.isAnalyzing = true }
        let result = Self.buildReport(entries: entries)
        DispatchQueue.main.async { [weak self] in
            self?.report = result
            self?.isAnalyzing = false
            self?.persist(result)
        }
        return result
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            report = try decoder.decode(HistoryAnalysisReport.self, from: data)
        } catch {
            NexLog.config.error("Failed to load history_analysis.json: \(error.localizedDescription)")
        }
    }

    private func persist(_ report: HistoryAnalysisReport) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(report)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NexLog.config.error("Failed to save history_analysis.json: \(error.localizedDescription)")
        }
    }

    // MARK: - Detection rules

    private static let promiseMarkers: [String] = [
        "vou fazer", "vou extrair", "vou analisar", "vou listar", "vou processar",
        "vou gerar", "vou criar", "vou rodar", "vou executar", "vou ler",
        "vou te entregar", "vou te mostrar", "vou retornar", "vou abrir",
        "farei", "em seguida", "assim que terminar", "aguarde enquanto",
        "em breve", "em instantes", "vou continuar"
    ]

    private static let truncationMarkers: [String] = [
        "truncad", "cortad", "limite atingido", "sem conexão",
        "limite de \\d+ passos", "máximo de \\d+ rounds"
    ]

    private static let missingContextMarkers: [String] = [
        "não tenho a lista",
        "não tenho acesso",
        "não consigo identificar",
        "preciso que você confirme",
        "cole a lista novamente",
        "não tenho contexto",
        "não sei a qual"
    ]

    private static let planFollowupGapMarkers: [String] = [
        "ainda não foi", "não foi gerado", "não foi executado",
        "não foi possível", "ainda não dá"
    ]

    // MARK: - Report construction

    private static func buildReport(entries: [HistoryEntry]) -> HistoryAnalysisReport {
        let agentEntries = entries.filter { $0.type == .agentPlan }
        guard !agentEntries.isEmpty else {
            return HistoryAnalysisReport(
                generatedAt: Date(),
                totalEntries: entries.count,
                analyzedEntries: 0,
                insights: [],
                flaggedEntries: [:],
                summary: HistoryAnalysisReport.HealthSummary(
                    successRate: 0,
                    avgCommandsPerTurn: 0,
                    promiseRate: 0,
                    truncationRate: 0,
                    topProblemKind: nil
                )
            )
        }

        var insights: [HistoryInsight] = []
        var flagged: [String: [String]] = [:]

        // 1) Promise without command
        let promises = agentEntries.filter {
            $0.commands.isEmpty && containsAny($0.summary, of: promiseMarkers)
        }
        if !promises.isEmpty {
            insights.append(insight(
                kind: .promiseWithoutCommand,
                severity: promises.count >= 3 ? .critical : .warning,
                title: "\(promises.count) resposta(s) prometendo sem executar",
                detail: "O agente disse \"vou fazer X\" sem incluir comando. " +
                        "Exemplo: \"\(promises.last?.userInput.prefix(60) ?? "")\".",
                from: promises
            ))
            for e in promises { flag(&flagged, e.id, kind: .promiseWithoutCommand) }
        }

        // 2) Truncated replies
        let truncated = agentEntries.filter {
            containsAny($0.summary, of: truncationMarkers, regex: true)
        }
        if !truncated.isEmpty {
            insights.append(insight(
                kind: .truncatedReply,
                severity: .warning,
                title: "\(truncated.count) turno(s) com saída truncada",
                detail: "O resumo menciona truncamento ou limite atingido. " +
                        "Considere aumentar `maxSteps`/`maxRounds` ou pedir paginação.",
                from: truncated
            ))
            for e in truncated { flag(&flagged, e.id, kind: .truncatedReply) }
        }

        // 3) Missing context (short msg + no commands + "não tenho ...")
        let missingCtx = agentEntries.filter {
            $0.commands.isEmpty
                && containsAny($0.summary, of: missingContextMarkers)
                && $0.userInput.count < 30
        }
        if !missingCtx.isEmpty {
            insights.append(insight(
                kind: .missingContext,
                severity: missingCtx.count >= 2 ? .critical : .warning,
                title: "\(missingCtx.count) turno(s) com perda de contexto",
                detail: "Mensagens curtas (\"1\", \"esse\", \"continue\") em que o agente disse não " +
                        "ter contexto. Esse padrão indica histórico de aba não está chegando ao prompt.",
                from: missingCtx
            ))
            for e in missingCtx { flag(&flagged, e.id, kind: .missingContext) }
        }

        // 4) Repeated command failures
        let failedSteps: [(entryId: UUID, command: String, stderr: String)] = agentEntries.flatMap { entry -> [(UUID, String, String)] in
            (entry.stepOutputs ?? [])
                .filter { $0.exitCode != 0 }
                .map { (entry.id, normalizeCmd($0.command), String($0.stderr.prefix(120))) }
        }
        let cmdFailureCounts = Dictionary(grouping: failedSteps, by: \.command)
            .filter { $1.count >= 2 }
        if !cmdFailureCounts.isEmpty {
            for (cmd, occurrences) in cmdFailureCounts.prefix(5) {
                let ids = occurrences.map(\.entryId)
                let uniqueIds = Array(Set(ids))
                insights.append(insight(
                    kind: .repeatedFailure,
                    severity: .warning,
                    title: "Comando `\(cmd)` falhou \(occurrences.count)x",
                    detail: "Esse comando vem falhando em múltiplos turnos. Provavelmente vale " +
                            "uma alternativa, instalar dependência, ou ensinar isso como aprendizado.",
                    occurrences: occurrences.count,
                    evidenceIds: uniqueIds,
                    firstSeen: agentEntries.first(where: { uniqueIds.contains($0.id) })?.timestamp ?? Date(),
                    lastSeen: agentEntries.last(where: { uniqueIds.contains($0.id) })?.timestamp ?? Date()
                ))
                for id in uniqueIds {
                    flag(&flagged, id, kind: .repeatedFailure)
                }
            }
        }

        // 5) Long conversations (heuristic: many rounds — summary mentions "X rounds")
        let longRoundsRegex = try? NSRegularExpression(pattern: "após (\\d+) rounds")
        let longConversations = agentEntries.filter { entry -> Bool in
            guard let summary = entry.summary, let rx = longRoundsRegex else { return false }
            let range = NSRange(summary.startIndex..., in: summary)
            guard let match = rx.firstMatch(in: summary, range: range),
                  match.numberOfRanges >= 2,
                  let r = Range(match.range(at: 1), in: summary),
                  let n = Int(summary[r]) else { return false }
            return n >= 4
        }
        if !longConversations.isEmpty {
            insights.append(insight(
                kind: .longConversation,
                severity: .info,
                title: "\(longConversations.count) tarefa(s) com 4+ rounds",
                detail: "Tarefas que demoraram muitos rounds para fechar. Geralmente há informação " +
                        "que poderia estar no perfil do sistema ou em aprendizados, evitando o ping-pong.",
                from: longConversations
            ))
            for e in longConversations { flag(&flagged, e.id, kind: .longConversation) }
        }

        // 6) Tool missing
        let missingToolEntries = agentEntries.filter { entry in
            (entry.stepOutputs ?? []).contains { step in
                let s = (step.stderr + " " + step.stdout).lowercased()
                return s.contains("command not found") || s.contains("not installed")
            }
        }
        if !missingToolEntries.isEmpty {
            insights.append(insight(
                kind: .toolMissing,
                severity: .warning,
                title: "\(missingToolEntries.count) turno(s) com ferramenta ausente",
                detail: "Comandos retornaram \"command not found\". Vale instalar via Homebrew, " +
                        "ou registrar como aprendizado para o agente já propor a alternativa.",
                from: missingToolEntries
            ))
            for e in missingToolEntries { flag(&flagged, e.id, kind: .toolMissing) }
        }

        // 7) Plan executed but summary still negates ("ainda não foi feito")
        let followupGaps = agentEntries.filter {
            !$0.commands.isEmpty && containsAny($0.summary, of: planFollowupGapMarkers)
        }
        if !followupGaps.isEmpty {
            insights.append(insight(
                kind: .planFollowupGap,
                severity: .warning,
                title: "\(followupGaps.count) plano(s) executado(s) mas summary negou conclusão",
                detail: "Comandos rodaram mas o resumo final disse \"ainda não foi feito\". " +
                        "Provavelmente o follow-up perdeu o contexto dos resultados anteriores.",
                from: followupGaps
            ))
            for e in followupGaps { flag(&flagged, e.id, kind: .planFollowupGap) }
        }

        let summary = computeHealth(agentEntries: agentEntries, insights: insights)

        return HistoryAnalysisReport(
            generatedAt: Date(),
            totalEntries: entries.count,
            analyzedEntries: agentEntries.count,
            insights: insights.sorted { $0.severity > $1.severity },
            flaggedEntries: flagged,
            summary: summary
        )
    }

    private static func computeHealth(
        agentEntries: [HistoryEntry],
        insights: [HistoryInsight]
    ) -> HistoryAnalysisReport.HealthSummary {
        let total = Double(agentEntries.count)
        let successCount = agentEntries.filter { entry in
            !(entry.summary ?? "").lowercased().hasPrefix("erro:")
                && !insights.contains { $0.evidenceIds.contains(entry.id) && $0.severity == .critical }
        }.count
        let avgCmds = agentEntries.map { Double($0.commands.count) }.reduce(0, +) / max(total, 1)
        let promiseCount = Double(insights.first(where: { $0.kind == .promiseWithoutCommand })?.occurrences ?? 0)
        let truncCount = Double(insights.first(where: { $0.kind == .truncatedReply })?.occurrences ?? 0)
        let top = insights.max { lhs, rhs in
            (lhs.severity, lhs.occurrences) < (rhs.severity, rhs.occurrences)
        }
        return .init(
            successRate: total == 0 ? 0 : Double(successCount) / total,
            avgCommandsPerTurn: avgCmds,
            promiseRate: total == 0 ? 0 : promiseCount / total,
            truncationRate: total == 0 ? 0 : truncCount / total,
            topProblemKind: top?.kind.rawValue
        )
    }

    // MARK: - Helpers

    private static func insight(
        kind: HistoryInsight.Kind,
        severity: HistoryInsight.Severity,
        title: String,
        detail: String,
        from entries: [HistoryEntry]
    ) -> HistoryInsight {
        let ids = entries.map(\.id)
        let times = entries.map(\.timestamp)
        return HistoryInsight(
            id: UUID(),
            kind: kind,
            severity: severity,
            title: title,
            detail: detail,
            evidenceIds: ids,
            occurrences: entries.count,
            firstSeen: times.min() ?? Date(),
            lastSeen: times.max() ?? Date()
        )
    }

    private static func insight(
        kind: HistoryInsight.Kind,
        severity: HistoryInsight.Severity,
        title: String,
        detail: String,
        occurrences: Int,
        evidenceIds: [UUID],
        firstSeen: Date,
        lastSeen: Date
    ) -> HistoryInsight {
        HistoryInsight(
            id: UUID(),
            kind: kind,
            severity: severity,
            title: title,
            detail: detail,
            evidenceIds: evidenceIds,
            occurrences: occurrences,
            firstSeen: firstSeen,
            lastSeen: lastSeen
        )
    }

    private static func containsAny(_ text: String?, of markers: [String], regex: Bool = false) -> Bool {
        guard let text else { return false }
        let lowered = text.lowercased()
        if regex {
            for m in markers {
                if lowered.range(of: m, options: .regularExpression) != nil { return true }
            }
            return false
        }
        for m in markers where lowered.contains(m) { return true }
        return false
    }

    private static func normalizeCmd(_ cmd: String) -> String {
        let head = cmd.components(separatedBy: .whitespacesAndNewlines).first ?? cmd
        return String(head.prefix(60))
    }

    private static func flag(_ flagged: inout [String: [String]], _ id: UUID, kind: HistoryInsight.Kind) {
        let key = id.uuidString
        var existing = flagged[key] ?? []
        existing.append(kind.rawValue)
        flagged[key] = existing
    }

    // Convenience: return the top N actionable insights so the LLM prompt
    // (and the UI) can show the most pressing items.
    func topActionable(limit: Int = 3) -> [HistoryInsight] {
        report.insights
            .filter { $0.severity != .info }
            .sorted { $0.severity > $1.severity }
            .prefix(limit)
            .map { $0 }
    }
}
