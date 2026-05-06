import type { WebSocket, WebSocketServer } from "ws";
import type { SessionManager } from "./session-manager";
import type { Command, Event } from "./types";

/** Glue between the WebSocket server and the SessionManager. */
export class WsHandler {
  private readonly clients = new Set<WebSocket>();

  constructor(
    private readonly server: WebSocketServer,
    private readonly sessions: SessionManager
  ) {
    this.server.on("connection", (ws) => this.onConnection(ws));
  }

  emit(event: Event): void {
    const payload = JSON.stringify(event) + "\n";
    for (const client of this.clients) {
      if (client.readyState === client.OPEN) {
        client.send(payload);
      }
    }
  }

  private onConnection(ws: WebSocket): void {
    this.clients.add(ws);
    ws.on("close", () => this.clients.delete(ws));
    ws.on("error", () => this.clients.delete(ws));
    ws.on("message", (raw) => {
      // Each frame is a complete JSON command. We don't buffer because the WS
      // layer already handles message boundaries for us.
      this.dispatch(ws, raw.toString("utf8")).catch((err) => {
        // Last-resort guard so a bad command never tears down the server.
        const fallback: Event = {
          event: "result",
          requestId: "unknown",
          ok: false,
          error: err instanceof Error ? err.message : String(err),
        };
        ws.send(JSON.stringify(fallback) + "\n");
      });
    });

    const ready: Event = { event: "ready" };
    ws.send(JSON.stringify(ready) + "\n");
  }

  private async dispatch(ws: WebSocket, raw: string): Promise<void> {
    let cmd: Command;
    try {
      cmd = JSON.parse(raw) as Command;
    } catch (err) {
      this.reply(ws, "unknown", false, undefined, "invalid_json");
      return;
    }

    const requestId = cmd.requestId ?? "";

    try {
      switch (cmd.type) {
        case "list_sessions": {
          this.reply(ws, requestId, true, this.sessions.listSessions());
          return;
        }
        case "add_session": {
          await this.sessions.addSession(cmd.sessionId, cmd.label ?? cmd.sessionId);
          this.reply(ws, requestId, true);
          return;
        }
        case "remove_session": {
          await this.sessions.removeSession(cmd.sessionId);
          this.reply(ws, requestId, true);
          return;
        }
        case "logout_session": {
          await this.sessions.logoutSession(cmd.sessionId);
          this.reply(ws, requestId, true);
          return;
        }
        case "get_chats": {
          const chats = this.sessions.listChats(cmd.sessionId, cmd.limit);
          this.reply(ws, requestId, true, chats);
          return;
        }
        case "get_messages": {
          const messages = this.sessions.listMessages(
            cmd.sessionId,
            cmd.chatId,
            cmd.limit,
            cmd.beforeTimestamp
          );
          this.reply(ws, requestId, true, messages);
          return;
        }
        case "send_message": {
          const sent = await this.sessions.sendText(
            cmd.sessionId,
            cmd.chatId,
            cmd.text
          );
          this.reply(ws, requestId, true, sent);
          return;
        }
        case "mark_read": {
          this.sessions.markRead(cmd.sessionId, cmd.chatId);
          this.reply(ws, requestId, true);
          return;
        }
        case "get_chat_context": {
          const limit = cmd.limit ?? 30;
          const messages = this.sessions
            .listMessages(cmd.sessionId, cmd.chatId, limit)
            .reverse();
          this.reply(ws, requestId, true, messages);
          return;
        }
        default: {
          const exhaustive: never = cmd;
          this.reply(ws, requestId, false, undefined, `unknown_command:${JSON.stringify(exhaustive)}`);
        }
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      this.reply(ws, requestId, false, undefined, message);
    }
  }

  private reply(
    ws: WebSocket,
    requestId: string,
    ok: boolean,
    data?: unknown,
    error?: string
  ): void {
    const event: Event = ok
      ? { event: "result", requestId, ok: true, data }
      : {
          event: "result",
          requestId,
          ok: false,
          error: error ?? "unknown_error",
        };
    ws.send(JSON.stringify(event) + "\n");
  }
}
