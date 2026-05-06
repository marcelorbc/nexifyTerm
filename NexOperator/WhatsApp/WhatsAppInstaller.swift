import Foundation
import Combine

/// Self-managed installer for the WhatsApp bridge.
///
/// First time the user toggles WhatsApp on in Settings we:
///   1. Make sure `node` is installed on the machine.
///   2. Copy the bridge source (shipped inside the .app bundle as Resources)
///      into `~/Library/Application Support/NexOperator/whatsapp/runtime/`.
///   3. Run `npm install` inside that runtime folder.
///   4. Run `npm run build` to produce `dist/index.js`.
///   5. From that point on, `WhatsAppBridgeService` can spawn the bridge.
///
/// Every step is observable so the Settings UI can render a progress block
/// instead of a silent toggle. We also keep a small marker file with the
/// installed version so we can re-run `npm install` automatically when the app
/// ships a newer bridge source.
@MainActor
final class WhatsAppInstaller: ObservableObject {
    static let shared = WhatsAppInstaller()

    enum Stage: Equatable {
        case idle
        case checkingNode
        case copyingSource
        case installingDeps
        case building
        case ready
        case failed(String)

        var isWorking: Bool {
            switch self {
            case .checkingNode, .copyingSource, .installingDeps, .building: return true
            default: return false
            }
        }

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }

