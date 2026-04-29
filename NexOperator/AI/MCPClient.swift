import Foundation

/// Communicates with a single MCP server process via JSON-RPC 2.0 over stdio.
actor MCPClient {
    let config: MCPServerConfig
    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var buffer = Data()
    private var nextId: Int = 1
    private var pendingRequests: [Int: CheckedContinuation<JSONRPCResponse, Error>] = [:]
    private var readTask: Task<Void, Never>?
    private(set) var tools: [MCPTool] = []
    private(set) var isConnected = false

    init(config: MCPServerConfig) {
        self.config = config
    }

    func start() async throws {
        guard !isConnected else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: resolveCommand(config.command))
        proc.arguments = config.args

        var environment = ProcessInfo.processInfo.environment
        for (key, val) in config.env {
            environment[key] = val
        }
        proc.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        do {
            try proc.run()
        } catch {
            throw MCPError.launchFailed(config.name, error.localizedDescription)
        }

        self.process = proc
        self.stdin = stdinPipe.fileHandleForWriting
        self.stdout = stdoutPipe.fileHandleForReading

        isConnected = true
        startReading()

        try await initialize()
        try await discoverTools()
    }

    func stop() {
        readTask?.cancel()
        readTask = nil
        process?.terminate()
        process = nil
        stdin = nil
        stdout = nil
        isConnected = false
        tools = []
        buffer = Data()
        for (_, cont) in pendingRequests {
            cont.resume(throwing: MCPError.disconnected)
        }
        pendingRequests.removeAll()
    }

    func callTool(name: String, arguments: [String: Any]) async throws -> String {
        let argsJSON: Any = arguments.isEmpty ? [:] as [String: String] : arguments
        let params: [String: Any] = ["name": name, "arguments": argsJSON]
        let response = try await sendRequest(method: "tools/call", params: params)

        if let error = response.error {
            throw MCPError.toolCallFailed(name, error.message)
        }

        guard let result = response.result else {
            return ""
        }

        if let content = result["content"] as? [[String: Any]] {
            return content.compactMap { item -> String? in
                if let text = item["text"] as? String { return text }
                if let type = item["type"] as? String, type == "text",
                   let text = item["text"] as? String { return text }
                return nil
            }.joined(separator: "\n")
        }

        if let data = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted) {
            return String(data: data, encoding: .utf8) ?? ""
        }

        return ""
    }

    // MARK: - Private

    private func initialize() async throws {
        let params: [String: Any] = [
            "protocolVersion": "2024-11-05",
            "capabilities": [:] as [String: Any],
            "clientInfo": [
                "name": "NexOperator",
                "version": "0.1.0"
            ]
        ]

        let response = try await sendRequest(method: "initialize", params: params)

        if let error = response.error {
            throw MCPError.initFailed(config.name, error.message)
        }

        try await sendNotification(method: "notifications/initialized")
    }

    private func discoverTools() async throws {
        let response = try await sendRequest(method: "tools/list", params: [:] as [String: String])

        let serverName = self.config.name

        if let error = response.error {
            NexLog.ai.warning("MCP tools/list error for \(serverName): \(error.message)")
            return
        }

        guard let result = response.result,
              let toolsArray = result["tools"] as? [[String: Any]] else {
            return
        }

        self.tools = toolsArray.compactMap { dict -> MCPTool? in
            guard let name = dict["name"] as? String else { return nil }
            let desc = dict["description"] as? String ?? ""
            var schema: MCPToolSchema? = nil
            if let schemaDict = dict["inputSchema"] as? [String: Any],
               let schemaData = try? JSONSerialization.data(withJSONObject: schemaDict),
               let decoded = try? JSONDecoder().decode(MCPToolSchema.self, from: schemaData) {
                schema = decoded
            }
            return MCPTool(serverName: serverName, name: name, description: desc, inputSchema: schema)
        }

        NexLog.ai.info("MCP \(serverName): discovered \(self.tools.count) tools")
    }

    private func sendRequest(method: String, params: Any) async throws -> JSONRPCResponse {
        let id = nextId
        nextId += 1

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ]

        let data = try JSONSerialization.data(withJSONObject: request)
        try sendData(data)

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation
        }
    }

    private func sendNotification(method: String) async throws {
        let notification: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method
        ]
        let data = try JSONSerialization.data(withJSONObject: notification)
        try sendData(data)
    }

    private func sendData(_ data: Data) throws {
        guard let stdin else { throw MCPError.disconnected }
        var message = Data()
        let header = "Content-Length: \(data.count)\r\n\r\n"
        message.append(header.data(using: .utf8)!)
        message.append(data)
        stdin.write(message)
    }

    private func startReading() {
        guard let stdout else { return }
        readTask = Task { [weak self] in
            while !Task.isCancelled {
                let chunk = stdout.availableData
                if chunk.isEmpty {
                    await self?.handleDisconnect()
                    break
                }
                await self?.processChunk(chunk)
            }
        }
    }

    private func processChunk(_ chunk: Data) {
        buffer.append(chunk)

        while true {
            guard let headerEnd = findHeaderEnd() else { break }

            let headerData = buffer[buffer.startIndex..<headerEnd]
            guard let headerStr = String(data: headerData, encoding: .utf8),
                  let contentLength = parseContentLength(headerStr) else {
                buffer.removeAll()
                break
            }

            let bodyStart = headerEnd + 4 // skip \r\n\r\n
            let bodyEnd = bodyStart + contentLength

            guard buffer.count >= bodyEnd else { break }

            let bodyData = buffer[bodyStart..<bodyEnd]
            buffer.removeSubrange(buffer.startIndex..<bodyEnd)

            handleMessage(bodyData)
        }
    }

    private func findHeaderEnd() -> Data.Index? {
        let separator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A] // \r\n\r\n
        guard buffer.count >= 4 else { return nil }

        for i in buffer.startIndex...(buffer.endIndex - 4) {
            if buffer[i] == separator[0] &&
               buffer[i+1] == separator[1] &&
               buffer[i+2] == separator[2] &&
               buffer[i+3] == separator[3] {
                return i
            }
        }
        return nil
    }

    private func parseContentLength(_ header: String) -> Int? {
        for line in header.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2,
               parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length",
               let length = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                return length
            }
        }
        return nil
    }

    private func handleMessage(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let id = json["id"] as? Int, let cont = pendingRequests.removeValue(forKey: id) {
            let response = JSONRPCResponse(
                id: id,
                result: json["result"] as? [String: Any],
                error: parseError(json["error"])
            )
            cont.resume(returning: response)
        }
    }

    private func parseError(_ errorObj: Any?) -> JSONRPCError? {
        guard let dict = errorObj as? [String: Any],
              let code = dict["code"] as? Int,
              let message = dict["message"] as? String else {
            return nil
        }
        return JSONRPCError(code: code, message: message)
    }

    private func handleDisconnect() {
        isConnected = false
        for (_, cont) in pendingRequests {
            cont.resume(throwing: MCPError.disconnected)
        }
        pendingRequests.removeAll()
    }

    private func resolveCommand(_ cmd: String) -> String {
        if cmd.hasPrefix("/") { return cmd }

        let searchPaths = [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "/usr/bin",
            "/bin",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".nvm/versions/node").path,
        ]

        let fm = FileManager.default
        for dir in searchPaths {
            let full = "\(dir)/\(cmd)"
            if fm.isExecutableFile(atPath: full) { return full }
        }

        if cmd == "npx" || cmd == "node" || cmd == "npm" {
            let possiblePaths = [
                "/usr/local/bin/\(cmd)",
                "/opt/homebrew/bin/\(cmd)",
                "/usr/bin/\(cmd)"
            ]
            for path in possiblePaths {
                if fm.isExecutableFile(atPath: path) { return path }
            }
        }

        return cmd
    }
}

// MARK: - JSON-RPC Types

struct JSONRPCResponse {
    let id: Int
    let result: [String: Any]?
    let error: JSONRPCError?
}

struct JSONRPCError {
    let code: Int
    let message: String
}

enum MCPError: LocalizedError {
    case launchFailed(String, String)
    case initFailed(String, String)
    case disconnected
    case toolCallFailed(String, String)
    case serverNotFound(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .launchFailed(let name, let detail): return "Falha ao iniciar MCP '\(name)': \(detail)"
        case .initFailed(let name, let detail): return "Falha ao inicializar MCP '\(name)': \(detail)"
        case .disconnected: return "Servidor MCP desconectado"
        case .toolCallFailed(let tool, let detail): return "Falha ao chamar tool '\(tool)': \(detail)"
        case .serverNotFound(let name): return "Servidor MCP '\(name)' não encontrado"
        case .timeout: return "Timeout na comunicação com MCP"
        }
    }
}
