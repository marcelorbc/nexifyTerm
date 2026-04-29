import SwiftUI

struct MCPSettingsView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var mcpManager = MCPManager.shared
    @State private var servers: [MCPServerConfig] = []
    @State private var isAddingServer = false
    @State private var editingServer: MCPServerConfig?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("MCP Servers")
                    .font(.headline)
                Spacer()
                Button(action: { isAddingServer = true }) {
                    Label("Adicionar", systemImage: "plus.circle")
                }
                .controlSize(.small)
            }

            if servers.isEmpty {
                emptyState
            } else {
                serversList
            }

            Text("MCPs (Model Context Protocol) permitem conectar ferramentas externas que fornecem contexto adicional para a IA.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .onAppear { servers = appState.configStore.mcpServers }
        .sheet(isPresented: $isAddingServer) {
            MCPServerFormView(onSave: { config in
                servers.append(config)
                saveAndRestart()
                isAddingServer = false
            })
        }
        .sheet(item: $editingServer) { server in
            MCPServerFormView(existing: server, onSave: { updated in
                if let idx = servers.firstIndex(where: { $0.name == server.name }) {
                    servers[idx] = updated
                }
                saveAndRestart()
                editingServer = nil
            })
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("Nenhum servidor MCP configurado")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Text("Adicione servidores como filesystem, database, ou qualquer MCP compatível.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var serversList: some View {
        VStack(spacing: 6) {
            ForEach(servers) { server in
                serverRow(server)
            }
        }
    }

    private func serverRow(_ server: MCPServerConfig) -> some View {
        HStack(spacing: 8) {
            statusIndicator(for: server)

            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                Text("\(server.command) \(server.args.joined(separator: " "))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let status = mcpManager.serverStatuses[server.name] {
                    Text(status.displayText)
                        .font(.system(size: 10))
                        .foregroundColor(statusColor(status))
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { server.enabled },
                set: { newVal in
                    if let idx = servers.firstIndex(where: { $0.name == server.name }) {
                        servers[idx].enabled = newVal
                        saveAndRestart()
                    }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)

            Button(action: { editingServer = server }) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .controlSize(.small)

            Button(action: {
                servers.removeAll { $0.name == server.name }
                saveAndRestart()
            }) {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
            .controlSize(.small)
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
    }

    private func statusIndicator(for server: MCPServerConfig) -> some View {
        let status = mcpManager.serverStatuses[server.name]
        let color: Color = {
            guard server.enabled else { return .gray }
            switch status {
            case .connected: return .green
            case .connecting: return .yellow
            case .error: return .red
            default: return .gray
            }
        }()
        return Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private func statusColor(_ status: MCPManager.MCPServerStatus) -> Color {
        switch status {
        case .connected: return .green
        case .connecting: return .yellow
        case .error: return .red
        case .disconnected: return .secondary
        }
    }

    private func saveAndRestart() {
        appState.configStore.mcpServers = servers
        mcpManager.startServers(servers)
    }
}

struct MCPServerFormView: View {
    let existing: MCPServerConfig?
    let onSave: (MCPServerConfig) -> Void

    @State private var name: String = ""
    @State private var command: String = ""
    @State private var argsText: String = ""
    @State private var envText: String = ""
    @Environment(\.dismiss) private var dismiss

    init(existing: MCPServerConfig? = nil, onSave: @escaping (MCPServerConfig) -> Void) {
        self.existing = existing
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? "Novo Servidor MCP" : "Editar \(existing?.name ?? "")")
                .font(.title3.bold())

            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Nome") {
                    TextField("filesystem", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                        .disabled(existing != nil)
                }

                LabeledContent("Comando") {
                    TextField("npx", text: $command)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }

                LabeledContent("Argumentos") {
                    TextField("-y @modelcontextprotocol/server-filesystem /tmp", text: $argsText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
                Text("Separar argumentos por espaço")
                    .font(.caption)
                    .foregroundColor(.secondary)

                LabeledContent("Env Vars") {
                    TextField("KEY=value,KEY2=value2", text: $envText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
                Text("Formato: KEY=value separados por vírgula")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }
                    .keyboardShortcut(.escape)
                Button("Salvar") {
                    let args = parseArgs(argsText)
                    let env = parseEnv(envText)
                    let config = MCPServerConfig(
                        name: name.trimmingCharacters(in: .whitespaces),
                        command: command.trimmingCharacters(in: .whitespaces),
                        args: args,
                        env: env,
                        enabled: existing?.enabled ?? true
                    )
                    onSave(config)
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty ||
                          command.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(20)
        .frame(minWidth: 400)
        .onAppear {
            if let s = existing {
                name = s.name
                command = s.command
                argsText = s.args.joined(separator: " ")
                envText = s.env.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
            }
        }
    }

    private func parseArgs(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        return trimmed.components(separatedBy: " ").filter { !$0.isEmpty }
    }

    private func parseEnv(_ text: String) -> [String: String] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [:] }
        var env: [String: String] = [:]
        for pair in trimmed.components(separatedBy: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                env[String(parts[0]).trimmingCharacters(in: .whitespaces)] =
                    String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        return env
    }
}
