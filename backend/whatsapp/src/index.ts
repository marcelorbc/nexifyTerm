import path from "node:path";
import os from "node:os";
import fs from "node:fs";
import { WebSocketServer } from "ws";
import { WhatsAppDatabase } from "./db";
import { SessionManager } from "./session-manager";
import { WsHandler } from "./ws-handler";

// Where to keep all WhatsApp data. The Swift host normally sets this to its
// Application Support folder; falling back to ./data keeps the bridge usable
// when launched manually for debugging.
function resolveDataDir(): string {
  if (process.env.NEX_WA_DATA_DIR) return process.env.NEX_WA_DATA_DIR;
  const home = os.homedir();
  if (process.platform === "darwin") {
    return path.join(home, "Library", "Application Support", "NexOperator", "whatsapp");
  }
  return path.join(process.cwd(), "data");
}

async function main(): Promise<void> {
  const dataDir = resolveDataDir();
  fs.mkdirSync(dataDir, { recursive: true });

  const dbPath = path.join(dataDir, "whatsapp.db");
  const sessionsRoot = path.join(dataDir, "sessions");

  const db = new WhatsAppDatabase(dbPath);

  const requestedPort = Number(process.env.NEX_WA_PORT ?? "0");
  const host = process.env.NEX_WA_HOST ?? "127.0.0.1";

  const server = new WebSocketServer({ host, port: requestedPort });

  await new Promise<void>((resolve) => {
    server.on("listening", () => resolve());
  });

  const address = server.address();
  const port =
    typeof address === "object" && address ? address.port : requestedPort;

  // The Swift host parses this single line to know which port to dial. Print
  // it before any other logging would clutter stdout.
  process.stdout.write(JSON.stringify({ type: "ready", port }) + "\n");

  let handler: WsHandler;
  const manager = new SessionManager(db, sessionsRoot, (event) => {
    handler?.emit(event);
  });
  handler = new WsHandler(server, manager);

  await manager.hydrate();

  const shutdown = async (): Promise<void> => {
    try {
      server.close();
    } catch {
      // best effort
    }
    db.close();
    process.exit(0);
  };
  process.on("SIGTERM", () => void shutdown());
  process.on("SIGINT", () => void shutdown());
}

main().catch((err) => {
  // eslint-disable-next-line no-console
  console.error("[whatsapp-bridge] fatal:", err);
  process.exit(1);
});
