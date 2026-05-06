import SwiftUI

/// Settings tab for WhatsApp. The whole flow is self-managed: toggling the
/// master switch triggers `WhatsAppInstaller` to copy the bundled bridge
/// source, run `npm install` and `npm run build` in the user's Application
/// Support folder. Once the install reaches `.ready`, the user can add
/// accounts and pair them via QR code from the WhatsApp tab.
struct WhatsAppSettingsSection: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var store = WhatsAppStore.shared
    @StateObject private var installer = WhatsAppInstaller.shared

    @State private var enabled: Bool = false
    @State private var showingAddSheet: Bool = false
    @State private var newLabel: String = ""
    @State private var actionError: String?

    private let fieldWidth: CGFloat = 280

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                masterToggleSection

                if enabled {
                    installSection

                    if installer.stage.isReady {
                        accountsSection
                        bridgeStatusSection
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(NexTheme.bg)
        .onAppear {
            enabled = appState.configStore.whatsappEnabled
            if enabled {
                Task { await store.boot() }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            addAccountSheet
        }
    }

    // MARK: - Master toggle

    private var masterToggleSection: some View {
        SettingsSectionWA(
            title: "Integração WhatsApp",
            icon: "message.fill",
            caption: "Ao ativar, o NexifyTerm instala automaticamente o serviço local que conecta com o WhatsApp Web (Baileys + SQLite). Nada é instalado na sua máquina antes disso. Use por sua conta e risco — clientes não oficiais podem violar os Termos do WhatsApp."
        ) {
            Toggle("Ativar WhatsApp", isOn: $enabled)
                .toggleStyle(.switch)
                .onChange(of: enabled) { _, newValue in
                    appState.configStore.whatsappEnabled = newValue
                    if newValue {
                        Task {
                            await installer.installIfNeeded()
                            if installer.stage.isReady {
                                await store.boot()
                            }
                        }
                    } else {
                        store.bridge.stop()
                    }
                }
        }
    }

    // MARK: - Install

    @ViewBuilder
    private var installSection: some View {
        SettingsSectionWA(
            title: "Instalação automática",
            icon: "shippingbox.fill",
            caption: "O NexifyTerm copia o bridge para ~/Library/Application Support/NexOperator/whatsapp/runtime/ e instala as dependências localmente. Você precisa de Node.js 18+ instalado (brew install node)."
        ) {
            switch installer.stage {
            case .idle:
                installRow(
                    icon: "circle.dashed",
                    color: .secondary,
                    title: "Aguardando início",
                    subtitle: "Aguardando para instalar o bridge."
                )
                Button("Instalar agora") {
                    Task { await installer.installIfNeeded() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            case .checkingNode, .copyingSource, .installingDeps, .building:
                workingRow
            case .ready:
                installRow(
                    icon: "checkmark.seal.fill",
                    color: .green,
                    title: "Bridge instalado",
                    subtitle: "Pronto para parear contas. Localização: \(WhatsAppPaths.runtimeDir.path)"
                )
                HStack {
                    Spacer()
                    Button("Reinstalar") {
                        Task { await installer.reinstall() }
                    }
                    .controlSize(.small)
                }
            case .failed(let msg):
                installRow(
                    icon: "exclamationmark.triangle.fill",
                    color: .red,
                    title: "Falha na instalação",
                    subtitle: msg
                )
                if msg.localizedCaseInsensitiveContains("node") {
                    nodeHelp
                }
                HStack {
                    Spacer()
                    Button("Tentar novamente") {
                        Task { await installer.reinstall() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
    }

    private var workingRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(installer.stage.description)
                        .font(.system(size: 12, weight: .medium))
                    if !installer.lastLogLine.isEmpty {
                        Text(installer.lastLogLine)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                Button("Cancelar") { installer.cancel() }
                    .controlSize(.small)
            }
            stageProgress
        }
    }

    private var stageProgress: some View {
        // Simple step strip showing which sub-step we're on. Helps users
        // understand the install isn't stuck.
        HStack(spacing: 4) {
            stagePill("Node",       active: stageMatches(.checkingNode), done: stageReached(.copyingSource))
            stagePill("Fontes",     active: stageMatches(.copyingSource), done: stageReached(.installingDeps))
            stagePill("Dependências", active: stageMatches(.installingDeps), done: stageReached(.building))
            stagePill("Build",      active: stageMatches(.building), done: installer.stage.isReady)
        }
    }

    private func stagePill(_ label: String, active: Bool, done: Bool) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(done ? Color.green.opacity(0.25) : (active ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.1)))
            )
            .foregroundStyle(done ? Color.green : (active ? Color.accentColor : .secondary))
    }

    private func installRow(
        icon: String,
        color: Color,
        title: String,
        subtitle: String
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private var nodeHelp: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Como instalar Node.js:")
                .font(.system(size: 11, weight: .semibold))
            Text("1. Instale o Homebrew em https://brew.sh")
                .font(.system(size: 11))
            Text("2. No terminal, rode: brew install node")
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.orange.opacity(0.1))
        )
    }

    // MARK: - Accounts

    private var accountsSection: some View {
        SettingsSectionWA(
            title: "Contas conectadas",
            icon: "person.2.fill",
            caption: "Cada conta abre uma sessão Baileys independente. Você pode parear até 4 dispositivos por número."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if store.sessions.isEmpty {
                    Text("Nenhuma conta conectada.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.sessions) { session in
                        sessionRow(session)
                    }
                }

                if let err = actionError {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }

                HStack {
                    Spacer()
                    Button("Adicionar Número") {
                        newLabel = ""
                        showingAddSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!store.bridge.isRunning)
                }
            }
        }
    }

    private var bridgeStatusSection: some View {
        SettingsSectionWA(
            title: "Status do bridge",
            icon: "bolt.horizontal.circle",
            caption: "Processo Node.js que conecta com os servidores do WhatsApp."
        ) {
            HStack(spacing: 10) {
                Image(systemName: store.bridge.isRunning ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(store.bridge.isRunning ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.bridge.isRunning ? "Em execução" : "Parado")
                        .font(.system(size: 12, weight: .medium))
                    if let err = store.bridge.lastError {
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                }
                Spacer()
                if store.bridge.isRunning {
                    Button("Reiniciar") {
                        store.bridge.stop()
                        Task { await store.boot() }
                    }
                    .controlSize(.small)
                } else {
                    Button("Iniciar") {
                        Task { await store.boot() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
    }

    private func sessionRow(_ session: WASession) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor(store.statuses[session.id] ?? session.status))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayName)
                    .font(.system(size: 12, weight: .medium))
                Text(statusLabel(store.statuses[session.id] ?? session.status))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Logout") {
                Task {
                    do { try await store.logoutSession(session.id) }
                    catch { actionError = error.localizedDescription }
                }
            }
            .controlSize(.small)
            Button(role: .destructive) {
                Task {
                    do { try await store.removeSession(session.id) }
                    catch { actionError = error.localizedDescription }
                }
            } label: {
                Text("Remover")
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(NexTheme.surface)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(NexTheme.border, lineWidth: 0.5))
        )
    }

    private var addAccountSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Nova conta WhatsApp")
                .font(.system(size: 13, weight: .semibold))
            Text("Dê um nome para identificar esta conta (ex: Pessoal, Trabalho).")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Nome da conta", text: $newLabel)
                .textFieldStyle(.roundedBorder)
                .frame(width: fieldWidth)
            HStack {
                Spacer()
                Button("Cancelar") { showingAddSheet = false }
                Button("Adicionar") {
                    let label = newLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "WhatsApp"
                        : newLabel
                    showingAddSheet = false
                    Task {
                        do {
                            _ = try await store.addSession(label: label)
                            await MainActor.run {
                                appState.addWhatsAppTab()
                            }
                        } catch {
                            await MainActor.run { actionError = error.localizedDescription }
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    // MARK: - Helpers

    private func statusColor(_ status: WAStatus) -> Color {
        switch status {
        case .connected: return .green
        case .pendingQR, .connecting: return .orange
        case .disconnected: return .gray
        case .loggedOut, .error: return .red
        }
    }

    private func statusLabel(_ status: WAStatus) -> String {
        switch status {
        case .connected: return "Conectado"
        case .pendingQR: return "Aguardando QR"
        case .connecting: return "Conectando..."
        case .disconnected: return "Desconectado (reconectando)"
        case .loggedOut: return "Sessão encerrada"
        case .error: return "Erro"
        }
    }

    private func stageMatches(_ target: WhatsAppInstaller.Stage) -> Bool {
        installer.stage == target
    }

    /// Returns true if the installer is past `target` (i.e. we already moved
    /// on from it, so the pill should be marked done).
    private func stageReached(_ target: WhatsAppInstaller.Stage) -> Bool {
        let order: [WhatsAppInstaller.Stage] = [
            .checkingNode, .copyingSource, .installingDeps, .building, .ready
        ]
        guard
            let currentIdx = order.firstIndex(of: installer.stage),
            let targetIdx = order.firstIndex(of: target)
        else {
            return installer.stage.isReady
        }
        return currentIdx >= targetIdx
    }
}

/// Lightweight section card -- mirrors the private `SettingsSection` defined
/// inside `SettingsView` (we can't reuse that one because it's fileprivate).
private struct SettingsSectionWA<Content: View>: View {
    let title: String
    let icon: String
    var caption: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(NexTheme.border, lineWidth: 0.5)
                    )
            )

            if let caption {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
