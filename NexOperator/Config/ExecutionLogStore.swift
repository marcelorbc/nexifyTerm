import Foundation
import Combine

/// Persistência da Execution Timeline.
///
/// Steps são gravados em JSON em
/// `~/Library/Application Support/NexOperator/execution_log/sessions/<sessionId>.json`
/// (um arquivo por sessão do agente). Mantém em memória os N steps mais
/// recentes para a UI consumir reativamente.
final class ExecutionLogStore: ObservableObject {

    static let shared = ExecutionLogStore()

    /// Steps em memória, ordenados por timestamp DESC (mais recente primeiro).
    @Published private(set) var steps: [ExecutionStep] = []

    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.nexia.nexifyterm.executionLog", qos: .utility)
    private let memoryLimit = 500

    private var rootDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fileManager.temporaryDirectory
        let dir = appSupport.appendingPathComponent("NexOperator/execution_log/sessions", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {
        loadFromDisk()
    }

    // MARK: - Public API

    /// Adiciona ou atualiza um step (idempotente por id).
    func upsert(_ step: ExecutionStep) {
        DispatchQueue.main.async {
            if let idx = self.steps.firstIndex(where: { $0.id == step.id }) {
                self.steps[idx] = step
            } else {
                self.steps.insert(step, at: 0)
                if self.steps.count > self.memoryLimit {
                    self.steps = Array(self.steps.prefix(self.memoryLimit))
                }
            }
            self.persist(sessionId: step.sessionId)
        }
    }

    /// Append em massa — útil para gravar um plano dry-run inteiro de uma vez.
    func append(_ newSteps: [ExecutionStep]) {
        DispatchQueue.main.async {
            for step in newSteps {
                if let idx = self.steps.firstIndex(where: { $0.id == step.id }) {
                    self.steps[idx] = step
                } else {
                    self.steps.insert(step, at: 0)
                }
            }
            if self.steps.count > self.memoryLimit {
                self.steps = Array(self.steps.prefix(self.memoryLimit))
            }
            // Persiste cada sessão tocada uma única vez.
            let touchedSessions = Set(newSteps.map(\.sessionId))
            for sessionId in touchedSessions { self.persist(sessionId: sessionId) }
        }
    }

    /// Atualiza somente o status de um step existente (in-place).
    func updateStatus(id: UUID, to newStatus: ExecutionStepStatus, output: String? = nil, error: String? = nil) {
        DispatchQueue.main.async {
            guard let idx = self.steps.firstIndex(where: { $0.id == id }) else { return }
            self.steps[idx].status = newStatus
            if let output { self.steps[idx].output = output }
            if let error { self.steps[idx].errorMessage = error }
            self.persist(sessionId: self.steps[idx].sessionId)
        }
    }

    /// Marca um step como revertido.
    func markRolledBack(id: UUID) {
        DispatchQueue.main.async {
            guard let idx = self.steps.firstIndex(where: { $0.id == id }) else { return }
            self.steps[idx].status = .rolledBack
            self.steps[idx].rolledBackAt = Date()
            self.persist(sessionId: self.steps[idx].sessionId)
        }
    }

    /// Steps de uma sessão específica.
    func steps(for sessionId: UUID) -> [ExecutionStep] {
        steps.filter { $0.sessionId == sessionId }
    }

    /// Sessões disponíveis (mais recentes primeiro).
    func sessions() -> [(sessionId: UUID, latest: Date, prompt: String?)] {
        let grouped = Dictionary(grouping: steps) { $0.sessionId }
        return grouped.map { sessionId, sessionSteps in
            let latest = sessionSteps.map(\.timestamp).max() ?? .distantPast
            let prompt = sessionSteps.compactMap(\.userPrompt).first
            return (sessionId, latest, prompt)
        }.sorted { $0.latest > $1.latest }
    }

    /// Limpa registros antigos (em memória e disco).
    func clearAll() {
        DispatchQueue.main.async {
            self.steps = []
            self.queue.async {
                let dir = self.rootDirectory
                if let contents = try? self.fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                    for url in contents {
                        try? self.fileManager.removeItem(at: url)
                    }
                }
            }
        }
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        queue.async {
            let dir = self.rootDirectory
            guard let urls = try? self.fileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { return }

            let sortedURLs = urls.sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return da > db
            }

            var loaded: [ExecutionStep] = []
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            for url in sortedURLs.prefix(50) {  // só as 50 sessões mais recentes
                guard let data = try? Data(contentsOf: url),
                      let steps = try? decoder.decode([ExecutionStep].self, from: data) else { continue }
                loaded.append(contentsOf: steps)
                if loaded.count >= self.memoryLimit { break }
            }

            let final = loaded.sorted { $0.timestamp > $1.timestamp }
            DispatchQueue.main.async {
                self.steps = Array(final.prefix(self.memoryLimit))
            }
        }
    }

    /// Reescreve o arquivo da sessão tocada com TODOS os steps dela em memória.
    private func persist(sessionId: UUID) {
        let sessionSteps = steps.filter { $0.sessionId == sessionId }
        guard !sessionSteps.isEmpty else { return }
        let snapshot = sessionSteps  // value-type copy para o background

        queue.async {
            let url = self.rootDirectory.appendingPathComponent("\(sessionId.uuidString).json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            do {
                let data = try encoder.encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                NexLog.ai.warning("Failed to persist execution log: \(error.localizedDescription)")
            }
        }
    }
}
