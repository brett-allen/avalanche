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

| Method | Path | Body |
|---|---|---|
| `GET` | `/health` | |
| `GET` | `/api/torrents` | |
| `GET` | `/api/torrents/:id` | |
| `GET` | `/api/torrents/:id/details` | files + per-peer rates (on demand) |
| `POST` | `/api/torrents` | `{"magnet":"..."}` or `{"path":"file.torrent"}` |
| `POST` | `/api/torrents/:id/stop` | |
| `DELETE` | `/api/torrents/:id` | |
