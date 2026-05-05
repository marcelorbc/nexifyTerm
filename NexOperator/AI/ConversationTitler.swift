import Foundation

/// Generates short ChatGPT-style titles for conversations using whatever LLM
/// the user already has configured. Decoupled from the agent flow so a
/// titling failure NEVER blocks the user — worst case we keep the tab name.
@MainActor
final class ConversationTitler {
    static let shared = ConversationTitler()

    private let configStore: ConfigStore
    private let titleStore: ConversationTitleStore
    /// Tabs currently being titled, so we don't fire concurrent calls for the
    /// same tab while one is in flight.
    private var inFlight: Set<UUID> = []

    /// After how many new entries we may regenerate a title (topic-drift heuristic).
    private let regenerateAfterDelta = 6
    /// Minimum time between regenerations of the same conversation.
    private let regenerateCooldown: TimeInterval = 60 * 5

    private init(
        configStore: ConfigStore = .shared,
        titleStore: ConversationTitleStore = .shared
    ) {
        self.configStore = configStore
        self.titleStore = titleStore
    }

    /// Decides whether the title should be (re)generated and, if yes, kicks
    /// off a background task. Returns immediately.
    func updateTitleIfNeeded(for tabId: UUID, entries: [HistoryEntry]) {
        guard !inFlight.contains(tabId) else { return }

        let tabEntries = entries.filter { $0.tabId == tabId }
        let agentEntries = tabEntries.filter { $0.type == .agentPlan }
        guard !agentEntries.isEmpty else { return }

        let firstUseful = agentEntries.first { isWorthTitling($0.userInput) }
        guard let seed = firstUseful else { return }

        let existing = titleStore.record(for: tabId)
        if let existing {
            let delta = agentEntries.count - existing.entriesAtGeneration
            let elapsed = -existing.generatedAt.timeIntervalSinceNow
            // Skip regeneration unless conversation has grown meaningfully and cooldown passed.
            if delta < regenerateAfterDelta { return }
            if elapsed < regenerateCooldown { return }
        }

        inFlight.insert(tabId)
        let snapshot = agentEntries.suffix(8).map(\.userInput)
        let totalCount = agentEntries.count
        let provider = configStore.defaultProvider
        let model = configStore.modelForProvider(provider)
        let router = ModelRouter(configStore: configStore)

        Task { [weak self] in
            defer { Task { @MainActor in self?.inFlight.remove(tabId) } }
            do {
                let title = try await Self.requestTitle(
                    seed: seed.userInput,
                    recent: snapshot,
                    router: router,
                    provider: provider,
                    model: model
                )
                guard !title.isEmpty else { return }
                await MainActor.run {
                    self?.titleStore.setTitle(title, for: tabId, entriesAtGeneration: totalCount)
                }
            } catch {
                NexLog.ai.warning("ConversationTitler failed: \(error.localizedDescription)")
            }
        }
    }

    /// Manual override (used by Settings → "Renomear" button if we ever ship it).
    func renameManually(_ title: String, for tabId: UUID, entries: [HistoryEntry]) {
        let count = entries.filter { $0.tabId == tabId && $0.type == .agentPlan }.count
        titleStore.setTitle(title, for: tabId, entriesAtGeneration: count)
    }

    // MARK: - Helpers

    private func isWorthTitling(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return false }
        // Pure-digit follow-ups like "1", "2" don't carry topic info.
        if trimmed.allSatisfy({ $0.isNumber }) { return false }
        return true
    }

    private static func requestTitle(
        seed: String,
        recent: [String],
        router: ModelRouter,
        provider: ProviderType,
        model: String
    ) async throws -> String {
        let llm = router.provider(for: provider, model: model)
        let messages: [[String: String]] = [
            ["role": "system", "content": Self.systemPrompt],
            ["role": "user", "content": Self.userPrompt(seed: seed, recent: recent)]
        ]
        let raw = try await llm.sendRaw(messages: messages)
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let systemPrompt: String = """
    Você gera títulos curtos para conversas — no estilo do ChatGPT.

    REGRAS (siga sem exceção):
    - Idioma: Português Brasileiro.
    - Tamanho: 3 a 6 palavras. Máximo 50 caracteres.
    - Sem aspas, sem ponto final, sem prefixos como "Título:".
    - Sem emoji.
    - Captura o ASSUNTO real (não a ação genérica). Use substantivos concretos quando houver.
    - Evite genéricos como "Conversa com agente", "Pedido do usuário", "Análise".

    Bons exemplos:
      "Análise da pasta Downloads"
      "Conversão de PDFs em HTML"
      "Diagnóstico de uso de CPU"
      "Limpeza de arquivos temporários"
      "Configuração do Ollama"

    Ruins (NÃO use):
      "Resposta ao pedido"
      "Análise"
      "Sobre arquivos"
      "Tarefa concluída"

    SAÍDA: apenas o título, em uma única linha. Nada mais.
    """

    private static func userPrompt(seed: String, recent: [String]) -> String {
        var prompt = "Pedido inicial do usuário:\n\(String(seed.prefix(400)))\n"
        let extras = recent.dropFirst().prefix(4)
        if !extras.isEmpty {
            prompt += "\nMensagens seguintes nesta mesma conversa:\n"
            for (idx, msg) in extras.enumerated() {
                prompt += "\(idx + 2). \(String(msg.prefix(160)))\n"
            }
        }
        prompt += "\nGere o título agora (3-6 palavras, pt-BR, sem aspas, sem ponto final):"
        return prompt
    }
}
