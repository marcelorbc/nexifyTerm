import Foundation
import Combine

/// Reactive cache of WhatsApp sessions/chats/messages exposed to the SwiftUI
/// layer. The store wraps `WhatsAppBridgeService` and:
///   - keeps the current sessions list, chat lists and per-chat message arrays
///   - listens for pushed events (qr, session_status, chats_update, message)
///   - provides simple async helpers used by the views
///
/// All published state is updated on the main actor so views update without
/// extra hops.
@MainActor
final class WhatsAppStore: ObservableObject {
    static let shared = WhatsAppStore()

    @Published private(set) var sessions: [WASession] = []
    @Published private(set) var chats: [String: [WAChat]] = [:] // sessionId -> chats
    @Published private(set) var messages: [String: [WAMessage]] = [:] // chatCompositeId -> messages
    @Published private(set) var qrCodes: [String: String] = [:] // sessionId -> base64 PNG data URL
    @Published private(set) var statuses: [String: WAStatus] = [:] // sessionId -> live status
    @Published var activeSessionId: String?
    @Published var activeChatId: String?

    let bridge = WhatsAppBridgeService()

    private init() {
        bridge.attach(store: self)
    }

    /// Ensures the bridge is installed (idempotent) and then starts it.
    /// Called by the WhatsApp tab and by `addSession` so the user never has
    /// to think about the underlying Node service.
    func boot() async {
        await WhatsAppInstaller.shared.installIfNeeded()
        guard WhatsAppInstaller.shared.stage.isReady else {
            // Install failed -- bridge stays stopped and Settings will show
            // the error to the user.
            return
        }
        await bridge.startIfNeeded()
        await refreshSessions()
    }

    // MARK: - Sessions

    func refreshSessions() async {
        do {
            let list = try await bridge.listSessions()
            sessions = list
            for s in list {
                statuses[s.id] = s.status
                if activeSessionId == nil, s.status == .connected {
                    activeSessionId = s.id
                }
            }
        } catch {
            NexLog.whatsapp.error("refreshSessions failed: \(error.localizedDescription)")
        }
    }

    func addSession(label: String) async throws -> String {
        let id = "wa-\(Int(Date().timeIntervalSince1970))-\(Int.random(in: 1000...9999))"
        try await bridge.addSession(id: id, label: label)
        await refreshSessions()
        return id
    }

    func removeSession(_ id: String) async throws {
        try await bridge.removeSession(id: id)
        sessions.removeAll { $0.id == id }
        chats[id] = nil
        statuses[id] = nil
        qrCodes[id] = nil
        if activeSessionId == id { activeSessionId = sessions.first?.id }
    }

    func logoutSession(_ id: String) async throws {
        try await bridge.logoutSession(id: id)
        statuses[id] = .loggedOut
    }

    // MARK: - Chats

    func loadChats(sessionId: String) async {
        do {
            let list = try await bridge.getChats(sessionId: sessionId)
            chats[sessionId] = list
        } catch {
            NexLog.whatsapp.error("loadChats failed: \(error.localizedDescription)")
        }
    }

    func chatsFor(sessionId: String) -> [WAChat] {
        chats[sessionId] ?? []
    }

    // MARK: - Messages

    func loadMessages(sessionId: String, chatId: String) async {
        do {
            let list = try await bridge.getMessages(sessionId: sessionId, chatId: chatId, limit: 100)
            // The bridge returns messages newest-first; views render top-down
            // chronological so reverse them once at load time.
            messages[chatKey(sessionId, chatId)] = list.reversed()
        } catch {
            NexLog.whatsapp.error("loadMessages failed: \(error.localizedDescription)")
        }
    }

    func messagesFor(sessionId: String, chatId: String) -> [WAMessage] {
        messages[chatKey(sessionId, chatId)] ?? []
    }

    func sendText(sessionId: String, chatId: String, text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let sent = try await bridge.sendMessage(sessionId: sessionId, chatId: chatId, text: trimmed)
        appendMessage(sent)
    }

    func markRead(sessionId: String, chatId: String) async {
        do {
            try await bridge.markRead(sessionId: sessionId, chatId: chatId)
            if var list = chats[sessionId] {
                if let idx = list.firstIndex(where: { $0.id == chatId }) {
                    let chat = list[idx]
                    list[idx] = WAChat(
                        id: chat.id,
                        sessionId: chat.sessionId,
                        name: chat.name,
                        lastMessage: chat.lastMessage,
                        lastMessageAt: chat.lastMessageAt,
                        unreadCount: 0,
                        isGroup: chat.isGroup
                    )
                    chats[sessionId] = list
                }
            }
        } catch {
            NexLog.whatsapp.warning("markRead failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Event handler (called from BridgeService)

    func handle(_ event: WAEvent) {
        switch event {
        case .qr(let sid, _, let png):
            qrCodes[sid] = png
            statuses[sid] = .pendingQR
        case .sessionStatus(let sid, let status, let phone, let name, _):
            statuses[sid] = status
            if status == .connected {
                qrCodes[sid] = nil
                if let idx = sessions.firstIndex(where: { $0.id == sid }) {
                    let cur = sessions[idx]
                    sessions[idx] = WASession(
                        id: cur.id,
                        label: cur.label,
                        phone: phone ?? cur.phone,
                        name: name ?? cur.name,
                        status: status,
                        createdAt: cur.createdAt
                    )
                }
                if activeSessionId == nil { activeSessionId = sid }
                Task { await self.loadChats(sessionId: sid) }
            } else if status == .loggedOut {
                qrCodes[sid] = nil
            }
            // Always reflect status change on the row.
            if let idx = sessions.firstIndex(where: { $0.id == sid }) {
                let cur = sessions[idx]
                sessions[idx] = WASession(
                    id: cur.id,
                    label: cur.label,
                    phone: phone ?? cur.phone,
                    name: name ?? cur.name,
                    status: status,
                    createdAt: cur.createdAt
                )
            }
        case .chatsUpdate(let sid, let list):
            chats[sid] = list
        case .message(_, let msg):
            appendMessage(msg)
        default:
            break
        }
    }

    // MARK: - Helpers

    private func appendMessage(_ msg: WAMessage) {
        let key = chatKey(msg.sessionId, msg.chatId)
        var list = messages[key] ?? []
        if list.contains(where: { $0.id == msg.id }) { return }
        list.append(msg)
        messages[key] = list
    }

    private func chatKey(_ sessionId: String, _ chatId: String) -> String {
        "\(sessionId)::\(chatId)"
    }
}
