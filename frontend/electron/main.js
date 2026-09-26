const { app, BrowserWindow, ipcMain, dialog } = require("electron");
const path = require("path");
const { spawn } = require("child_process");
const fs = require("fs");
const http = require("http");

const DEFAULT_API_PORT = 8080;
const DEFAULT_API_BASE = `http://127.0.0.1:${DEFAULT_API_PORT}`;

let mainWindow = null;
let daemonProc = null;
let managedDaemon = false;

function daemonBinaryCandidates() {
  const env = process.env.AVALANCHED_PATH;
  const local = path.resolve(__dirname, "..", "..", "daemon", "avalanched");
  return [env, local, "avalanched"].filter(Boolean);
}

function resolveDaemonBinary() {
  for (const candidate of daemonBinaryCandidates()) {
    if (candidate === "avalanched") return candidate;
    try {
      if (fs.existsSync(candidate)) return candidate;
    } catch {
      // continue
    }
  }
  return null;
}

function apiRequest(method, apiPath, body) {
  const url = new URL(apiPath, DEFAULT_API_BASE);
  const payload = body == null ? null : Buffer.from(JSON.stringify(body));
  return new Promise((resolve, reject) => {
    const req = http.request(
      {
        hostname: url.hostname,
        port: url.port,
        path: url.pathname + url.search,
        method,
        headers: {
          Accept: "application/json",
          ...(payload
            ? {
                "Content-Type": "application/json",
                "Content-Length": payload.length,
              }
            : {}),
        },
        timeout: 5000,
      },
      (res) => {
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => {
          const text = Buffer.concat(chunks).toString("utf8");
          let data = null;
          if (text) {
            try {
              data = JSON.parse(text);
            } catch {
              data = { raw: text };
            }
          }
          if (res.statusCode >= 400) {
            const err = new Error(
              (data && data.error) || `HTTP ${res.statusCode}`
            );
            err.status = res.statusCode;
            err.data = data;
            reject(err);
            return;
          }
          resolve(data);
        });
      }
    );
    req.on("error", reject);
    req.on("timeout", () => {
      req.destroy();
      reject(new Error("request timeout"));
    });
    if (payload) req.write(payload);
    req.end();
  });
}

async function healthOk() {
  try {
    const data = await apiRequest("GET", "/health");
    return data && data.status === "ok";
  } catch {
    return false;
  }
}

function startDaemon() {
  if (daemonProc) return { ok: true, managed: managedDaemon };
  const bin = resolveDaemonBinary();
  if (!bin) {
    return {
      ok: false,
      error:
        "avalanched not found. Build daemon/ first or set AVALANCHED_PATH.",
    };
  }

  const downloads = path.resolve(__dirname, "..", "..", "downloads");
  daemonProc = spawn(
    bin,
    ["serve", "--api-port", String(DEFAULT_API_PORT), "--output", downloads],
    {
      cwd: path.dirname(bin === "avalanched" ? process.cwd() : bin),
      stdio: ["ignore", "pipe", "pipe"],
      env: process.env,
    }
  );
  managedDaemon = true;

  daemonProc.stdout.on("data", (buf) => {
    if (mainWindow) {
      mainWindow.webContents.send("daemon:log", buf.toString("utf8"));
    }
  });
  daemonProc.stderr.on("data", (buf) => {
    if (mainWindow) {
      mainWindow.webContents.send("daemon:log", buf.toString("utf8"));
    }
  });
  daemonProc.on("exit", (code, signal) => {
    daemonProc = null;
    managedDaemon = false;
    if (mainWindow) {
      mainWindow.webContents.send("daemon:exit", { code, signal });
    }
  });

  return { ok: true, managed: true, path: bin };
}

function stopDaemon() {
  if (!daemonProc || !managedDaemon) {
    return { ok: false, error: "no managed daemon" };
  }
  daemonProc.kill("SIGINT");
  return { ok: true };
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1100,
    height: 720,
    minWidth: 800,
    minHeight: 520,
    title: "Avalanche",
    backgroundColor: "#0e1418",
    titleBarStyle: process.platform === "darwin" ? "hiddenInset" : "default",
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });

  mainWindow.loadFile(path.join(__dirname, "..", "renderer", "index.html"));
  mainWindow.on("closed", () => {
    mainWindow = null;
  });
}

app.whenReady().then(() => {
  createWindow();
  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") app.quit();
});

app.on("before-quit", () => {
  if (daemonProc && managedDaemon) {
    daemonProc.kill("SIGINT");
  }
});

ipcMain.handle("daemon:status", async () => {
  const healthy = await healthOk();
  return {
    healthy,
    managed: managedDaemon,
    running: Boolean(daemonProc) || healthy,
    binary: resolveDaemonBinary(),
    apiBase: DEFAULT_API_BASE,
  };
});

ipcMain.handle("daemon:start", async () => {
  if (await healthOk()) {
    return { ok: true, managed: false, already: true };
  }
  const started = startDaemon();
  if (!started.ok) return started;
  for (let i = 0; i < 40; i++) {
    await new Promise((r) => setTimeout(r, 150));
    if (await healthOk()) return { ok: true, managed: true };
  }
  return { ok: false, error: "daemon started but API never became healthy" };
});

ipcMain.handle("daemon:stop", async () => stopDaemon());

ipcMain.handle("api:list", async () => apiRequest("GET", "/api/torrents"));
ipcMain.handle("api:get", async (_e, id) =>
  apiRequest("GET", `/api/torrents/${id}`)
);
ipcMain.handle("api:details", async (_e, id) =>
  apiRequest("GET", `/api/torrents/${id}/details`)
);
ipcMain.handle("api:addMagnet", async (_e, magnet, output) =>
  apiRequest("POST", "/api/torrents", {
    magnet,
    ...(output ? { output } : {}),
  })
);
ipcMain.handle("api:stop", async (_e, id) =>
  apiRequest("POST", `/api/torrents/${id}/stop`)
);
ipcMain.handle("api:remove", async (_e, id) =>
  apiRequest("DELETE", `/api/torrents/${id}`)
);

ipcMain.handle("dialog:openTorrent", async () => {
  const result = await dialog.showOpenDialog(mainWindow, {
    title: "Open torrent",
    properties: ["openFile"],
    filters: [{ name: "Torrent", extensions: ["torrent"] }],
  });
  if (result.canceled || !result.filePaths.length) return null;
  return result.filePaths[0];
});

ipcMain.handle("api:addPath", async (_e, filePath, output) =>
  apiRequest("POST", "/api/torrents", {
    path: filePath,
    ...(output ? { output } : {}),
  })
);
