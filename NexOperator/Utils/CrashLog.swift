import Foundation

/// Persists crash/error info to disk so it can be shown on next launch.
final class CrashLog {
    static let shared = CrashLog()

    private let fileURL: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("NexOperator", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("last_crash.log")
    }

    func save(_ info: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(timestamp)]\n\(info)\n\n"
        try? entry.data(using: .utf8)?.write(to: fileURL, options: .atomic)
    }

    func loadAndClear() -> String? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let content = try? String(contentsOf: fileURL, encoding: .utf8)
        try? FileManager.default.removeItem(at: fileURL)
        return content
    }
}