        var description: String {
            switch self {
            case .idle:           return "Não iniciado"
            case .checkingNode:   return "Procurando Node.js..."
            case .copyingSource:  return "Copiando arquivos do bridge..."
            case .installingDeps: return "Instalando dependências (pode levar 1-2 minutos)..."
            case .building:       return "Compilando bridge..."
            case .ready:          return "Pronto"
            case .failed(let m):  return "Falha: \(m)"
            }
        }
    }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var lastLogLine: String = ""
    @Published private(set) var nodePath: String?

    private var installTask: Task<Void, Never>?

    /// Marker written on success so we can detect when the app shipped a
    /// newer bridge source than what's currently installed.
    private static let installedVersionKey = "wa.installed.bridgeVersion"
    /// Bumped together with backend/whatsapp/package.json. Keep in sync.
    private static let bundledBridgeVersion = "0.1.0"

    private init() {}

    // MARK: - Public API

    /// Returns true if `dist/index.js` exists and the recorded version matches
    /// the bundled version. When false, the caller (Settings or BridgeService)
    /// should call `installIfNeeded()` before spawning the bridge.
    var isInstalled: Bool {
        let entry = WhatsAppPaths.bridgeEntrypoint.path
        if !FileManager.default.fileExists(atPath: entry) { return false }
        let stored = NexPersistence.shared.getConfig(Self.installedVersionKey)
        return stored == Self.bundledBridgeVersion
    }

    /// Idempotent install. Runs the full pipeline only when needed; otherwise
    /// flips state to `.ready` immediately.
    func installIfNeeded() async {
        if isInstalled {
            stage = .ready
            return
        }
        await runInstall(force: false)
    }

    /// Reinstall from scratch (Settings "Reinstalar" button). Wipes the
    /// runtime folder and reruns the pipeline. Useful when the user wants to
    /// recover from a broken install.
    func reinstall() async {
        let runtime = WhatsAppPaths.runtimeDir
        try? FileManager.default.removeItem(at: runtime)
        NexPersistence.shared.setConfig(Self.installedVersionKey, value: "")
        await runInstall(force: true)
    }

    /// Cancels an ongoing install (best-effort: kills the running shell).
    func cancel() {
        installTask?.cancel()
    }

    // MARK: - Pipeline

    private func runInstall(force: Bool) async {
        installTask?.cancel()
        let task = Task {
            do {
                try await checkNode()
                try await copySource()
                try await npmInstall()
                try await npmBuild()
                NexPersistence.shared.setConfig(
                    Self.installedVersionKey,
                    value: Self.bundledBridgeVersion
                )
                stage = .ready
                NexLog.whatsapp.info("Bridge installed successfully")
            } catch is CancellationError {
                stage = .failed("Cancelado")
            } catch {
                stage = .failed(error.localizedDescription)
                NexLog.whatsapp.error("Bridge install failed: \(error.localizedDescription)")
            }
        }
        installTask = task
        await task.value
    }

    // MARK: - Steps

    private func checkNode() async throws {
        stage = .checkingNode
        let candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
        ]
        var found: String?
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                found = path
                break
            }
        }
        if found == nil, let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let full = "\(dir)/node"
                if FileManager.default.isExecutableFile(atPath: full) {
                    found = full
                    break
                }
            }
        }
        guard let nodeBin = found else {
            throw InstallerError.nodeMissing
        }
        nodePath = nodeBin
        // Verify the version is >= 18 by running `node --version`.
        let result = try await runShell(executable: nodeBin, args: ["--version"], cwd: WhatsAppPaths.dataDir)
        let version = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if let major = parseMajor(version), major < 18 {
            throw InstallerError.nodeTooOld(version)
        }
        lastLogLine = "Node \(version) encontrado em \(nodeBin)"
    }

    private func copySource() async throws {
        stage = .copyingSource
        let source = try resolveBundleSource()
        let dest = WhatsAppPaths.runtimeDir
        let fm = FileManager.default

        try fm.createDirectory(at: dest, withIntermediateDirectories: true)

        // Copy package.json (+ lockfile for reproducible installs),
        // tsconfig.json, src/ -- explicitly, skipping anything else that
        // might end up in Resources.
        let inputs = ["package.json", "package-lock.json", "tsconfig.json", "src"]
        for entry in inputs {
            let src = source.appendingPathComponent(entry)
            let dst = dest.appendingPathComponent(entry)
            guard fm.fileExists(atPath: src.path) else { continue }
            if fm.fileExists(atPath: dst.path) {
                try fm.removeItem(at: dst)
            }
            try fm.copyItem(at: src, to: dst)
        }
        lastLogLine = "Fontes copiadas para \(dest.path)"
    }

    private func npmInstall() async throws {
        stage = .installingDeps
        guard let nodePath else { throw InstallerError.nodeMissing }
        // Prefer running `npm` via the same directory the user's `node` lives
        // in; this keeps Homebrew / nvm setups consistent.
        let npmBin = nodeSiblingNpm(nodePath: nodePath) ?? "/usr/local/bin/npm"
        guard FileManager.default.isExecutableFile(atPath: npmBin) else {
            throw InstallerError.npmMissing
        }
        _ = try await runShell(
            executable: npmBin,
            args: ["install", "--no-audit", "--no-fund", "--no-progress"],
            cwd: WhatsAppPaths.runtimeDir,
            // npm install is the long step; stream stderr lines into UI.
            streamProgress: true
        )
    }

    private func npmBuild() async throws {
        stage = .building
        guard let nodePath else { throw InstallerError.nodeMissing }
        let npmBin = nodeSiblingNpm(nodePath: nodePath) ?? "/usr/local/bin/npm"
        _ = try await runShell(
            executable: npmBin,
            args: ["run", "build"],
            cwd: WhatsAppPaths.runtimeDir,
            streamProgress: true
        )
        let entry = WhatsAppPaths.bridgeEntrypoint
        guard FileManager.default.fileExists(atPath: entry.path) else {
            throw InstallerError.buildOutputMissing
        }
    }

    // MARK: - Helpers

    /// Resolves the bridge source baked into the .app bundle. Falls back to
    /// the workspace `backend/whatsapp/` for development builds where the
    /// Resources copy step hasn't run yet.
    private func resolveBundleSource() throws -> URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("whatsapp-bridge"),
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("package.json").path) {
            return bundled
        }
        // Dev fallback: walk up from the executable looking for a sibling
        // backend/whatsapp/ directory in the source tree.
        var url = Bundle.main.executableURL?.deletingLastPathComponent()
        for _ in 0..<8 {
            guard let current = url else { break }
            let candidate = current.appendingPathComponent("backend/whatsapp")
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("package.json").path) {
                return candidate
            }
            url = current.deletingLastPathComponent()
        }
        throw InstallerError.bundleMissing
    }

    private func nodeSiblingNpm(nodePath: String) -> String? {
        let dir = (nodePath as NSString).deletingLastPathComponent
        let npm = "\(dir)/npm"
        return FileManager.default.isExecutableFile(atPath: npm) ? npm : nil
    }

    private func parseMajor(_ versionString: String) -> Int? {
        let trimmed = versionString.hasPrefix("v") ? String(versionString.dropFirst()) : versionString
        return Int(trimmed.split(separator: ".").first ?? "")
    }

    /// Runs an external command, piping output line-by-line into `lastLogLine`
    /// when `streamProgress` is true. Throws on non-zero exit codes with the
    /// last 4KB of stderr captured for diagnostics.
    private func runShell(
        executable: String,
        args: [String],
        cwd: URL,
        streamProgress: Bool = false
    ) async throws -> String {
        try Task.checkCancellation()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        proc.currentDirectoryURL = cwd

        var env = ProcessInfo.processInfo.environment
        // Make sure node finds npm registries via the user's HOME (cache).
        if env["HOME"] == nil {
            env["HOME"] = NSHomeDirectory()
        }
        // Ensure npm sees a sane PATH so it can find git/python if a native
        // dependency needs to compile (better-sqlite3 ships prebuilds, but
        // be defensive).
        let extraPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PATH"] = (env["PATH"] ?? "").isEmpty ? extraPaths : "\(extraPaths):\(env["PATH"]!)"
        proc.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        // Stream stderr/stdout into `lastLogLine` so the Settings UI shows a
        // live progress hint instead of staring at a frozen spinner.
        let streamer = StreamingCollector(
            onLine: { [weak self] line in
                guard streamProgress else { return }
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                Task { @MainActor in
                    self?.lastLogLine = trimmed
                }
            }
        )
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            streamer.append(data)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            streamer.append(data)
        }

        do {
            try proc.run()
        } catch {
            throw InstallerError.launchFailed(error.localizedDescription)
        }

        // Wait for completion in a way that supports Task cancellation: we
        // poll with a short sleep so we can react to cancel requests.
        while proc.isRunning {
            if Task.isCancelled {
                proc.terminate()
                throw CancellationError()
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        if proc.terminationStatus != 0 {
            let tail = streamer.tail()
            throw InstallerError.commandFailed(
                "\(executable) \(args.joined(separator: " "))",
                Int(proc.terminationStatus),
                tail
            )
        }
        return streamer.allText()
    }
}

