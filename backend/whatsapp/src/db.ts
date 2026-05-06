import Database from "better-sqlite3";
import path from "node:path";
import fs from "node:fs";
import type {
  ChatRow,
  MessageRow,
  SessionRow,
  SessionStatus,
} from "./types";

const SCHEMA = `
CREATE TABLE IF NOT EXISTS sessions (
  id TEXT PRIMARY KEY,
  label TEXT NOT NULL,
  phone TEXT,
  name TEXT,
  status TEXT NOT NULL DEFAULT 'disconnected',
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS chats (
  id TEXT NOT NULL,
  session_id TEXT NOT NULL,
  name TEXT NOT NULL DEFAULT '',
  last_message TEXT NOT NULL DEFAULT '',
  last_message_at INTEGER NOT NULL DEFAULT 0,
  unread_count INTEGER NOT NULL DEFAULT 0,
  is_group INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (id, session_id)
);

CREATE INDEX IF NOT EXISTS idx_chats_session_recent
  ON chats(session_id, last_message_at DESC);

CREATE TABLE IF NOT EXISTS messages (
  id TEXT NOT NULL,
  session_id TEXT NOT NULL,
  chat_id TEXT NOT NULL,
  sender TEXT NOT NULL DEFAULT '',
  sender_name TEXT NOT NULL DEFAULT '',
  content TEXT NOT NULL DEFAULT '',
  media_type TEXT,
  media_url TEXT,
  timestamp INTEGER NOT NULL DEFAULT 0,
  is_from_me INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (id, session_id)
);

CREATE INDEX IF NOT EXISTS idx_messages_chat_time
  ON messages(session_id, chat_id, timestamp DESC);
`;

export class WhatsAppDatabase {
  private readonly db: Database.Database;

  constructor(filePath: string) {
    fs.mkdirSync(path.dirname(filePath), { recursive: true });
    this.db = new Database(filePath);
    this.db.pragma("journal_mode = WAL");
    this.db.exec(SCHEMA);
  }

  // -- Sessions ----------------------------------------------------------

  upsertSession(session: SessionRow): void {
    this.db
      .prepare(
        `INSERT INTO sessions (id, label, phone, name, status, created_at)
         VALUES (@id, @label, @phone, @name, @status, @createdAt)
         ON CONFLICT(id) DO UPDATE SET
           label=excluded.label,
           phone=COALESCE(excluded.phone, sessions.phone),
           name=COALESCE(excluded.name, sessions.name),
           status=excluded.status`
      )
      .run({
        id: session.id,
        label: session.label,
        phone: session.phone,
        name: session.name,
        status: session.status,
        createdAt: session.createdAt,
      });
  }

  setSessionStatus(id: string, status: SessionStatus): void {
    this.db
      .prepare(`UPDATE sessions SET status = ? WHERE id = ?`)
      .run(status, id);
  }

  setSessionPhone(id: string, phone: string, name: string | null): void {
    this.db
      .prepare(`UPDATE sessions SET phone = ?, name = COALESCE(?, name) WHERE id = ?`)
      .run(phone, name, id);
  }

  listSessions(): SessionRow[] {
    return this.db
      .prepare(
        `SELECT id, label, phone, name, status, created_at as createdAt
         FROM sessions ORDER BY created_at ASC`
      )
      .all() as SessionRow[];
  }

  removeSession(id: string): void {
    const tx = this.db.transaction((sessionId: string) => {
      this.db.prepare(`DELETE FROM messages WHERE session_id = ?`).run(sessionId);
      this.db.prepare(`DELETE FROM chats WHERE session_id = ?`).run(sessionId);
      this.db.prepare(`DELETE FROM sessions WHERE id = ?`).run(sessionId);
    });
    tx(id);
  }

  // -- Chats -------------------------------------------------------------

  upsertChat(chat: ChatRow): void {
    this.db
      .prepare(
        `INSERT INTO chats (id, session_id, name, last_message, last_message_at, unread_count, is_group)
         VALUES (@id, @sessionId, @name, @lastMessage, @lastMessageAt, @unreadCount, @isGroup)
         ON CONFLICT(id, session_id) DO UPDATE SET
           name = CASE WHEN excluded.name <> '' THEN excluded.name ELSE chats.name END,
           last_message = excluded.last_message,
           last_message_at = excluded.last_message_at,
           unread_count = excluded.unread_count,
           is_group = excluded.is_group`
      )
      .run(chat);
  }

  listChats(sessionId: string, limit = 200): ChatRow[] {
    return this.db
      .prepare(
        `SELECT id, session_id as sessionId, name, last_message as lastMessage,
                last_message_at as lastMessageAt, unread_count as unreadCount,
                is_group as isGroup
         FROM chats
         WHERE session_id = ?
         ORDER BY last_message_at DESC
         LIMIT ?`
      )
      .all(sessionId, limit) as ChatRow[];
  }

  resetUnread(sessionId: string, chatId: string): void {
    this.db
      .prepare(
        `UPDATE chats SET unread_count = 0 WHERE session_id = ? AND id = ?`
      )
      .run(sessionId, chatId);
  }

  // -- Messages ----------------------------------------------------------

  upsertMessage(message: MessageRow): void {
    this.db
      .prepare(
        `INSERT INTO messages (id, session_id, chat_id, sender, sender_name, content,
                               media_type, media_url, timestamp, is_from_me)
         VALUES (@id, @sessionId, @chatId, @sender, @senderName, @content,
                 @mediaType, @mediaUrl, @timestamp, @isFromMe)
         ON CONFLICT(id, session_id) DO UPDATE SET
           content = excluded.content,
           media_type = excluded.media_type,
           media_url = excluded.media_url,
           timestamp = excluded.timestamp`
      )
      .run(message);
  }

  listMessages(
    sessionId: string,
    chatId: string,
    limit = 50,
    beforeTimestamp?: number
  ): MessageRow[] {
    const ts = beforeTimestamp ?? Number.MAX_SAFE_INTEGER;
    return this.db
      .prepare(
        `SELECT id, session_id as sessionId, chat_id as chatId, sender,
                sender_name as senderName, content, media_type as mediaType,
                media_url as mediaUrl, timestamp, is_from_me as isFromMe
         FROM messages
         WHERE session_id = ? AND chat_id = ? AND timestamp < ?
         ORDER BY timestamp DESC
         LIMIT ?`
      )
      .all(sessionId, chatId, ts, limit) as MessageRow[];
  }

  close(): void {
    this.db.close();
  }
}
