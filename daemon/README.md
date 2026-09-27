# Avalanche daemon (`avalanched`)

BitTorrent engine and localhost JSON API.

HTTP(S) trackers and webseeds go through `vendor:curl`. The peer wire sits on `core:net` / `core:nbio`. The control-plane API uses vendored [`odin-http`](https://github.com/laytan/odin-http) (`deps:http`).

## Build

Requires [Odin](https://odin-lang.org/) and system libcurl.

```sh
./build.sh
./avalanched version
```

```sh
./build.sh test
```

## Run

```sh
./avalanched                         # daemon (default)
./avalanched serve --api-port 8080 --output downloads
./avalanched info 'magnet:?xt=urn:btih:…'
./avalanched download 'magnet:?xt=urn:btih:…'
```

Optional JSON config (see `avalanche.example.json`). Defaults to `./avalanche.json` if present; CLI flags override the file.

```json
{
  "listen_port": 6881,
  "download_dir": "downloads",
  "api_host": "127.0.0.1",
  "api_port": 8080,
  "dht_enabled": true
}
```

```sh
./avalanched --config /etc/avalanche.json
./avalanched --no-dht
```

Session state is saved under `{download_dir}/.avalanche/` (magnet, info bencode, bitfield) so the daemon can resume after restart without re-fetching metadata or re-downloading completed pieces. `DELETE /api/torrents/:id` forgets resume state for that torrent (payload files are left on disk).

| Method | Path | Body |
|---|---|---|
| `GET` | `/health` | |
| `GET` | `/api/torrents` | |
| `GET` | `/api/torrents/:id` | |
| `GET` | `/api/torrents/:id/details` | files + per-peer rates (on demand) |
| `POST` | `/api/torrents` | `{"magnet":"..."}` or `{"path":"file.torrent"}` |
| `POST` | `/api/torrents/:id/stop` | |
| `DELETE` | `/api/torrents/:id` | |