// MARK: - Errors

extension WhatsAppInstaller {
    enum InstallerError: LocalizedError {
        case nodeMissing
        case nodeTooOld(String)
        case npmMissing
        case bundleMissing
        case launchFailed(String)
        case commandFailed(String, Int, String)
        case buildOutputMissing

        var errorDescription: String? {
            switch self {
            case .nodeMissing:
                return "Node.js não encontrado. Instale com: brew install node"
            case .nodeTooOld(let v):
                return "Node \(v) é muito antigo (precisa de v18+). Atualize com: brew upgrade node"
            case .npmMissing:
                return "npm não encontrado ao lado do Node. Reinstale o Node."
            case .bundleMissing:
                return "Recursos do bridge não foram encontrados no app."
            case .launchFailed(let m):
                return "Falha ao executar processo: \(m)"
            case .commandFailed(let cmd, let code, let tail):
                return "Comando '\(cmd)' falhou (\(code)). Últimas linhas:\n\(tail.suffix(800))"
            case .buildOutputMissing:
                return "Build terminou mas dist/index.js não foi gerado."
            }
        }
    }
}

// MARK: - Helpers

/// Collects a process' output into a rolling buffer and notifies on each new
/// line. Thread-safe so it can be fed by both stdout and stderr handlers.
private final class StreamingCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var partial = Data()
    private var combined = Data()
    private let onLine: (String) -> Void

    init(onLine: @escaping (String) -> Void) {
        self.onLine = onLine
    }

    func append(_ data: Data) {
        lock.lock()
        partial.append(data)
        combined.append(data)
        // Keep the rolling buffer bounded (the diagnostic tail only needs the
        // last few KB of output).
        if combined.count > 8 * 1024 {
            combined = combined.suffix(8 * 1024)
        }
        // Pull complete lines out of `partial` and emit each separately.
        while let nl = partial.firstIndex(of: 0x0A) {
            let line = partial.subdata(in: 0..<nl)
            partial.removeSubrange(0...nl)
            if let str = String(data: line, encoding: .utf8) {
                lock.unlock()
                onLine(str)
                lock.lock()
            }
        }
        lock.unlock()
    }

    func tail() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: combined, encoding: .utf8) ?? ""
    }

    func allText() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: combined, encoding: .utf8) ?? ""
    }
}
