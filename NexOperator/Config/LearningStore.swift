import Foundation

struct Learning: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let command: String
    let error: String
    let lesson: String
    var hitCount: Int

    init(command: String, error: String, lesson: String) {
        self.id = UUID()
        self.timestamp = Date()
        self.command = command
        self.error = error
        self.lesson = lesson
        self.hitCount = 1
    }
}

class LearningStore {
    static let shared = LearningStore()

    private let fileURL: URL
    private var learnings: [Learning] = []
    private let maxEntries = 100

    private init() {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NexOperator")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        self.fileURL = appSupport.appendingPathComponent("learnings.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Learning].self, from: data) else {
            return
        }
        learnings = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(learnings) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func learn(command: String, error: String, lesson: String) {
        let cmdKey = normalizeCommand(command)
        let errKey = error.prefix(100).lowercased()

        if let idx = learnings.firstIndex(where: {
            normalizeCommand($0.command) == cmdKey &&
            $0.error.prefix(100).lowercased() == errKey
        }) {
            learnings[idx].hitCount += 1
            save()
            return
        }

        let entry = Learning(command: command, error: error, lesson: lesson)
        learnings.append(entry)

        if learnings.count > maxEntries {
            learnings.sort { $0.hitCount > $1.hitCount }
            learnings = Array(learnings.prefix(maxEntries))
        }

        save()
        NexLog.ai.info("Learned: \(lesson.prefix(80))")
    }

    func relevantLearnings(for query: String, limit: Int = 5) -> [Learning] {
        let queryWords = Set(query.lowercased().components(separatedBy: .whitespacesAndNewlines))

        let scored = learnings.map { learning -> (Learning, Int) in
            let cmdWords = Set(learning.command.lowercased().components(separatedBy: .whitespacesAndNewlines))
            let lessonWords = Set(learning.lesson.lowercased().components(separatedBy: .whitespacesAndNewlines))
            let overlap = queryWords.intersection(cmdWords).count + queryWords.intersection(lessonWords).count
            let recency = -learning.timestamp.timeIntervalSinceNow < 86400 * 7 ? 2 : 0
            return (learning, overlap + recency + learning.hitCount)
        }

        return scored
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    func allLearnings() -> [Learning] {
        learnings.sorted { $0.timestamp > $1.timestamp }
    }

    func clear() {
        learnings = []
        save()
    }

    private func normalizeCommand(_ cmd: String) -> String {
        let base = cmd.components(separatedBy: .whitespacesAndNewlines).first ?? cmd
        return base.lowercased()
    }
}
