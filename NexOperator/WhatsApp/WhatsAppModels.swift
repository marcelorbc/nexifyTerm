import Foundation

// Mirrors the row shapes returned by the Node bridge. Field names match the
// JSON the bridge emits (camelCase aliases over the SQLite columns) so we can
// decode straight into these structs.

enum WAStatus: String, Codable {
    case pendingQR = "pending_qr"
    case connecting
    case connected
    case disconnected
    case loggedOut = "logged_out"
    case error
}

struct WASession: Codable, Identifiable, Equatable {
    let id: String
    let label: String
    let phone: String?
    let name: String?
    let status: WAStatus
    let createdAt: Int64

    var displayName: String {
        if let name, !name.isEmpty { return name }
        if let phone, !phone.isEmpty { return phone }
        return label
    }
}

struct WAChat: Codable, Identifiable, Equatable, Hashable {
    let id: String
    let sessionId: String
    let name: String
    let lastMessage: String
    let lastMessageAt: Int64
    let unreadCount: Int
    let isGroup: Int

    /// Composite id so SwiftUI lists keep stable selection across sessions.
    var compositeId: String { "\(sessionId):\(id)" }

    var displayName: String {
        if !name.isEmpty { return name }
        // Strip the WhatsApp suffix so the UI shows just the phone digits when
        // we don't have a saved contact name yet.
        return id.split(separator: "@").first.map(String.init) ?? id
    }

    var isGroupChat: Bool { isGroup != 0 }

    var lastMessageDate: Date? {
        guard lastMessageAt > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(lastMessageAt) / 1000.0)
    }
}

struct WAMessage: Codable, Identifiable, Equatable, Hashable {
    let id: String
    let sessionId: String
    let chatId: String
    let sender: String
    let senderName: String
    let content: String
    let mediaType: String?
    let mediaUrl: String?
    let timestamp: Int64
    let isFromMe: Int

    var compositeId: String { "\(sessionId):\(id)" }
    var fromMe: Bool { isFromMe != 0 }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000.0) }
    var hasMedia: Bool { mediaType != nil }
}

// MARK: - Bridge Protocol

enum WACommand: Encodable {
    case listSessions(requestId: String)
    case addSession(requestId: String, sessionId: String, label: String?)
    case removeSession(requestId: String, sessionId: String)
    case logoutSession(requestId: String, sessionId: String)
    case getChats(requestId: String, sessionId: String, limit: Int?)
    case getMessages(requestId: String, sessionId: String, chatId: String, limit: Int?, beforeTimestamp: Int64?)
    case sendMessage(requestId: String, sessionId: String, chatId: String, text: String)
    case markRead(requestId: String, sessionId: String, chatId: String)
    case getChatContext(requestId: String, sessionId: String, chatId: String, limit: Int?)

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .listSessions(let rid):
            try c.encode("list_sessions", forKey: .type)
            try c.encode(rid, forKey: .requestId)
        case .addSession(let rid, let sid, let label):
            try c.encode("add_session", forKey: .type)
            try c.encode(rid, forKey: .requestId)
            try c.encode(sid, forKey: .sessionId)
            try c.encodeIfPresent(label, forKey: .label)
        case .removeSession(let rid, let sid):
            try c.encode("remove_session", forKey: .type)
            try c.encode(rid, forKey: .requestId)
            try c.encode(sid, forKey: .sessionId)
        case .logoutSession(let rid, let sid):
            try c.encode("logout_session", forKey: .type)
            try c.encode(rid, forKey: .requestId)
            try c.encode(sid, forKey: .sessionId)
        case .getChats(let rid, let sid, let limit):
            try c.encode("get_chats", forKey: .type)
            try c.encode(rid, forKey: .requestId)
            try c.encode(sid, forKey: .sessionId)
            try c.encodeIfPresent(limit, forKey: .limit)
        case .getMessages(let rid, let sid, let cid, let limit, let before):
            try c.encode("get_messages", forKey: .type)
            try c.encode(rid, forKey: .requestId)
            try c.encode(sid, forKey: .sessionId)
            try c.encode(cid, forKey: .chatId)
            try c.encodeIfPresent(limit, forKey: .limit)
            try c.encodeIfPresent(before, forKey: .beforeTimestamp)
        case .sendMessage(let rid, let sid, let cid, let text):
            try c.encode("send_message", forKey: .type)
            try c.encode(rid, forKey: .requestId)
            try c.encode(sid, forKey: .sessionId)
            try c.encode(cid, forKey: .chatId)
            try c.encode(text, forKey: .text)
        case .markRead(let rid, let sid, let cid):
            try c.encode("mark_read", forKey: .type)
            try c.encode(rid, forKey: .requestId)
            try c.encode(sid, forKey: .sessionId)
            try c.encode(cid, forKey: .chatId)
        case .getChatContext(let rid, let sid, let cid, let limit):
            try c.encode("get_chat_context", forKey: .type)
            try c.encode(rid, forKey: .requestId)
            try c.encode(sid, forKey: .sessionId)
            try c.encode(cid, forKey: .chatId)
            try c.encodeIfPresent(limit, forKey: .limit)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case requestId
        case sessionId
        case chatId
        case label
        case text
        case limit
        case beforeTimestamp
    }
}

/// Decoded form of `event` payloads pushed by the bridge.
enum WAEvent {
    case ready
    case result(requestId: String, ok: Bool, data: Data?, error: String?)
    case qr(sessionId: String, qrText: String, qrPngDataURL: String)
    case sessionStatus(sessionId: String, status: WAStatus, phone: String?, name: String?, reason: String?)
    case chatsUpdate(sessionId: String, chats: [WAChat])
    case message(sessionId: String, message: WAMessage)
    case unknown(String)
}
