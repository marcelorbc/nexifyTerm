import Foundation
import Combine

/// Tracks an LLM-generated short title for each conversation (one per tabId),
/// in the spirit of ChatGPT's auto-generated chat titles.
/// Persisted to `~/Library/Application Support/NexOperator/conversation_titles.json`.
final class ConversationTitleStore: ObservableObject {
    static let shared = ConversationTitleStore()

    /// Snapshot of the per-tab title state. We persist `entriesAtGeneration`
    /// so we can decide later whether the conversation grew enough to be
    /// worth re-titling (topic drift heuristic).
    struct Record: Codable, Equatable {
        var title: String
        var generatedAt: Date
        var entriesAtGeneration: Int
    }

    @Published private(set) var titles: [UUID: Record] = [:]

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.nexia.conversationtitles", qos: .utility)

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("NexOperator", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("conversation_titles.json")
        loadFromDisk()
    }

    // MARK: - Reads

    func title(for tabId: UUID) -> String? {
        titles[tabId]?.title
    }

    func record(for tabId: UUID) -> Record? {
        titles[tabId]
    }

    // MARK: - Writes

    func setTitle(_ title: String, for tabId: UUID, entriesAtGeneration: Int) {
        let cleaned = sanitize(title)
        guard !cleaned.isEmpty else { return }
        let record = Record(
            title: cleaned,
            generatedAt: Date(),
            entriesAtGeneration: entriesAtGeneration
        )
        DispatchQueue.main.async { [weak self] in
            self?.titles[tabId] = record
            self?.persist()
        }
    }

    func clear(tabId: UUID) {
        DispatchQueue.main.async { [weak self] in
            self?.titles.removeValue(forKey: tabId)
            self?.persist()
        }
    }

    func clearAll() {
        DispatchQueue.main.async { [weak self] in
            self?.titles = [:]
            self?.persist()
        }
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            // Persisted as [UUIDString: Record] for simpler JSON.
            let raw = try decoder.decode([String: Record].self, from: data)
            var resolved: [UUID: Record] = [:]
            for (k, v) in raw {
                if let uuid = UUID(uuidString: k) { resolved[uuid] = v }
            }
            titles = resolved
        } catch {
            NexLog.config.error("Failed to load conversation_titles.json: \(error.localizedDescription)")
        }
    }

    private func persist() {
        let snapshot = titles.reduce(into: [String: Record]()) { acc, kv in
            acc[kv.key.uuidString] = kv.value
        }
        queue.async { [fileURL] in
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(snapshot)
                try data.write(to: fileURL, options: .atomic)
            } catch {
                NexLog.config.error("Failed to save conversation_titles.json: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Helpers

    /// Strip surrounding quotes, code fences, "Title:" prefixes the LLM
    /// occasionally adds; cap to 60 chars; collapse whitespace.
    private func sanitize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip code fences if any.
        s = s.replacingOccurrences(of: "```", with: "")
        // Drop common prefixes.
        let prefixes = ["título:", "title:", "titulo:", "resposta:"]
        for p in prefixes {
            if s.lowercased().hasPrefix(p) {
                s = String(s.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Strip surrounding quotes (single, double, smart).
        let quoteChars: Set<Character> = ["\"", "'", "“", "”", "‘", "’", "«", "»"]
        while let first = s.first, quoteChars.contains(first) { s.removeFirst() }
        while let last = s.last, quoteChars.contains(last) { s.removeLast() }
        // Drop trailing punctuation that adds no value.
        while let last = s.last, ".!?…".contains(last) { s.removeLast() }
        // Collapse whitespace.
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        // Cap.
        if s.count > 60 {
            s = String(s.prefix(60)).trimmingCharacters(in: .whitespaces)
        }
        return s
    }
}
