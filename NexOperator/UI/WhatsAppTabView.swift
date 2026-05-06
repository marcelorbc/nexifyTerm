import SwiftUI

/// Top-level WhatsApp tab. Three-column layout:
///   1. Session sidebar (left, 200pt)
///   2. Chat list for the active session (center, 280pt)
///   3. Active chat or empty placeholder (right, flexible)
///
/// When a session is in `pendingQR` state, a centered QR card is drawn over
/// the right-hand area until the user pairs the device.
struct WhatsAppTabView: View {
    @EnvironmentObject var store: WhatsAppStore
    @EnvironmentObject var appState: AppState
    @StateObject private var installer = WhatsAppInstaller.shared

    var body: some View {
        Group {
            if !appState.configStore.whatsappEnabled {
                disabledPlaceholder
            } else if installer.stage.isWorking || installer.stage == .idle {
                installerProgressPlaceholder
            } else if case .failed = installer.stage {
                installerFailedPlaceholder
            } else if !store.bridge.isRunning {
                bridgeStartingPlaceholder
            } else if store.sessions.isEmpty {
                emptyStatePlaceholder
            } else {
                threeColumnLayout
            }
        }
        .task {
            // If WhatsApp is enabled but not yet booted, kick the install
            // pipeline now (idempotent if already done).
            if appState.configStore.whatsappEnabled {
                await store.boot()
                if let first = store.sessions.first {
                    store.activeSessionId = store.activeSessionId ?? first.id
                    if let sid = store.activeSessionId {
                        await store.loadChats(sessionId: sid)
                    }
                }
            }
        }
    }

    // MARK: - Layout

    private var threeColumnLayout: some View {
        HStack(spacing: 0) {
            sessionSidebar
            Divider()
            if let sid = store.activeSessionId {
                WhatsAppChatListView(sessionId: sid)
                    .environmentObject(store)
                Divider()
                rightPane(sessionId: sid)
            } else {
                Spacer()
                Text("Selecione uma conta na barra lateral")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func rightPane(sessionId: String) -> some View {
        let status = store.statuses[sessionId]
        if status == .pendingQR, let qr = store.qrCodes[sessionId] {
            VStack {
                Spacer()
                WhatsAppQRCodeView(
                    dataURL: qr,
                    label: store.sessions.first(where: { $0.id == sessionId })?.label ?? "WhatsApp",
                    onCancel: {
                        Task { try? await store.removeSession(sessionId) }
                    }
                )
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .background(NexTheme.bg)
        } else if status == .connecting {
            statusPlaceholder(symbol: "arrow.triangle.2.circlepath", title: "Conectando...")
        } else if status == .disconnected {
            statusPlaceholder(symbol: "wifi.slash", title: "Desconectado", subtitle: "Aguardando reconexão automática.")
        } else if status == .loggedOut {
            statusPlaceholder(symbol: "rectangle.portrait.and.arrow.right", title: "Sessão encerrada", subtitle: "Adicione novamente para reparear.")
        } else if let chatId = store.activeChatId {
            WhatsAppChatView(sessionId: sessionId, chatId: chatId)
                .environmentObject(store)
                .environmentObject(appState)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "message.circle")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("Selecione uma conversa")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(NexTheme.bg)
        }
    }

    // MARK: - Sidebar

    private var sessionSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Contas")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 6)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(store.sessions) { session in
                        sessionRow(session)
                    }
                }
                .padding(.horizontal, 6)
            }

            Divider()
            Button {
                appState.isShowingSettings = true
                if #available(macOS 14.0, *) {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                } else {
                    NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                }
            } label: {
                Label("Gerenciar contas em Settings", systemImage: "gearshape")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(10)
        }
        .frame(width: 200)
        .background(NexTheme.surface)
    }

    private func sessionRow(_ session: WASession) -> some View {
        let isSelected = store.activeSessionId == session.id
        let status = store.statuses[session.id] ?? session.status
        return Button {
            store.activeSessionId = session.id
            Task { await store.loadChats(sessionId: session.id) }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor(status))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(statusLabel(status))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? NexTheme.surfaceHover : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Placeholders

    private var disabledPlaceholder: some View {
        VStack(spacing: 14) {
            Image(systemName: "message.badge.waveform")
                .font(.system(size: 40))
                .foregroundStyle(Color.green)
            Text("WhatsApp não está ativo")
                .font(.system(size: 14, weight: .semibold))
            Text("Ative a integração em Settings > WhatsApp. O NexifyTerm cuida da instalação automaticamente.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("Abrir Settings") {
                if #available(macOS 14.0, *) {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                } else {
                    NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var installerProgressPlaceholder: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text(installer.stage.description)
                .font(.system(size: 13, weight: .medium))
            if !installer.lastLogLine.isEmpty {
                Text(installer.lastLogLine)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 420)
            }
            Text("Esta é a primeira vez que você ativa o WhatsApp neste app. As dependências são instaladas localmente em ~/Library/Application Support/NexOperator/whatsapp/.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var installerFailedPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.red)
            Text("Falha ao instalar o bridge")
                .font(.system(size: 14, weight: .semibold))
            Text(installer.stage.description)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 8) {
                Button("Tentar novamente") {
                    Task { await installer.reinstall() }
                }
                .buttonStyle(.borderedProminent)
                Button("Abrir Settings") {
                    if #available(macOS 14.0, *) {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    } else {
                        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                    }
                }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bridgeStartingPlaceholder: some View {
        VStack(spacing: 12) {
            ProgressView()
            if let err = store.bridge.lastError {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            } else {
                Text("Iniciando bridge do WhatsApp...")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStatePlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "message.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color.green)
            Text("Conecte um número do WhatsApp")
                .font(.system(size: 14, weight: .semibold))
            Text("Vá em Settings > WhatsApp para parear seu primeiro aparelho via QR code.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("Abrir Settings") {
                if #available(macOS 14.0, *) {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                } else {
                    NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statusPlaceholder(symbol: String, title: String, subtitle: String? = nil) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NexTheme.bg)
    }

    private func statusColor(_ status: WAStatus) -> Color {
        switch status {
        case .connected:    return .green
        case .pendingQR:    return .orange
        case .connecting:   return .blue
        case .disconnected: return .gray
        case .loggedOut:    return .red
        case .error:        return .red
        }
    }

    private func statusLabel(_ status: WAStatus) -> String {
        switch status {
        case .connected:    return "Conectado"
        case .pendingQR:    return "Aguardando QR"
        case .connecting:   return "Conectando..."
        case .disconnected: return "Desconectado"
        case .loggedOut:    return "Sessão encerrada"
        case .error:        return "Erro"
        }
    }
}
