import Foundation

/// Builds the personalization blocks (custom instructions + saved memories +
/// personality style) that are injected into every LLM call.
///
/// This is intentionally a small, pure helper with no side effects. The actual
/// memory store and config store are read at build-time so the result is a
/// stable string the prompt layer can append.
enum PersonalizationContext {

    struct Snapshot {
        let style: PersonalityStyle
        let customInstructions: String
        let memories: [UserMemory]
        let memoryEnabled: Bool
        let memoryAutoCapture: Bool
        let systemProfile: SystemProfile?
        let historyInsights: [HistoryInsight]
    }

    /// Captures the current personalization config + memories. Centralized so
    /// the rest of the codebase doesn't pull from singletons directly.
    static func currentSnapshot() -> Snapshot {
        let config = ConfigStore.shared
        let memories = config.memoryEnabled ? MemoryStore.shared.all() : []
        let profile: SystemProfile? = {
            guard config.systemProfileEnabled else { return nil }
            let candidate = SystemProfileService.shared.currentProfile
            return candidate.isEmpty ? nil : candidate
        }()
        let insights = HistoryAnalyzer.shared.topActionable(limit: 3)
        return Snapshot(
            style: config.personalityStyle,
            customInstructions: config.customInstructions,
            memories: memories,
            memoryEnabled: config.memoryEnabled,
            memoryAutoCapture: config.memoryAutoCapture,
            systemProfile: profile,
            historyInsights: insights
        )
    }

    /// Renders the personalization block for the SYSTEM prompt. This block is
    /// stable across rounds of the same conversation.
    static func systemBlock(_ snapshot: Snapshot = currentSnapshot()) -> String {
        var block = ""

        block += "=== PERSONA E ESTILO ===\n"
        block += snapshot.style.promptInstruction + "\n"
        block += "(Estilo escolhido pelo usuário: \(snapshot.style.label))\n\n"

        let trimmedInstructions = snapshot.customInstructions
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedInstructions.isEmpty {
            block += "=== INSTRUÇÕES PERSONALIZADAS DO USUÁRIO ===\n"
            block += trimmedInstructions + "\n"
            block += "Estas instruções têm precedência sobre escolhas de formato/estilo "
            block += "padrão, exceto quando conflitarem com regras de segurança.\n\n"
        }

        let profile = systemProfileBlock(snapshot)
        if !profile.isEmpty {
            block += profile
        }

        let insights = historyInsightsBlock(snapshot)
        if !insights.isEmpty {
            block += insights
        }

        if snapshot.memoryAutoCapture {
            block += memoryCaptureProtocolBlock()
        }

        return block
    }

    /// Surfaces recent behavioral patterns flagged by `HistoryAnalyzer` so the
    /// LLM gets a small, actionable nudge to avoid repeating the same mistakes.
    static func historyInsightsBlock(_ snapshot: Snapshot) -> String {
        guard !snapshot.historyInsights.isEmpty else { return "" }

        var block = "=== APRENDIZADOS DO HISTÓRICO (evite repetir estes padrões) ===\n"
        block += "A análise das suas últimas interações nesta máquina identificou os padrões abaixo. "
        block += "Internalize-os antes de responder.\n\n"

        for insight in snapshot.historyInsights {
            block += "- [\(insight.severity.label.uppercased())] \(insight.kind.label) "
            block += "(\(insight.occurrences)x): \(insight.title)\n"
            block += "  Como evitar: \(insight.detail)\n"
        }

        block += "=== FIM APRENDIZADOS ===\n\n"
        return block
    }

