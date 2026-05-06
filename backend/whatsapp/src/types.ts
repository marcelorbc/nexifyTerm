// Shared types for the WhatsApp bridge protocol.
//
// The Swift host sends `Command` objects and receives `Event` objects, both
// over a single WebSocket connection as newline-delimited JSON. Every command
// optionally carries a `requestId` so the Swift side can correlate the matching
// `result` event back to its original call site.

export interface BaseCommand {
  requestId?: string;
}

export type Command =
  | ({ type: "list_sessions" } & BaseCommand)
  | ({ type: "add_session"; sessionId: string; label?: string } & BaseCommand)
  | ({ type: "remove_session"; sessionId: string } & BaseCommand)
  | ({ type: "logout_session"; sessionId: string } & BaseCommand)
  | ({ type: "get_chats"; sessionId: string; limit?: number } & BaseCommand)
  | ({
      type: "get_messages";
      sessionId: string;
      chatId: string;
      limit?: number;
      beforeTimestamp?: number;
    } & BaseCommand)
  | ({
      type: "send_message";
      sessionId: string;
      chatId: string;
      text: string;
    } & BaseCommand)
  | ({
      type: "mark_read";
      sessionId: string;
      chatId: string;
    } & BaseCommand)
  | ({
      type: "get_chat_context";
      sessionId: string;
      chatId: string;
      limit?: number;
    } & BaseCommand);

export type Event =
  | { event: "ready" }
  | { event: "result"; requestId: string; ok: true; data?: unknown }
  | { event: "result"; requestId: string; ok: false; error: string }
  | {
      event: "qr";
      sessionId: string;
      qr: string;
      qrImagePng: string;
    }
  | {
      event: "session_status";
      sessionId: string;
      status: SessionStatus;
      phone?: string;
      name?: string;
      reason?: string;
    }
  | { event: "chats_update"; sessionId: string; chats: ChatRow[] }
  | { event: "message"; sessionId: string; message: MessageRow };

export type SessionStatus =
  | "pending_qr"
  | "connecting"
  | "connected"
  | "disconnected"
  | "logged_out"
  | "error";

export interface SessionRow {
  id: string;
  label: string;
  phone: string | null;
  name: string | null;
  status: SessionStatus;
  createdAt: number;
}

export interface ChatRow {
  id: string;
  sessionId: string;
  name: string;
  lastMessage: string;
  lastMessageAt: number;
  unreadCount: number;
  isGroup: number;
}

export interface MessageRow {
  id: string;
  sessionId: string;
  chatId: string;
  sender: string;
  senderName: string;
  content: string;
  mediaType: string | null;
  mediaUrl: string | null;
  timestamp: number;
  isFromMe: number;
}
