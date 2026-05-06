import path from "node:path";
import fs from "node:fs";
import QRCode from "qrcode";
import { Boom } from "@hapi/boom";
import {
  default as makeWASocket,
  useMultiFileAuthState,
  DisconnectReason,
  type WAMessage,
  type WASocket,
  type ConnectionState,
} from "@whiskeysockets/baileys";
import pino from "pino";
import type { WhatsAppDatabase } from "./db";
import type {
  ChatRow,
  Event,
  MessageRow,
  SessionRow,
  SessionStatus,
} from "./types";

type EmitFn = (event: Event) => void;

// Baileys uses both `number` (encoded as seconds) and `Long` from long.js for
// timestamps depending on the upstream protobuf. We don't pull in the long
// types directly; this alias keeps the call sites readable.
type BaileysTimestamp =
  | number
  | { toNumber: () => number }
  | null
  | undefined;

interface SessionRuntime {
  id: string;
  socket?: WASocket;
  status: SessionStatus;
  // We start a fresh socket on remove/logout. While that is happening we
  // ignore stale events from the previous one to keep the UI consistent.
  generation: number;
}

const logger = pino({ level: "warn" });

/** Manages a pool of Baileys sockets, persisting auth state per session. */
export class SessionManager {
  private readonly runtimes = new Map<string, SessionRuntime>();

  constructor(
    private readonly db: WhatsAppDatabase,
    private readonly sessionsRoot: string,
    private readonly emit: EmitFn
  ) {
    fs.mkdirSync(this.sessionsRoot, { recursive: true });
  }

  /** Restore every session that was previously paired (auth folder exists). */
  async hydrate(): Promise<void> {
    const persisted = this.db.listSessions();
    for (const session of persisted) {
      const authDir = this.authDir(session.id);
      if (!fs.existsSync(authDir)) {
        // Auth folder is gone (user nuked it) -> reset status so the UI shows
        // "needs pairing again" instead of an inconsistent "connected".
        this.db.setSessionStatus(session.id, "logged_out");
        continue;
      }
      this.runtimes.set(session.id, {
        id: session.id,
        status: "connecting",
        generation: 0,
      });
      void this.connect(session.id).catch((err) => {
        logger.error({ err, sessionId: session.id }, "hydrate connect failed");
      });
    }
  }

  listSessions(): SessionRow[] {
    return this.db.listSessions();
  }

  async addSession(sessionId: string, label: string): Promise<void> {
    const existing = this.db.listSessions().find((s) => s.id === sessionId);
    if (!existing) {
      this.db.upsertSession({
        id: sessionId,
        label,
        phone: null,
        name: null,
        status: "pending_qr",
        createdAt: Date.now(),
      });
    } else {
      this.db.setSessionStatus(sessionId, "pending_qr");
    }
    if (!this.runtimes.has(sessionId)) {
      this.runtimes.set(sessionId, {
        id: sessionId,
        status: "pending_qr",
        generation: 0,
      });
    }
    await this.connect(sessionId);
  }

  async removeSession(sessionId: string): Promise<void> {
    await this.shutdown(sessionId);
    const dir = this.authDir(sessionId);
    if (fs.existsSync(dir)) {
      fs.rmSync(dir, { recursive: true, force: true });
    }
    this.db.removeSession(sessionId);
    this.runtimes.delete(sessionId);
  }

  async logoutSession(sessionId: string): Promise<void> {
    const runtime = this.runtimes.get(sessionId);
    if (runtime?.socket) {
      try {
        await runtime.socket.logout();
      } catch (err) {
        logger.warn({ err, sessionId }, "logout failed - cleaning up locally");
      }
    }
    await this.shutdown(sessionId);
    const dir = this.authDir(sessionId);
    if (fs.existsSync(dir)) {
      fs.rmSync(dir, { recursive: true, force: true });
    }
    this.db.setSessionStatus(sessionId, "logged_out");
    this.emit({
      event: "session_status",
      sessionId,
      status: "logged_out",
    });
  }

  listChats(sessionId: string, limit = 200): ChatRow[] {
    return this.db.listChats(sessionId, limit);
  }

  listMessages(
    sessionId: string,
    chatId: string,
    limit = 50,
    before?: number
  ): MessageRow[] {
    return this.db.listMessages(sessionId, chatId, limit, before);
  }

  markRead(sessionId: string, chatId: string): void {
    this.db.resetUnread(sessionId, chatId);
  }

