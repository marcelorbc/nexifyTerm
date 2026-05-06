import SwiftUI

/// Right-hand pane: shows the messages of the currently selected chat plus a
/// composer at the bottom. Auto-scrolls to the latest message whenever new
/// data arrives.
struct WhatsAppChatView: View {
    @EnvironmentObject var store: WhatsAppStore
    @EnvironmentObject var appState: AppState
    let sessionId: String
    let chatId: String

    @State private var draft: String = ""
    @State private var isSending: Bool = false
    @State private var sendError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messagesScroll
            Divider()
            composer
        }
        .background(NexTheme.bg)
        .onAppear {
            Task { await store.loadMessages(sessionId: sessionId, chatId: chatId) }
        }
        .onChange(of: chatId) { _, _ in
            Task { await store.loadMessages(sessionId: sessionId, chatId: chatId) }
        }
    }

    private var chat: WAChat? {
        store.chatsFor(sessionId: sessionId).first(where: { $0.id == chatId })
    }

    private var messages: [WAMessage] {
        store.messagesFor(sessionId: sessionId, chatId: chatId)
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(chat?.displayName ?? chatId)
                    .font(.system(size: 13, weight: .semibold))
                Text(chat?.isGroupChat == true ? "Grupo" : "Conversa")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                askAgentSummarize()
            } label: {
                Label("Resumir com IA", systemImage: "sparkles")
                    .font(.system(size: 11, weight: .medium))
            }
            .controlSize(.small)
            .help("Pede ao agente para resumir as últimas mensagens deste chat.")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(NexTheme.surface)
    }

    private var messagesScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(messages) { message in
                        bubble(for: message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func bubble(for message: WAMessage) -> some View {
        let isMe = message.fromMe
        HStack {
            if isMe { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 2) {
                if !isMe && !message.senderName.isEmpty {
                    Text(message.senderName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                if message.hasMedia {
                    Label(message.mediaType?.capitalized ?? "Mídia", systemImage: mediaIcon(message.mediaType))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if !message.content.isEmpty {
                    Text(message.content)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                }
                Text(Self.timeFormatter.string(from: message.date))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isMe ? Color.green.opacity(0.18) : Color.gray.opacity(0.12))
            )
            if !isMe { Spacer(minLength: 60) }
        }
    }

    private var composer: some View {
        VStack(spacing: 4) {
            if let err = sendError {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                TextField("Mensagem", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .lineLimit(1...6)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(NexTheme.surface)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(NexTheme.border, lineWidth: 0.5)
                            )
                    )
                    .onSubmit { send() }

                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(canSend ? Color.green : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canSend || isSending)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(NexTheme.surface)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend, !isSending else { return }
        let text = draft
        isSending = true
        sendError = nil
        Task {
            do {
                try await store.sendText(sessionId: sessionId, chatId: chatId, text: text)
                await MainActor.run {
                    draft = ""
                    isSending = false
                }
            } catch {
                await MainActor.run {
                    sendError = error.localizedDescription
                    isSending = false
                }
            }
        }
    }

    private func askAgentSummarize() {
        // Build a one-shot prompt and route it through the regular agent flow.
        // The contextExtra hook will inject the actual messages, so we only
        // need to ask the question here.
        let target = chat?.displayName ?? chatId
        let prompt = "Resuma as últimas mensagens da conversa de WhatsApp \"\(target)\". Destaque pendências, decisões e perguntas em aberto."
        appState.startAgentExecution(prompt)
    }

    private func mediaIcon(_ type: String?) -> String {
        switch type {
        case "image": return "photo"
        case "video": return "video"
        case "audio": return "waveform"
        case "document": return "doc"
        case "sticker": return "face.smiling"
        default: return "paperclip"
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "HH:mm"
        return f
    }()
}
