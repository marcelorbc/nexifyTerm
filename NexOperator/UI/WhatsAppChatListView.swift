import SwiftUI

/// Sidebar listing all chats for the active session. Selection drives the
/// right-hand `WhatsAppChatView`. Unread chats are bumped to the top by the
/// store via timestamp ordering already.
struct WhatsAppChatListView: View {
    @EnvironmentObject var store: WhatsAppStore
    let sessionId: String

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if filteredChats.isEmpty {
                placeholder
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredChats) { chat in
                            row(for: chat)
                            Divider().opacity(0.3)
                        }
                    }
                }
            }
        }
        .background(NexTheme.surface)
        .frame(minWidth: 260)
    }

    @State private var search: String = ""

    private var filteredChats: [WAChat] {
        let all = store.chatsFor(sessionId: sessionId)
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        return all.filter {
            $0.displayName.localizedCaseInsensitiveContains(trimmed)
            || $0.lastMessage.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Buscar conversas", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(NexTheme.bg)
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "message")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text("Sincronizando conversas...")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func row(for chat: WAChat) -> some View {
        let isSelected = store.activeChatId == chat.id
        Button {
            store.activeChatId = chat.id
            Task {
                await store.loadMessages(sessionId: sessionId, chatId: chat.id)
                await store.markRead(sessionId: sessionId, chatId: chat.id)
            }
        } label: {
            HStack(spacing: 10) {
                avatar(for: chat)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(chat.displayName)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        Spacer()
                        if let date = chat.lastMessageDate {
                            Text(Self.formatter.string(from: date))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text(chat.lastMessage.isEmpty ? " " : chat.lastMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        if chat.unreadCount > 0 {
                            Text("\(chat.unreadCount)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.green)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isSelected ? NexTheme.surfaceHover : Color.clear)
        }
        .buttonStyle(.plain)
    }

    private func avatar(for chat: WAChat) -> some View {
        ZStack {
            Circle()
                .fill(chat.isGroupChat ? Color.blue.opacity(0.2) : Color.green.opacity(0.2))
                .frame(width: 32, height: 32)
            Image(systemName: chat.isGroupChat ? "person.3.fill" : "person.fill")
                .foregroundStyle(chat.isGroupChat ? Color.blue : Color.green)
                .font(.system(size: 13))
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "HH:mm"
        return f
    }()
}
