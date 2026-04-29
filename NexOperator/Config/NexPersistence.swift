import Foundation

/// File-based persistence in ~/Library/Application Support/NexOperator/
/// Survives rebuilds, re-signing, and app reinstalls.
final class NexPersistence {
    static let shared = NexPersistence()

    private let baseDir: URL
    private let configURL: URL
    private let secretsURL: URL
    private let flagsURL: URL

    private var configCache: [String: String] = [:]
    private var secretsCache: [String: String] = [:]
    private var flagsCache: [String: Bool] = [:]

    private let queue = DispatchQueue(label: "com.nexia.persistence", qos: .utility)

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        baseDir = appSupport.appendingPathComponent("NexOperator", isDirectory: true)

        configURL = baseDir.appendingPathComponent("config.json")
        secretsURL = baseDir.appendingPathComponent("secrets.dat")
        flagsURL = baseDir.appendingPathComponent("flags.json")

        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)

        configCache = loadJSON(from: configURL) ?? [:]
        secretsCache = loadSecrets()
        flagsCache = loadJSON(from: flagsURL) ?? [:]
    }

    // MARK: - Config (models, providers, preferences)

    func getConfig(_ key: String) -> String? {
        queue.sync { configCache[key] }
    }

    func setConfig(_ key: String, value: String) {
        queue.sync {
            configCache[key] = value
            saveJSON(configCache, to: configURL)
        }
    }

    // MARK: - Secrets (API keys)

    func getSecret(_ key: String) -> String? {
        queue.sync { secretsCache[key] }
    }

    func setSecret(_ key: String, value: String) {
        queue.sync {
            secretsCache[key] = value
            saveSecrets()
        }
    }

    // MARK: - Flags (booleans like onboarding completed)

    func getFlag(_ key: String) -> Bool {
        queue.sync { flagsCache[key] ?? false }
    }

    func setFlag(_ key: String, value: Bool) {
        queue.sync {
            flagsCache[key] = value
            saveJSON(flagsCache, to: flagsURL)
        }
    }

    // MARK: - File I/O

    private func loadJSON<T: Decodable>(from url: URL) -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            NexLog.config.error("Failed to load \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    private func saveJSON<T: Encodable>(_ value: T, to url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            NexLog.config.error("Failed to save \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Basic obfuscation for secrets at rest (XOR with a fixed key).
    /// Not cryptographic security, but prevents plain-text API keys on disk.
    private func loadSecrets() -> [String: String] {
        guard FileManager.default.fileExists(atPath: secretsURL.path) else { return [:] }
        do {
            let raw = try Data(contentsOf: secretsURL)
            let decoded = xorTransform(raw)
            return try JSONDecoder().decode([String: String].self, from: decoded)
        } catch {
            NexLog.config.error("Failed to load secrets: \(error.localizedDescription)")
            return [:]
        }
    }

    private func saveSecrets() {
        do {
            let data = try JSONEncoder().encode(secretsCache)
            let encoded = xorTransform(data)
            try encoded.write(to: secretsURL, options: .atomic)
        } catch {
            NexLog.config.error("Failed to save secrets: \(error.localizedDescription)")
        }
    }

    // MARK: - Sidebar State Persistence

    private var sidebarStateURL: URL { baseDir.appendingPathComponent("sidebar_state.json") }

    func saveSidebarState(_ state: SidebarState) {
        queue.sync { saveJSON(state, to: sidebarStateURL) }
    }

    func loadSidebarState() -> SidebarState? {
        queue.sync { loadJSON(from: sidebarStateURL) }
    }

    // MARK: - Tab Session Persistence

    private var sessionURL: URL { baseDir.appendingPathComponent("session_tabs.json") }

    func saveTabs(_ tabs: [SavedTab], activeTabIndex: Int?) {
        let session = SavedSession(tabs: tabs, activeTabIndex: activeTabIndex)
        queue.sync { saveJSON(session, to: sessionURL) }
    }

    func loadTabs() -> SavedSession? {
        queue.sync { loadJSON(from: sessionURL) }
    }

    private let xorKey: [UInt8] = [0x4E, 0x65, 0x78, 0x4F, 0x70, 0x21, 0x53, 0x65, 0x63, 0x72, 0x65, 0x74]

    private func xorTransform(_ data: Data) -> Data {
        var result = Data(count: data.count)
        for i in 0..<data.count {
            result[i] = data[i] ^ xorKey[i % xorKey.count]
        }
        return result
    }
}

// MARK: - Session Persistence Models

struct SavedTab: Codable {
    let title: String
    let currentDirectory: String
    let provider: String
    let model: String
    let approvalMode: String
    let tabMode: String
    let isPinned: Bool

    init(from tab: TerminalTab) {
        self.title = tab.title
        self.currentDirectory = tab.currentDirectory
        self.provider = tab.provider.rawValue
        self.model = tab.model
        self.approvalMode = tab.approvalMode.rawValue
        self.tabMode = tab.tabMode.rawValue
        self.isPinned = tab.isPinned
    }

    func toTerminalTab() -> TerminalTab {
        TerminalTab(
            title: title,
            currentDirectory: currentDirectory,
            provider: ProviderType(rawValue: provider) ?? .ollama,
            model: model,
            approvalMode: ApprovalMode(rawValue: approvalMode) ?? .alwaysAsk,
            tabMode: TabMode(rawValue: tabMode) ?? .terminal,
            isPinned: isPinned
        )
    }
}

struct SavedSession: Codable {
    let tabs: [SavedTab]
    let activeTabIndex: Int?
}

struct SidebarState: Codable {
    let expandedFolders: [String]
    let sidebarWidth: Double
    let rootPath: String
}
