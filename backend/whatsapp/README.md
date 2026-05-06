# NexifyTerm WhatsApp Bridge

Local Node.js service that exposes WhatsApp (via [Baileys](https://github.com/WhiskeySockets/Baileys)) through a WebSocket API consumed by the Swift app.

## Architecture

```
NexifyTerm (Swift) <--WebSocket JSON--> bridge (Node) <--WS protocol--> WhatsApp servers
                                            |
                                            +--> SQLite (chats, messages)
                                            +--> auth state files (per session)
```

- **Multi session**: each WhatsApp number is one Baileys socket with its own auth folder.
- **Storage**: messages and chats persisted in `whatsapp.db` (SQLite via `better-sqlite3`).
- **Auth state**: `sessions/{sessionId}/` contains the device credentials produced by Baileys.

## Folders

By default everything lives under `$NEX_WA_DATA_DIR` (which the Swift app sets to `~/Library/Application Support/NexOperator/whatsapp/`). When the env var is missing the bridge falls back to `./data/`.

- `data/whatsapp.db` -- SQLite database
- `data/sessions/{sessionId}/` -- Baileys auth state per session

## Run locally

```bash
npm install
npm run build
NEX_WA_PORT=0 npm start
```

The bridge prints a single JSON line on stdout describing the listening port:

```
{"type":"ready","port":54321}
```

The Swift host parses that line and connects via `ws://127.0.0.1:{port}`.

## Protocol

See `src/types.ts` for all command/event shapes. The bridge is purely command/response + push events. Messages are JSON terminated by a newline.
