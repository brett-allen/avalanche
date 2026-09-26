# Avalanche frontend

Electron UI for the Avalanche daemon HTTP API.

## Setup

```sh
# from repo root — build the daemon first
cd ../daemon && ./build.sh

cd ../frontend
npm install
npm start
```

The app looks for `../daemon/avalanched`, then `AVALANCHED_PATH`, then `avalanched` on `PATH`. Use **Start** in the header to spawn the daemon, or run `./avalanched` yourself.