    /// Renders the cached system profile (hardware, OS, installed tools) so the
    /// agent can plan without redundant `which`/`--version` probing.
    static func systemProfileBlock(_ snapshot: Snapshot) -> String {
        guard let profile = snapshot.systemProfile, !profile.isEmpty else { return "" }

        var block = "=== PERFIL DO SISTEMA (use para planejar — evite re-checar o que já está aqui) ===\n"

        let hw = profile.hardware
        block += "[Hardware] "
        block += "\(hw.chip.isEmpty ? hw.model : hw.chip)"
        if !hw.architecture.isEmpty { block += " · \(hw.architecture)" }
        if hw.physicalCores > 0 { block += " · \(hw.physicalCores)P/\(hw.logicalCores)L cores" }
        if hw.memoryGB > 0 { block += " · \(hw.memoryGB) GB RAM" }
        if !hw.hostname.isEmpty { block += " · host=\(hw.hostname)" }
        block += "\n"

        let os = profile.os
        block += "[OS] \(os.name) \(os.version)"
        if !os.build.isEmpty { block += " (build \(os.build))" }
        block += " · locale=\(os.locale) · tz=\(os.timezone)\n"

        let env = profile.shellEnv
        block += "[Shell] \(env.defaultShell)"
        if env.pathHasHomebrew { block += " · Homebrew no PATH" }
        if let editor = env.defaultEditor { block += " · EDITOR=\(editor)" }
        block += "\n"

        if !profile.packageManagers.isEmpty {
            for pm in profile.packageManagers {
                var line = "[\(pm.name)]"
                if let v = pm.version { line += " v\(v)" }
                line += " · \(pm.packagesCount) pacote(s)"
                if !pm.topPackages.isEmpty {
                    let preview = pm.topPackages.prefix(20).joined(separator: ", ")
                    line += " · ex: \(preview)"
                }
                block += line + "\n"
            }
        }

        let installed = profile.installedTools
        if !installed.isEmpty {
            block += "[Ferramentas instaladas]\n"
            let grouped = Dictionary(grouping: installed, by: { $0.category })
            for category in SystemProfile.DetectedTool.Category.allCases {
                guard let items = grouped[category], !items.isEmpty else { continue }
                let descriptions = items.map { tool -> String in
                    if let v = tool.version, !v.isEmpty {
                        return "\(tool.name)=\(v)"
                    }
                    return tool.name
                }.joined(separator: ", ")
                block += "  - \(category.label): \(descriptions)\n"
            }
        }

        let missing = profile.tools.filter { !$0.installed }
        if !missing.isEmpty, missing.count <= 12 {
            let names = missing.map(\.name).joined(separator: ", ")
            block += "[Não instalado] \(names)\n"
        }

        block += "Coletado em: \(formattedDate(profile.collectedAt))\n"
        block += "=== FIM PERFIL DO SISTEMA ===\n\n"
        return block
    }

    /// Renders the saved-memories block for the USER prompt. Kept separate from
    /// the system block because memories evolve across rounds and we want the
    /// LLM to treat them as recent context, not policy.
    static func memoryBlock(_ snapshot: Snapshot = currentSnapshot()) -> String {
        guard snapshot.memoryEnabled, !snapshot.memories.isEmpty else { return "" }

        let pinned = snapshot.memories.filter { $0.pinned }
        let recent = snapshot.memories.filter { !$0.pinned }.prefix(20)
        let combined = pinned + recent
        guard !combined.isEmpty else { return "" }

        var block = "=== MEMÓRIAS SOBRE O USUÁRIO (use para personalizar a resposta) ===\n"
        block += "Estas são informações persistentes coletadas em conversas anteriores. "
        block += "Use-as como contexto, mas NÃO as repita textualmente para o usuário a "
        block += "menos que ele pergunte o que você lembra.\n\n"

        for memory in combined {
            let pin = memory.pinned ? "📌 " : ""
            let cat = memory.category.label
            let id = memory.id.uuidString
            block += "- [\(cat)] \(pin)\(memory.content) (id: \(id))\n"
        }
        block += "=== FIM MEMÓRIAS ===\n\n"
        return block
    }

    private static func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// Tells the LLM how to emit memory updates in its JSON response so the app
    /// can persist them (auto-capture).
    private static func memoryCaptureProtocolBlock() -> String {
        """
        === PROTOCOLO DE MEMÓRIA (auto-capture) ===
        Quando identificar um fato durável e útil sobre o usuário (preferência \
        recorrente, projeto, identidade, stack, regra que ele quer sempre seguir, \
        ou pedido explícito como "lembre que..."), inclua um campo \
        `memoryUpdates` no JSON final:

        "memoryUpdates": [
          { "action": "add",    "category": "preference|project|identity|skill|fact", "content": "Texto curto e claro" },
          { "action": "update", "id": "<uuid existente>", "content": "Novo texto" },
          { "action": "remove", "id": "<uuid existente>" }
        ]

        Regras de captura (siga rigorosamente):
        - Só capture o que for ESTÁVEL, não apague algo do contexto temporário da conversa.
        - Não capture dados sensíveis (senhas, tokens, CPF, dados de cartão).
        - Se o usuário pedir "esqueça que...", emita uma ação `remove`.
        - Se o usuário corrigir uma memória anterior, emita `update` com o id existente.
        - Mantenha o `content` curto (≤ 200 caracteres), em pt-BR, sem aspas externas.
        - O campo `memoryUpdates` é OPCIONAL — só emita quando realmente houver algo \
          a salvar/alterar/remover.
        === FIM PROTOCOLO MEMÓRIA ===

        """
    }
}
