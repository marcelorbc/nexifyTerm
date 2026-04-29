import Foundation

class HistoryStore {
    static let shared = HistoryStore()

    private let maxEntries = 500

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("NexOperator", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    func load() -> [HistoryEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            let entries = try JSONDecoder().decode([HistoryEntry].self, from: data)
            return entries
        } catch {
            NexLog.config.error("Failed to load history: \(error.localizedDescription)")
            return []
        }
    }

    func save(_ entries: [HistoryEntry]) {
        let trimmed = entries.suffix(maxEntries)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(Array(trimmed))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NexLog.config.error("Failed to save history: \(error.localizedDescription)")
        }
    }

    func append(_ entry: HistoryEntry, to entries: inout [HistoryEntry]) {
        entries.append(entry)
        save(entries)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
