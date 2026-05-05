import Foundation
import Combine

/// Collects (and caches) the machine `SystemProfile` so the agent always has
/// hardware/OS/software context without extra round-trips. Cache lives at
/// `~/Library/Application Support/NexOperator/system_profile.json`.
///
/// Thread-safe: reads of `currentProfile` and `isStale` go through an internal
/// queue, so prompt builders can pull a snapshot from any context.
final class SystemProfileService: ObservableObject {
    static let shared = SystemProfileService()

    @Published private(set) var profile: SystemProfile = .empty
    @Published private(set) var isRefreshing: Bool = false

    private let fileURL: URL
    private let staleAfter: TimeInterval = 60 * 60 * 24 * 3 // 3 days
    private let queue = DispatchQueue(label: "com.nexia.systemprofile", qos: .utility)
    private var refreshTask: Task<Void, Never>?

    private static let probedTools: [(name: String, category: SystemProfile.DetectedTool.Category, versionFlag: String?)] = [
        // Version control
        ("git",        .versionControl, "--version"),
        // Runtimes
        ("node",       .runtime, "--version"),
        ("npm",        .runtime, "--version"),
        ("pnpm",       .runtime, "--version"),
        ("yarn",       .runtime, "--version"),
        ("bun",        .runtime, "--version"),
        ("python3",    .runtime, "--version"),
        ("python",     .runtime, "--version"),
        ("pip3",       .runtime, "--version"),
        ("ruby",       .runtime, "--version"),
        ("go",         .runtime, "version"),
        ("rustc",      .runtime, "--version"),
        ("cargo",      .runtime, "--version"),
        ("java",       .runtime, "-version"),
        ("php",        .runtime, "--version"),
        ("swift",      .runtime, "--version"),
        ("dotnet",     .runtime, "--version"),
        ("dart",       .runtime, "--version"),
        ("flutter",    .runtime, "--version"),
        // DevOps
        ("docker",     .devops, "--version"),
        ("podman",     .devops, "--version"),
        ("kubectl",    .devops, "version --client --short"),
        ("helm",       .devops, "version --short"),
        ("terraform",  .devops, "version"),
        ("ansible",    .devops, "--version"),
        ("vagrant",    .devops, "--version"),
        // Cloud
        ("aws",        .cloud, "--version"),
        ("gcloud",     .cloud, "--version"),
        ("az",         .cloud, "--version"),
        ("gh",         .cloud, "--version"),
        ("heroku",     .cloud, "--version"),
        ("flyctl",     .cloud, "version"),
        // Editors
        ("code",       .editor, "--version"),
        ("cursor",     .editor, "--version"),
        ("vim",        .editor, "--version"),
        ("nvim",       .editor, "--version"),
        // Shell utilities
        ("tmux",       .shell, "-V"),
        ("zsh",        .shell, "--version"),
        ("bash",       .shell, "--version"),
        ("fish",       .shell, "--version"),
        ("jq",         .shell, "--version"),
        ("yq",         .shell, "--version"),
        ("rg",         .shell, "--version"),
        ("fd",         .shell, "--version"),
        ("fzf",        .shell, "--version"),
        ("bat",        .shell, "--version"),
        ("htop",       .shell, nil),
        // Databases
        ("psql",       .database, "--version"),
        ("mysql",      .database, "--version"),
        ("redis-cli",  .database, "--version"),
        ("mongosh",    .database, "--version"),
        ("sqlite3",    .database, "--version"),
    ]

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let baseDir = appSupport.appendingPathComponent("NexOperator", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        self.fileURL = baseDir.appendingPathComponent("system_profile.json")
        loadFromDisk()
    }

    // MARK: - Public API

    /// Snapshot reader callable from any thread.
    var currentProfile: SystemProfile {
        queue.sync { profile }
    }

    /// True if cache is missing or older than `staleAfter`.
    var isStale: Bool {
        let snapshot = currentProfile
        return snapshot.isEmpty || -snapshot.collectedAt.timeIntervalSinceNow > staleAfter
    }

