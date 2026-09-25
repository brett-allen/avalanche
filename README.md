# Avalanche

BitTorrent client in Odin.

HTTP(S) trackers and webseeds go through `vendor:curl`. The peer wire, UDP trackers, DHT, and µTP sit on `core:net` / `core:nbio`. The local control-plane API uses vendored [`odin-http`](https://github.com/laytan/odin-http) (`deps:http` under `./vendor/http`).

## Layout

| Package | Role |
|---|---|
| `bencode` | Bencode encode/decode |
| `metainfo` | `.torrent` files and magnet URIs |
| `tracker` | HTTP(S) and UDP announce |
| `peer` | Peer wire (BEP 3), extensions (BEP 10), metadata (BEP 9) |
| `storage` | Piece-oriented file I/O |
| `session` | Client, multi-torrent engine (thread per torrent) |
| `api` | Localhost JSON HTTP API (`serve`) |

## Build

Requires [Odin](https://odin-lang.org/) and system libcurl (already used by `vendor:curl` on macOS).

```sh
./build.sh
./avalanche version
```

Smoke the collection wiring:

```sh
./build.sh test
```

## Usage

```sh
./avalanche <command> [input] [flags]
```

| Command | Description |
|---|---|
| `version` | Print Avalanche and libcurl versions |
| `info` | Inspect a magnet URI (and `.torrent` if parseable) |
| `download` | Download one or more magnets / `.torrent` files (parallel torrents) |
| `serve` | Run localhost HTTP API bound to the multi-torrent engine |

| Flag | Description |
|---|---|
| `--output` | Download directory |
| `--port` | BitTorrent listen port (default `6881`) |
| `--api-port` | HTTP API port for `serve` (default `8080`) |
| `--no-announce` | Skip HTTP and UDP tracker announce |
| `--verbose` | Show per-tracker / per-peer protocol detail |

### HTTP API (`serve`)

```sh
./avalanche serve --api-port 8080 --output downloads
```

| Method | Path | Body |
|---|---|---|
| `GET` | `/health` | |
| `GET` | `/api/torrents` | |
| `GET` | `/api/torrents/:id` | |
| `POST` | `/api/torrents` | `{"magnet":"..."}` or `{"path":"file.torrent"}` |
| `POST` | `/api/torrents/:id/stop` | |
| `DELETE` | `/api/torrents/:id` | |

Default `info` output is a short summary (name, size, announce/handshake counts). Use `--verbose` for the full protocol dump. Color is used when stdout is a capable terminal.