  async sendText(
    sessionId: string,
    chatId: string,
    text: string
  ): Promise<MessageRow> {
    const runtime = this.runtimes.get(sessionId);
    if (!runtime?.socket) {
      throw new Error(`session not connected: ${sessionId}`);
    }
    const sent = await runtime.socket.sendMessage(chatId, { text });
    if (!sent) {
      throw new Error("send failed");
    }
    const row = this.messageFromBaileys(sessionId, sent, true);
    if (row) {
      this.db.upsertMessage(row);
      this.bumpChat(sessionId, chatId, text, sent.messageTimestamp);
    }
    return row ?? {
      id: sent.key.id ?? `${Date.now()}`,
      sessionId,
      chatId,
      sender: "me",
      senderName: "",
      content: text,
      mediaType: null,
      mediaUrl: null,
      timestamp: Date.now(),
      isFromMe: 1,
    };
  }

  // -- Internals ---------------------------------------------------------

  private authDir(sessionId: string): string {
    return path.join(this.sessionsRoot, sessionId);
  }

  private async shutdown(sessionId: string): Promise<void> {
    const runtime = this.runtimes.get(sessionId);
    if (!runtime) return;
    runtime.generation += 1;
    const sock = runtime.socket;
    runtime.socket = undefined;
    if (sock) {
      try {
        sock.ev.removeAllListeners("connection.update");
        sock.ev.removeAllListeners("creds.update");
        sock.ev.removeAllListeners("messages.upsert");
        sock.ev.removeAllListeners("chats.upsert");
        sock.ev.removeAllListeners("chats.update");
        sock.end(undefined);
      } catch (err) {
        logger.warn({ err, sessionId }, "error tearing down socket");
      }
    }
  }

  private async connect(sessionId: string): Promise<void> {
    const runtime = this.runtimes.get(sessionId);
    if (!runtime) return;
    const generation = ++runtime.generation;

    const dir = this.authDir(sessionId);
    fs.mkdirSync(dir, { recursive: true });
    const { state, saveCreds } = await useMultiFileAuthState(dir);

    const sock = makeWASocket({
      auth: state,
      printQRInTerminal: false,
      logger,
      browser: ["NexifyTerm", "Desktop", "1.0"],
      syncFullHistory: false,
      markOnlineOnConnect: false,
    });
    runtime.socket = sock;

    sock.ev.on("creds.update", saveCreds);

    sock.ev.on("connection.update", (update: Partial<ConnectionState>) => {
      if (this.runtimes.get(sessionId)?.generation !== generation) return;
      this.handleConnectionUpdate(sessionId, update).catch((err) => {
        logger.error({ err, sessionId }, "connection.update handler failed");
      });
    });

    sock.ev.on("messages.upsert", (m) => {
      if (this.runtimes.get(sessionId)?.generation !== generation) return;
      try {
        for (const msg of m.messages) this.ingestMessage(sessionId, msg);
      } catch (err) {
        logger.error({ err, sessionId }, "messages.upsert failed");
      }
    });

    sock.ev.on("chats.upsert", (chats) => {
      if (this.runtimes.get(sessionId)?.generation !== generation) return;
      for (const chat of chats) this.ingestChat(sessionId, chat);
      this.emit({
        event: "chats_update",
        sessionId,
        chats: this.db.listChats(sessionId),
      });
    });

    sock.ev.on("chats.update", (chats) => {
      if (this.runtimes.get(sessionId)?.generation !== generation) return;
      for (const chat of chats) this.ingestChat(sessionId, chat);
      this.emit({
        event: "chats_update",
        sessionId,
        chats: this.db.listChats(sessionId),
      });
    });
  }

  private async handleConnectionUpdate(
    sessionId: string,
    update: Partial<ConnectionState>
  ): Promise<void> {
    const { qr, connection, lastDisconnect } = update;

    if (qr) {
      const png = await QRCode.toDataURL(qr, { margin: 1, width: 320 });
      this.db.setSessionStatus(sessionId, "pending_qr");
      this.emit({
        event: "qr",
        sessionId,
        qr,
        qrImagePng: png,
      });
      this.emit({
        event: "session_status",
        sessionId,
        status: "pending_qr",
      });
    }

    if (connection === "open") {
      const runtime = this.runtimes.get(sessionId);
      const sock = runtime?.socket;
      const me = sock?.user;
      const phone = me?.id?.split(":")[0]?.split("@")[0] ?? null;
      if (phone) this.db.setSessionPhone(sessionId, phone, me?.name ?? null);
      this.db.setSessionStatus(sessionId, "connected");
      runtime!.status = "connected";
      this.emit({
        event: "session_status",
        sessionId,
        status: "connected",
        phone: phone ?? undefined,
        name: me?.name,
      });
    }

    if (connection === "close") {
      const reason = (lastDisconnect?.error as Boom | undefined)?.output
        ?.statusCode;
      const loggedOut = reason === DisconnectReason.loggedOut;
      const status: SessionStatus = loggedOut ? "logged_out" : "disconnected";
      this.db.setSessionStatus(sessionId, status);
      this.emit({
        event: "session_status",
        sessionId,
        status,
        reason: lastDisconnect?.error?.message,
      });
      if (loggedOut) {
        const dir = this.authDir(sessionId);
        if (fs.existsSync(dir)) fs.rmSync(dir, { recursive: true, force: true });
        return;
      }
      // Auto-reconnect with a small backoff.
      setTimeout(() => {
        if (this.runtimes.has(sessionId)) {
          this.connect(sessionId).catch((err) => {
            logger.error({ err, sessionId }, "reconnect failed");
          });
        }
      }, 2_000);
    }
  }

