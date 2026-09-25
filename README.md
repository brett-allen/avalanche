# Avalanche

BitTorrent client in Odin.

HTTP(S) trackers and webseeds go through `vendor:curl`. The peer wire, UDP trackers, DHT, and µTP sit on `core:net` / `core:nbio`.

## Layout

| Package | Role |
|---|---|
| `bencode` | Bencode encode/decode |
| `metainfo` | `.torrent` files and magnet URIs |
| `tracker` | HTTP(S) and UDP announce |
| `peer` | Peer wire (BEP 3), extensions (BEP 10), metadata (BEP 9) |
| `storage` | Piece-oriented file I/O |
| `session` | Client, multi-torrent engine (thread per torrent) |

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

| Flag | Description |
|---|---|
| `--output` | Download directory |
| `--port` | Listen port (default `6881`) |
| `--no-announce` | Skip HTTP and UDP tracker announce |
| `--verbose` | Show per-tracker / per-peer protocol detail |

Default `info` output is a short summary (name, size, announce/handshake counts). Use `--verbose` for the full protocol dump. Color is used when stdout is a capable terminal.
