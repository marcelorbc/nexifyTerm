import Foundation

struct RecentDirectory: Codable, Identifiable, Equatable {
    var id: String { path }
    let path: String
    let name: String
    let visitedAt: Date
}

final class RecentDirectoriesStore: ObservableObject {
    static let shared = RecentDirectoriesStore()

    @Published private(set) var recents: [RecentDirectory] = []

    private let maxItems = 20
    private let fileURL: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("NexOperator", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("recent_directories.json")
        load()
    }

    func add(_ path: String) {
        let name = URL(fileURLWithPath: path).lastPathComponent
        recents.removeAll { $0.path == path }
        recents.insert(RecentDirectory(path: path, name: name, visitedAt: Date()), at: 0)
        if recents.count > maxItems {
            recents = Array(recents.prefix(maxItems))
        }
        persist()
    }

    func remove(_ path: String) {
        recents.removeAll { $0.path == path }
        persist()
    }

    func clear() {
        recents.removeAll()
        persist()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            recents = try decoder.decode([RecentDirectory].self, from: data)
        } catch {
            NexLog.config.error("Failed to load recent directories: \(error.localizedDescription)")
        }
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(recents)
            try data.write(to: fileURL, options: .atomic)
            SpotlightIndexer.shared.indexRecentDirectories(recents)
            SharedDefaults.updateRecentDirectories(recents)
        } catch {
            NexLog.config.error("Failed to save recent directories: \(error.localizedDescription)")
        }
    }
}
