import Foundation

/// Builds a compact natural-language snippet describing the currently active
/// WhatsApp chat for the agent prompt. Pulls from the in-memory `WhatsAppStore`
/// cache so the call stays synchronous (matches `GitContextBuilder` etc.).
@MainActor
enum WhatsAppContextBuilder {
    static func formatForPrompt(maxMessages: Int = 30) -> String {
        let store = WhatsAppStore.shared
        guard let sessionId = store.activeSessionId else {
            return "[WhatsApp] Nenhuma conta conectada."
        }
        guard let chatId = store.activeChatId else {
            return "[WhatsApp] Conta ativa: \(store.sessions.first(where: { $0.id == sessionId })?.displayName ?? sessionId). Nenhuma conversa selecionada."
        }
        let chat = store.chatsFor(sessionId: sessionId).first(where: { $0.id == chatId })
        let messages = store.messagesFor(sessionId: sessionId, chatId: chatId).suffix(maxMessages)

        var lines: [String] = []
        lines.append("[WhatsApp] Conta: \(store.sessions.first(where: { $0.id == sessionId })?.displayName ?? sessionId)")
        if let chat {
            lines.append("Conversa: \(chat.displayName)\(chat.isGroupChat ? " (grupo)" : "")")
        } else {
            lines.append("Conversa: \(chatId)")
        }
        lines.append("Mensagens (\(messages.count) mais recentes):")

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        for msg in messages {
            let who = msg.fromMe
                ? "Eu"
                : (msg.senderName.isEmpty ? msg.sender : msg.senderName)
            let when = formatter.string(from: msg.date)
            let body: String
            if !msg.content.isEmpty {
                body = msg.content
            } else if let media = msg.mediaType {
                body = "[mídia: \(media)]"
            } else {
                body = "[mensagem vazia]"
            }
            lines.append("- [\(when)] \(who): \(body)")
        }

        if messages.isEmpty {
            lines.append("(nenhuma mensagem carregada ainda — peça ao usuário para abrir a conversa)")
        }

        return lines.joined(separator: "\n")
    }
}