  private ingestChat(
    sessionId: string,
    chat: {
      id?: string | null;
      name?: string | null;
      unreadCount?: number | null;
      conversationTimestamp?: BaileysTimestamp;
    }
  ): void {
    if (!chat.id) return;
    const ts = this.timestampToMillis(chat.conversationTimestamp) ?? 0;
    this.db.upsertChat({
      id: chat.id,
      sessionId,
      name: chat.name ?? "",
      lastMessage: "",
      lastMessageAt: ts,
      unreadCount: chat.unreadCount ?? 0,
      isGroup: chat.id.endsWith("@g.us") ? 1 : 0,
    });
  }

  private ingestMessage(sessionId: string, msg: WAMessage): void {
    const row = this.messageFromBaileys(sessionId, msg, msg.key.fromMe ?? false);
    if (!row) return;
    this.db.upsertMessage(row);

    // Keep chat row in sync so the chat list shows the latest preview.
    const chatId = row.chatId;
    this.bumpChat(sessionId, chatId, row.content, row.timestamp / 1000);
    this.emit({ event: "message", sessionId, message: row });
  }

  private bumpChat(
    sessionId: string,
    chatId: string,
    content: string,
    timestampSec: BaileysTimestamp
  ): void {
    const tsMs = this.timestampToMillis(timestampSec) ?? Date.now();
    const existing = this.db
      .listChats(sessionId, 5_000)
      .find((c) => c.id === chatId);
    this.db.upsertChat({
      id: chatId,
      sessionId,
      name: existing?.name ?? "",
      lastMessage: content,
      lastMessageAt: tsMs,
      unreadCount: existing?.unreadCount ?? 0,
      isGroup: chatId.endsWith("@g.us") ? 1 : 0,
    });
    this.emit({
      event: "chats_update",
      sessionId,
      chats: this.db.listChats(sessionId),
    });
  }

  private timestampToMillis(ts: BaileysTimestamp): number | null {
    if (ts === null || ts === undefined) return null;
    if (typeof ts === "number") return ts * 1000;
    const maybeLong = ts as { toNumber?: () => number };
    if (typeof maybeLong.toNumber === "function") {
      return maybeLong.toNumber() * 1000;
    }
    return null;
  }

  private messageFromBaileys(
    sessionId: string,
    msg: WAMessage,
    fromMe: boolean
  ): MessageRow | null {
    const key = msg.key;
    if (!key.id || !key.remoteJid) return null;

    const content = this.extractText(msg);
    const mediaType = this.extractMediaType(msg);
    const sender = key.participant ?? key.remoteJid;
    const senderName = msg.pushName ?? "";
    const timestamp = this.timestampToMillis(msg.messageTimestamp) ?? Date.now();

    return {
      id: key.id,
      sessionId,
      chatId: key.remoteJid,
      sender,
      senderName,
      content,
      mediaType,
      mediaUrl: null,
      timestamp,
      isFromMe: fromMe ? 1 : 0,
    };
  }

  private extractText(msg: WAMessage): string {
    const m = msg.message;
    if (!m) return "";
    if (m.conversation) return m.conversation;
    if (m.extendedTextMessage?.text) return m.extendedTextMessage.text;
    if (m.imageMessage?.caption) return m.imageMessage.caption;
    if (m.videoMessage?.caption) return m.videoMessage.caption;
    if (m.documentMessage?.caption) return m.documentMessage.caption;
    if (m.audioMessage) return "[audio]";
    if (m.stickerMessage) return "[sticker]";
    if (m.documentMessage) return `[document] ${m.documentMessage.fileName ?? ""}`;
    return "";
  }

  private extractMediaType(msg: WAMessage): string | null {
    const m = msg.message;
    if (!m) return null;
    if (m.imageMessage) return "image";
    if (m.videoMessage) return "video";
    if (m.audioMessage) return "audio";
    if (m.documentMessage) return "document";
    if (m.stickerMessage) return "sticker";
    return null;
  }
}