    /// Triggers a refresh in the background unless one is already in flight.
    func refresh(force: Bool = false) {
        let alreadyRunning = queue.sync { isRefreshing }
        if alreadyRunning { return }
        if !force && !isStale { return }

        setRefreshing(true)
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let collected = await Self.collect()
            self.applyCollected(collected)
        }
    }

    /// Awaitable variant for callers that want the result synchronously.
    func refreshAndWait(force: Bool = false) async {
        if !force && !isStale { return }
        setRefreshing(true)
        let collected = await Self.collect()
        applyCollected(collected)
    }

    func clearCache() {
        queue.sync {
            profile = .empty
            try? FileManager.default.removeItem(at: fileURL)
        }
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
    }

    // MARK: - State updates

    private func setRefreshing(_ value: Bool) {
        queue.sync { isRefreshing = value }
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
    }

    private func applyCollected(_ collected: SystemProfile) {
        queue.sync {
            profile = collected
            isRefreshing = false
            persist(collected)
        }
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            profile = try decoder.decode(SystemProfile.self, from: data)
        } catch {
            NexLog.config.error("Failed to load system_profile.json: \(error.localizedDescription)")
        }
    }

    private func persist(_ profile: SystemProfile) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(profile)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NexLog.config.error("Failed to save system_profile.json: \(error.localizedDescription)")
        }
    }

    // MARK: - Collection

    private static func collect() async -> SystemProfile {
        async let hardware = collectHardware()
        async let osInfo = collectOSInfo()
        async let shellEnv = collectShellEnv()
        async let tools = collectTools()
        async let pkgs = collectPackageManagers()

        return await SystemProfile(
            hardware: hardware,
            os: osInfo,
            shellEnv: shellEnv,
            tools: tools,
            packageManagers: pkgs,
            collectedAt: Date()
        )
    }

    private static func collectHardware() async -> SystemProfile.Hardware {
        let model = (await CommandExecutor.run("/usr/sbin/sysctl -n hw.model", timeout: 3)).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let chip = (await CommandExecutor.run("/usr/sbin/sysctl -n machdep.cpu.brand_string", timeout: 3)).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let arch = (await CommandExecutor.run("/usr/bin/uname -m", timeout: 3)).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let phys = Int((await CommandExecutor.run("/usr/sbin/sysctl -n hw.physicalcpu", timeout: 3)).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let logical = Int((await CommandExecutor.run("/usr/sbin/sysctl -n hw.ncpu", timeout: 3)).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let memBytes = Int64((await CommandExecutor.run("/usr/sbin/sysctl -n hw.memsize", timeout: 3)).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let memGB = Int(round(Double(memBytes) / (1024.0 * 1024.0 * 1024.0)))
        let hostname = (await CommandExecutor.run("/bin/hostname -s", timeout: 3)).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return SystemProfile.Hardware(
            model: model,
            chip: chip,
            architecture: arch,
            physicalCores: phys,
            logicalCores: logical,
            memoryGB: memGB,
            hostname: hostname
        )
    }

    private static func collectOSInfo() async -> SystemProfile.OSInfo {
        let version = (await CommandExecutor.run("/usr/bin/sw_vers -productVersion", timeout: 3)).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let build = (await CommandExecutor.run("/usr/bin/sw_vers -buildVersion", timeout: 3)).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (await CommandExecutor.run("/usr/bin/sw_vers -productName", timeout: 3)).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let locale = ProcessInfo.processInfo.environment["LANG"]
            ?? Locale.current.identifier
        let tz = TimeZone.current.identifier

        return SystemProfile.OSInfo(
            name: name.isEmpty ? "macOS" : name,
            version: version,
            build: build,
            locale: locale,
            timezone: tz
        )
    }

    private static func collectShellEnv() async -> SystemProfile.ShellEnv {
        let env = ProcessInfo.processInfo.environment
        let shell = env["SHELL"] ?? "/bin/zsh"
        let home = env["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        let editor = env["EDITOR"]
        let pathVal = env["PATH"] ?? ""
        let hasBrew = pathVal.contains("/opt/homebrew") || pathVal.contains("/usr/local/Homebrew")
            || FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew")
            || FileManager.default.fileExists(atPath: "/usr/local/bin/brew")

        return SystemProfile.ShellEnv(
            defaultShell: shell,
            homePath: home,
            pathHasHomebrew: hasBrew,
            defaultEditor: editor
        )
    }

    private static func collectTools() async -> [SystemProfile.DetectedTool] {
        await withTaskGroup(of: SystemProfile.DetectedTool.self) { group in
            for tool in probedTools {
                group.addTask {
                    await detectTool(name: tool.name, category: tool.category, versionFlag: tool.versionFlag)
                }
            }
            var results: [SystemProfile.DetectedTool] = []
            for await item in group {
                results.append(item)
            }
            return results.sorted { $0.name < $1.name }
        }
    }

    private static func detectTool(
        name: String,
        category: SystemProfile.DetectedTool.Category,
        versionFlag: String?
    ) async -> SystemProfile.DetectedTool {
        let pathRes = await CommandExecutor.run("/usr/bin/command -v \(name) 2>/dev/null || /usr/bin/which \(name)", timeout: 2)
        let path = pathRes.stdout
            .components(separatedBy: "\n")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path, !path.isEmpty, !path.contains("not found") else {
            return SystemProfile.DetectedTool(name: name, path: nil, version: nil, category: category)
        }

        var version: String? = nil
        if let flag = versionFlag {
            let cmd = "\(path) \(flag) 2>&1 | head -n 1"
            let out = await CommandExecutor.run(cmd, timeout: 3)
            let trimmed = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed.count < 200 {
                version = trimmed
            }
        }

        return SystemProfile.DetectedTool(name: name, path: path, version: version, category: category)
    }

    private static func collectPackageManagers() async -> [SystemProfile.PackageManager] {
        var managers: [SystemProfile.PackageManager] = []

        if let brew = await detectBrew() {
            managers.append(brew)
        }

        return managers
    }

    private static func detectBrew() async -> SystemProfile.PackageManager? {
        let brewPath: String? = {
            for candidate in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
                if FileManager.default.fileExists(atPath: candidate) { return candidate }
            }
            return nil
        }()
        guard let brewPath else { return nil }

        let versionOut = await CommandExecutor.run("\(brewPath) --version 2>/dev/null | head -n 1", timeout: 4)
        let version = versionOut.stdout
            .replacingOccurrences(of: "Homebrew ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let listOut = await CommandExecutor.run("\(brewPath) list --formula 2>/dev/null", timeout: 8)
        let formulae = listOut.stdout
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        let caskOut = await CommandExecutor.run("\(brewPath) list --cask 2>/dev/null", timeout: 6)
        let casks = caskOut.stdout
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .map { "[cask] \($0)" }

        let combined = (formulae + casks)
        let top = Array(combined.prefix(40))

        return SystemProfile.PackageManager(
            name: "Homebrew",
            version: version.isEmpty ? nil : version,
            packagesCount: combined.count,
            topPackages: top
        )
    }
}
