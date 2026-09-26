# Avalanche

BitTorrent client split into two sub-projects:

| Path | Role |
|---|---|
| [`daemon/`](daemon/) | Odin engine + HTTP API → binary `avalanched` |
| [`frontend/`](frontend/) | Electron UI talking to the daemon API |

## Quick start

```sh
# Terminal 1 — engine
cd daemon && ./build.sh && ./avalanched --api-port 8080

# Terminal 2 — UI
cd frontend && npm install && npm start
```

The frontend can also spawn `avalanched` itself if the binary is on `PATH` or at `../daemon/avalanched`.
