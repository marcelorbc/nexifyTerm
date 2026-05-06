import Foundation
import Combine

/// Manages the lifecycle of the Node.js WhatsApp bridge process and exposes a
/// typed async API on top of its WebSocket protocol.
///
/// One service is shared by the whole app (see `WhatsAppStore.shared`). The
/// service is responsible for:
///   1. Spawning `node dist/index.js` with the right env vars.
///   2. Reading the bridge's "ready" handshake on stdout to learn the port.
///   3. Opening a `URLSessionWebSocketTask` and pumping messages.
///   4. Routing `result` events back to the awaiting caller via continuations.
///   5. Forwarding `qr`, `session_status`, `chats_update`, `message` events to
///      the `WhatsAppStore` so the SwiftUI views can react.
@MainActor
final class WhatsAppBridgeService: ObservableObject {
    enum BridgeError: Error, LocalizedError {
        case nodeNotFound
        case bridgeNotFound
        case launchFailed(String)
        case notConnected
        case commandFailed(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .nodeNotFound: return "Node.js não foi encontrado. Instale Node 18+."
            case .bridgeNotFound: return "Bridge do WhatsApp não foi compilado. Execute npm run whatsapp:build."
            case .launchFailed(let m): return "Falha ao iniciar bridge: \(m)"
            case .notConnected: return "Bridge do WhatsApp não está conectado."
            case .commandFailed(let m): return m
            case .timeout: return "Comando do WhatsApp expirou."
            }
        }
    }

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var lastError: String?

    private weak var store: WhatsAppStore?
    private var process: Process?
    private var stderrTask: Task<Void, Never>?
    private var stdoutTask: Task<Void, Never>?
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pendingRequests: [String: CheckedContinuation<Data, Error>] = [:]
    private var nextRequestId: Int = 1

    init() {}

    func attach(store: WhatsAppStore) {
        self.store = store
    }

    // MARK: - Lifecycle

    func startIfNeeded() async {
        guard !isRunning else { return }
        do {
            try await start()
        } catch {
            await MainActor.run {
                self.lastError = error.localizedDescription
            }
            NexLog.whatsapp.error("Failed to start bridge: \(error.localizedDescription)")
        }
    }

    func start() async throws {
        guard !isRunning else { return }

        let nodePath = try resolveNodeBinary()
        let bridgePath = try resolveBridgeEntrypoint()
        let dataDir = WhatsAppPaths.dataDir.path

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nodePath)
        proc.arguments = [bridgePath]

        var env = ProcessInfo.processInfo.environment
        env["NEX_WA_DATA_DIR"] = dataDir
        env["NEX_WA_PORT"] = "0"
        env["NEX_WA_HOST"] = "127.0.0.1"
        proc.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        do {
            try proc.run()
        } catch {
            throw BridgeError.launchFailed(error.localizedDescription)
        }
        self.process = proc

        // Drain stderr into the unified log so users can diagnose Baileys
        // chatter without staring at Xcode's console.
        stderrTask = Task.detached { [stderrPipe] in
            let handle = stderrPipe.fileHandleForReading
            while !Task.isCancelled {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                if let str = String(data: chunk, encoding: .utf8), !str.isEmpty {
                    NexLog.whatsapp.debug("[stderr] \(str, privacy: .public)")
                }
            }
        }

        // The bridge writes a single JSON line on stdout describing its port,
        // then keeps stdout open. We read that one line to learn the port and
        // then leave stdout idle.
        let port = try await readReadyHandshake(from: stdoutPipe)
        NexLog.whatsapp.info("Bridge ready on port \(port, privacy: .public)")

        try await connectWebSocket(port: port)
        await MainActor.run {
            self.isRunning = true
            self.lastError = nil
        }
    }

    func stop() {
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        stderrTask?.cancel()
        stdoutTask?.cancel()
        stderrTask = nil
        stdoutTask = nil

        process?.terminate()
        process = nil

        for (_, cont) in pendingRequests {
            cont.resume(throwing: BridgeError.notConnected)
        }
        pendingRequests.removeAll()
        isRunning = false
    }

    // MARK: - High-level API

    func listSessions() async throws -> [WASession] {
        let data = try await sendCommand { rid in .listSessions(requestId: rid) }
        return try Self.decode(data, as: [WASession].self)
    }

    func addSession(id: String, label: String) async throws {
        _ = try await sendCommand { rid in .addSession(requestId: rid, sessionId: id, label: label) }
    }

    func removeSession(id: String) async throws {
        _ = try await sendCommand { rid in .removeSession(requestId: rid, sessionId: id) }
    }

    func logoutSession(id: String) async throws {
        _ = try await sendCommand { rid in .logoutSession(requestId: rid, sessionId: id) }
    }

    func getChats(sessionId: String, limit: Int = 200) async throws -> [WAChat] {
        let data = try await sendCommand { rid in
            .getChats(requestId: rid, sessionId: sessionId, limit: limit)
        }
        return try Self.decode(data, as: [WAChat].self)
    }

    func getMessages(
        sessionId: String,
        chatId: String,
        limit: Int = 50,
        before: Int64? = nil
    ) async throws -> [WAMessage] {
        let data = try await sendCommand { rid in
            .getMessages(requestId: rid, sessionId: sessionId, chatId: chatId, limit: limit, beforeTimestamp: before)
        }
        return try Self.decode(data, as: [WAMessage].self)
    }

    func sendMessage(sessionId: String, chatId: String, text: String) async throws -> WAMessage {
        let data = try await sendCommand { rid in
            .sendMessage(requestId: rid, sessionId: sessionId, chatId: chatId, text: text)
        }
        return try Self.decode(data, as: WAMessage.self)
    }

    func markRead(sessionId: String, chatId: String) async throws {
        _ = try await sendCommand { rid in
            .markRead(requestId: rid, sessionId: sessionId, chatId: chatId)
        }
    }

    func chatContext(sessionId: String, chatId: String, limit: Int = 30) async throws -> [WAMessage] {
        let data = try await sendCommand { rid in
            .getChatContext(requestId: rid, sessionId: sessionId, chatId: chatId, limit: limit)
        }
        return try Self.decode(data, as: [WAMessage].self)
    }

    // MARK: - Private: process / handshake

    private func resolveNodeBinary() throws -> String {
        let candidates = [
            "/usr/local/bin/node",
            "/opt/homebrew/bin/node",
            "/usr/bin/node",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // Fallback: search PATH from the user's shell environment.
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let full = "\(dir)/node"
                if FileManager.default.isExecutableFile(atPath: full) {
                    return full
                }
            }
        }
        throw BridgeError.nodeNotFound
    }

    private func resolveBridgeEntrypoint() throws -> String {
        // Single source of truth: the runtime directory the installer
        // populates. If it's missing, the user hasn't activated WhatsApp
        // yet (or the install never finished) -- the caller surfaces a
        // friendlier message via the installer state.
        let entry = WhatsAppPaths.bridgeEntrypoint.path
        guard FileManager.default.fileExists(atPath: entry) else {
            throw BridgeError.bridgeNotFound
        }
        return entry
    }

    private func readReadyHandshake(from pipe: Pipe) async throws -> Int {
        let handle = pipe.fileHandleForReading
        let timeoutSeconds: TimeInterval = 15

        return try await withThrowingTaskGroup(of: Int.self) { group in
            group.addTask {
                var buffer = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        try Task.checkCancellation()
                        try await Task.sleep(nanoseconds: 50_000_000)
                        continue
                    }
                    buffer.append(chunk)
                    if let newlineRange = buffer.range(of: Data([0x0A])) {
                        let line = buffer.subdata(in: 0..<newlineRange.lowerBound)
                        guard
                            let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                            let type = json["type"] as? String,
                            type == "ready",
                            let port = json["port"] as? Int
                        else {
                            throw BridgeError.launchFailed("invalid ready handshake")
                        }
                        return port
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw BridgeError.timeout
            }
            let port = try await group.next()!
            group.cancelAll()
            return port
        }
    }

    private func connectWebSocket(port: Int) async throws {
        let url = URL(string: "ws://127.0.0.1:\(port)")!
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        task.resume()
        self.webSocketTask = task

        receiveTask = Task { [weak self] in
            await self?.pumpIncoming()
        }
    }

    private func pumpIncoming() async {
        guard let task = webSocketTask else { return }
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                let text: String
                switch message {
                case .string(let s): text = s
                case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
                @unknown default: continue
                }
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    handleIncoming(line: String(line))
                }
            } catch {
                NexLog.whatsapp.error("WS receive error: \(error.localizedDescription)")
                await MainActor.run {
                    self.isRunning = false
                    self.lastError = error.localizedDescription
                }
                return
            }
        }
    }

    private func handleIncoming(line: String) {
        guard let data = line.data(using: .utf8) else { return }
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        guard let event = raw["event"] as? String else { return }

        switch event {
        case "ready":
            return
        case "result":
            guard let rid = raw["requestId"] as? String else { return }
            let ok = raw["ok"] as? Bool ?? false
            if let cont = pendingRequests.removeValue(forKey: rid) {
                if ok {
                    let payload = raw["data"] ?? NSNull()
                    let payloadData: Data
                    if payload is NSNull {
                        payloadData = Data("null".utf8)
                    } else if let serialized = try? JSONSerialization.data(withJSONObject: payload) {
                        payloadData = serialized
                    } else {
                        payloadData = Data("null".utf8)
                    }
                    cont.resume(returning: payloadData)
                } else {
                    let msg = raw["error"] as? String ?? "unknown_error"
                    cont.resume(throwing: BridgeError.commandFailed(msg))
                }
            }
        case "qr":
            if let sid = raw["sessionId"] as? String,
               let qr = raw["qr"] as? String,
               let png = raw["qrImagePng"] as? String {
                store?.handle(.qr(sessionId: sid, qrText: qr, qrPngDataURL: png))
            }
        case "session_status":
            if let sid = raw["sessionId"] as? String,
               let statusStr = raw["status"] as? String,
               let status = WAStatus(rawValue: statusStr) {
                store?.handle(.sessionStatus(
                    sessionId: sid,
                    status: status,
                    phone: raw["phone"] as? String,
                    name: raw["name"] as? String,
                    reason: raw["reason"] as? String
                ))
            }
        case "chats_update":
            if let sid = raw["sessionId"] as? String,
               let arr = raw["chats"],
               let chatsData = try? JSONSerialization.data(withJSONObject: arr),
               let chats = try? JSONDecoder().decode([WAChat].self, from: chatsData) {
                store?.handle(.chatsUpdate(sessionId: sid, chats: chats))
            }
        case "message":
            if let sid = raw["sessionId"] as? String,
               let msgObj = raw["message"],
               let msgData = try? JSONSerialization.data(withJSONObject: msgObj),
               let msg = try? JSONDecoder().decode(WAMessage.self, from: msgData) {
                store?.handle(.message(sessionId: sid, message: msg))
            }
        default:
            break
        }
    }

    // MARK: - Private: command plumbing

    private func sendCommand(
        timeout: TimeInterval = 30,
        _ build: (String) -> WACommand
    ) async throws -> Data {
        guard let task = webSocketTask, isRunning else {
            throw BridgeError.notConnected
        }
        let rid = "req-\(nextRequestId)"
        nextRequestId += 1
        let command = build(rid)
        let payload = try JSONEncoder().encode(command)
        let line = String(data: payload, encoding: .utf8) ?? "{}"

        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { [weak self] in
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                    Task { @MainActor in
                        self?.pendingRequests[rid] = cont
                        do {
                            try await task.send(.string(line))
                        } catch {
                            self?.pendingRequests.removeValue(forKey: rid)
                            cont.resume(throwing: error)
                        }
                    }
                }
            }
            group.addTask { [weak self] in
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let self {
                    await MainActor.run {
                        if let cont = self.pendingRequests.removeValue(forKey: rid) {
                            cont.resume(throwing: BridgeError.timeout)
                        }
                    }
                }
                throw BridgeError.timeout
            }
            let data = try await group.next()!
            group.cancelAll()
            return data
        }
    }

    private static func decode<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        return try JSONDecoder().decode(type, from: data)
    }
}

/// Shared helpers for paths the bridge writes to and reads from.
///
/// Layout under `~/Library/Application Support/NexOperator/whatsapp/`:
/// - `runtime/`         -- copy of the bridge source + node_modules + dist
/// - `whatsapp.db`      -- SQLite database used by the bridge
/// - `sessions/`        -- per-account Baileys auth state
enum WhatsAppPaths {
    static var dataDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = appSupport
            .appendingPathComponent("NexOperator", isDirectory: true)
            .appendingPathComponent("whatsapp", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var runtimeDir: URL {
        let url = dataDir.appendingPathComponent("runtime", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var bridgeEntrypoint: URL {
        runtimeDir.appendingPathComponent("dist/index.js")
    }
}
