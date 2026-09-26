const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("avalanche", {
  daemonStatus: () => ipcRenderer.invoke("daemon:status"),
  daemonStart: () => ipcRenderer.invoke("daemon:start"),
  daemonStop: () => ipcRenderer.invoke("daemon:stop"),
  listTorrents: () => ipcRenderer.invoke("api:list"),
  getTorrent: (id) => ipcRenderer.invoke("api:get", id),
  getDetails: (id) => ipcRenderer.invoke("api:details", id),
  addMagnet: (magnet, output) =>
    ipcRenderer.invoke("api:addMagnet", magnet, output),
  addPath: (filePath, output) =>
    ipcRenderer.invoke("api:addPath", filePath, output),
  stopTorrent: (id) => ipcRenderer.invoke("api:stop", id),
  removeTorrent: (id) => ipcRenderer.invoke("api:remove", id),
  openTorrentDialog: () => ipcRenderer.invoke("dialog:openTorrent"),
  onDaemonLog: (cb) => {
    const listener = (_e, line) => cb(line);
    ipcRenderer.on("daemon:log", listener);
    return () => ipcRenderer.removeListener("daemon:log", listener);
  },
  onDaemonExit: (cb) => {
    const listener = (_e, info) => cb(info);
    ipcRenderer.on("daemon:exit", listener);
    return () => ipcRenderer.removeListener("daemon:exit", listener);
  },
});
