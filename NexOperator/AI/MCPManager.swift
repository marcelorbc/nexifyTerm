import Foundation
import Combine

/// Manages all MCP server connections, tool discovery, and tool execution.
@MainActor
class MCPManager: ObservableObject {
    static let shared = MCPManager()

    @Published var availableTools: [MCPTool] = []
    @Published var serverStatuses: [String: MCPServerStatus] = [:]

    private var clients: [String: MCPClient] = [:]

    enum MCPServerStatus: Equatable {
        case disconnected
        case connecting
        case connected(toolCount: Int)
        case error(String)

        var displayText: String {
            switch self {
            case .disconnected: return "Desconectado"
            case .connecting: return "Conectando..."
            case .connected(let count): return "Conectado (\(count) tools)"
            case .error(let msg): return "Erro: \(msg)"
            }
        }

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    func startServers(_ configs: [MCPServerConfig]) {
        Task {
            await stopAll()

            for config in configs where config.enabled {
                await startServer(config)
            }
        }
    }

    func startServer(_ config: MCPServerConfig) async {
        serverStatuses[config.name] = .connecting

        let client = MCPClient(config: config)
        clients[config.name] = client

        do {
            try await client.start()
            let tools = await client.tools
            serverStatuses[config.name] = .connected(toolCount: tools.count)
            refreshTools()
            NexLog.ai.info("MCP server '\(config.name)' started with \(tools.count) tools")
        } catch {
            serverStatuses[config.name] = .error(error.localizedDescription)
            NexLog.ai.error("MCP server '\(config.name)' failed: \(error.localizedDescription)")
        }
    }

    func stopServer(_ name: String) async {
        if let client = clients.removeValue(forKey: name) {
            await client.stop()
        }
        serverStatuses[name] = .disconnected
        refreshTools()
    }

    func stopAll() async {
        for (name, client) in clients {
            await client.stop()
            serverStatuses[name] = .disconnected
        }
        clients.removeAll()
        availableTools = []
    }

    func restartServer(_ config: MCPServerConfig) async {
        await stopServer(config.name)
        await startServer(config)
    }

    func callTool(_ call: MCPToolCall) async -> MCPToolResult {
        guard let client = clients[call.server] else {
            return MCPToolResult(
                server: call.server,
                tool: call.tool,
                content: "Servidor MCP '\(call.server)' não está conectado.",
                isError: true
            )
        }

        let args = call.arguments.reduce(into: [String: Any]()) { result, pair in
            result[pair.key] = pair.value.toJSON()
        }

        do {
            let content = try await client.callTool(name: call.tool, arguments: args)
            return MCPToolResult(
                server: call.server,
                tool: call.tool,
                content: content,
                isError: false
            )
        } catch {
            return MCPToolResult(
                server: call.server,
                tool: call.tool,
                content: "Erro: \(error.localizedDescription)",
                isError: true
            )
        }
    }

    func executeMCPToolCalls(_ calls: [MCPToolCall]) async -> [MCPToolResult] {
        var results: [MCPToolResult] = []
        for call in calls {
            let result = await callTool(call)
            results.append(result)
        }
        return results
    }

    func toolsDescription() -> String {
        guard !availableTools.isEmpty else { return "" }

        var desc = "=== MCP TOOLS DISPONÍVEIS ===\n"
        desc += "Você pode usar estas ferramentas MCP para obter informações adicionais.\n"
        desc += "Para usar uma tool, inclua 'mcpToolCalls' no seu JSON de resposta.\n\n"

        let grouped = Dictionary(grouping: availableTools, by: \.serverName)
        for (server, tools) in grouped.sorted(by: { $0.key < $1.key }) {
            desc += "Server: \(server)\n"
            for tool in tools {
                desc += "  - \(tool.name): \(tool.description)\n"
                if let schema = tool.inputSchema, let props = schema.properties {
                    let required = Set(schema.required ?? [])
                    for (propName, propSchema) in props.sorted(by: { $0.key < $1.key }) {
                        let req = required.contains(propName) ? " (obrigatório)" : ""
                        let type = propSchema.type ?? "any"
                        let propDesc = propSchema.description ?? ""
                        desc += "      \(propName) [\(type)\(req)]: \(propDesc)\n"
                    }
                }
            }
            desc += "\n"
        }

        desc += """
        Para chamar uma tool MCP, adicione ao JSON:
        "mcpToolCalls": [
          { "server": "nome_do_server", "tool": "nome_da_tool", "arguments": { ... } }
        ]
        
        REGRAS MCP:
        - Use tools MCP ANTES dos comandos de terminal quando a tool pode fornecer a informação necessária.
        - Cada chamada retorna um resultado que será incluído no próximo contexto.
        - Se NÃO precisa de tools MCP, omita o campo "mcpToolCalls".
        === FIM MCP TOOLS ===
        """

        return desc
    }

    // MARK: - Private

    private func refreshTools() {
        Task {
            var allTools: [MCPTool] = []
            for (_, client) in clients {
                let tools = await client.tools
                allTools.append(contentsOf: tools)
            }
            availableTools = allTools
        }
    }
}
