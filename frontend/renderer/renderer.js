const magnetInput = document.getElementById("magnet-input");
const torrentList = document.getElementById("torrent-list");
const emptyState = document.getElementById("empty-state");
const torrentMeta = document.getElementById("torrent-meta");
const overallSpeed = document.getElementById("overall-speed");
const workspace = document.querySelector(".workspace");
const detailPanel = document.getElementById("detail-panel");
const detailTitle = document.getElementById("detail-title");
const detailSpeed = document.getElementById("detail-speed");
const detailFiles = document.getElementById("detail-files");
const detailPeers = document.getElementById("detail-peers");
const detailFilesEmpty = document.getElementById("detail-files-empty");
const detailPeersEmpty = document.getElementById("detail-peers-empty");
const panelFiles = document.getElementById("panel-files");
const panelPeers = document.getElementById("panel-peers");
const btnDetailClose = document.getElementById("btn-detail-close");
const detailTabs = document.querySelectorAll(".detail-tab");
const daemonStatus = document.getElementById("daemon-status");
const daemonLabel = daemonStatus.querySelector(".daemon-label");
const btnDaemonToggle = document.getElementById("btn-daemon-toggle");
const btnAddMagnet = document.getElementById("btn-add-magnet");
const btnOpenTorrent = document.getElementById("btn-open-torrent");
const toastEl = document.getElementById("toast");

/** @type {Map<number|string, HTMLElement>} */
const rows = new Map();
/** @type {Map<number|string, object>} */
const torrentById = new Map();

let pollTimer = null;
let detailTimer = null;
let toastTimer = null;
let lastDaemonKey = "";
let lastMeta = "";
let lastOverall = "";
let refreshing = false;
let detailRefreshing = false;
/** @type {number|string|null} */
let selectedId = null;
let activeDetailTab = "files";

function toast(message) {
  toastEl.textContent = message;
  toastEl.classList.remove("hidden");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toastEl.classList.add("hidden"), 3200);
}

function formatBytes(n) {
  const v = Number(n) || 0;
  if (v < 1024) return `${v} B`;
  const units = ["KB", "MB", "GB", "TB"];
  let x = v;
  let i = -1;
  do {
    x /= 1024;
    i += 1;
  } while (x >= 1024 && i < units.length - 1);
  return `${x.toFixed(x >= 10 || i === 0 ? 0 : 1)} ${units[i]}`;
}

function formatRate(n) {
  const v = Number(n) || 0;
  if (v < 1024) return `${Math.round(v)} B/s`;
  const units = ["kB/s", "MB/s", "GB/s"];
  let x = v / 1024;
  let i = 0;
  while (x >= 1024 && i < units.length - 1) {
    x /= 1024;
    i += 1;
  }
  return `${x.toFixed(x >= 10 || i === 0 ? 0 : 1)} ${units[i]}`;
}

function speedLine(down, up) {
  return `▼ ${formatRate(down)}  ▲ ${formatRate(up)}`;
}

function progressPct(t) {
  if (t.bytes_total > 0) return Math.min(100, (100 * t.bytes_done) / t.bytes_total);
  if (t.pieces_total > 0) return Math.min(100, (100 * t.pieces_done) / t.pieces_total);
  return 0;
}

function isTerminal(state) {
  return state === "complete" || state === "stopped" || state === "failed";
}

function setText(el, value) {
  if (el && el.textContent !== value) el.textContent = value;
}

function setDaemonUI(status) {
  const up = Boolean(status.healthy);
  const key = `${up}|${Boolean(status.managed)}`;
  if (key === lastDaemonKey) return;
  lastDaemonKey = key;

  daemonStatus.dataset.state = up ? "up" : "down";
  setText(
    daemonLabel,
    up ? (status.managed ? "daemon running" : "daemon connected") : "daemon offline"
  );
  setText(
    btnDaemonToggle,
    up && status.managed ? "Stop" : up ? "Connected" : "Start"
  );
  btnDaemonToggle.disabled = up && !status.managed;
  btnAddMagnet.disabled = !up;
  btnOpenTorrent.disabled = !up;
}

async function refreshDaemon() {
  try {
    const status = await window.avalanche.daemonStatus();
    setDaemonUI(status);
    return status;
  } catch {
    setDaemonUI({ healthy: false, managed: false });
    return { healthy: false };
  }
}

function createRow(t) {
  const li = document.createElement("li");
  li.className = "torrent torrent-enter";
  li.dataset.id = String(t.id);
  li.innerHTML = `
    <div class="torrent-main">
      <p class="torrent-title"></p>
      <div class="bar"><span data-bar></span></div>
      <p class="torrent-sub">
        <span class="state" data-state></span>
        <span data-bytes></span>
        <span data-speed></span>
        <span data-peers></span>
        <span data-error class="hidden"></span>
      </p>
    </div>
    <div class="torrent-actions">
      <button type="button" class="ghost" data-act="stop">Stop</button>
      <button type="button" class="danger" data-act="remove">Remove</button>
    </div>
  `;

  li.addEventListener("click", (e) => {
    if (e.target.closest("button")) return;
    openDetails(t.id);
  });

  li.querySelector('[data-act="stop"]').addEventListener("click", async (e) => {
    e.stopPropagation();
    try {
      await window.avalanche.stopTorrent(t.id);
      toast(`Stopping #${t.id}`);
      await refreshTorrents();
    } catch (err) {
      toast(err.message || String(err));
    }
  });
  li.querySelector('[data-act="remove"]').addEventListener("click", async (e) => {
    e.stopPropagation();
    try {
      await window.avalanche.removeTorrent(t.id);
      toast(`Removed #${t.id}`);
      if (selectedId === t.id) closeDetails();
      await refreshTorrents();
    } catch (err) {
      toast(err.message || String(err));
    }
  });

  li.addEventListener(
    "animationend",
    () => li.classList.remove("torrent-enter"),
    { once: true }
  );

  return li;
}

function updateRow(li, t) {
  const title = t.name || t.infohash || `Torrent ${t.id}`;
  setText(li.querySelector(".torrent-title"), title);

  const pct = progressPct(t);
  const bar = li.querySelector("[data-bar]");
  const width = `${pct.toFixed(1)}%`;
  if (bar.style.width !== width) bar.style.width = width;

  const stateEl = li.querySelector("[data-state]");
  const state = t.state || "unknown";
  if (stateEl.dataset.state !== state) stateEl.dataset.state = state;
  setText(stateEl, state);

  setText(li.querySelector("[data-bytes]"), `${formatBytes(t.bytes_done)} / ${formatBytes(t.bytes_total)}`);
  setText(li.querySelector("[data-speed]"), speedLine(t.down_rate, t.up_rate));
  setText(li.querySelector("[data-peers]"), `${t.peers_active || 0} peers`);

  const errEl = li.querySelector("[data-error]");
  if (t.error) {
    errEl.classList.remove("hidden");
    setText(errEl, t.error);
  } else {
    errEl.classList.add("hidden");
    setText(errEl, "");
  }

  const stopBtn = li.querySelector('[data-act="stop"]');
  stopBtn.classList.toggle("hidden", isTerminal(state));
  li.classList.toggle("is-selected", selectedId === t.id);
}

function renderTorrents(list) {
  const items = Array.isArray(list) ? list : [];
  emptyState.classList.toggle("hidden", items.length > 0);

  let downSum = 0;
  let upSum = 0;
  torrentById.clear();
  for (const t of items) {
    torrentById.set(t.id, t);
    downSum += Number(t.down_rate) || 0;
    upSum += Number(t.up_rate) || 0;
  }

  const overall = speedLine(downSum, upSum);
  if (overall !== lastOverall) {
    lastOverall = overall;
    overallSpeed.textContent = overall;
  }

  const meta =
    items.length === 0
      ? "No active transfers"
      : `${items.length} transfer${items.length === 1 ? "" : "s"}`;
  if (meta !== lastMeta) {
    lastMeta = meta;
    torrentMeta.textContent = meta;
  }

  const seen = new Set();
  for (const t of items) {
    const id = t.id;
    seen.add(id);
    let li = rows.get(id);
    if (!li) {
      li = createRow(t);
      rows.set(id, li);
      torrentList.appendChild(li);
    }
    updateRow(li, t);
  }

  for (const [id, li] of rows) {
    if (!seen.has(id)) {
      rows.delete(id);
      li.remove();
      if (selectedId === id) closeDetails();
    }
  }
}

function setDetailTab(tab) {
  activeDetailTab = tab === "peers" ? "peers" : "files";
  for (const btn of detailTabs) {
    const on = btn.dataset.tab === activeDetailTab;
    btn.classList.toggle("is-active", on);
    btn.setAttribute("aria-selected", on ? "true" : "false");
  }
  panelFiles.classList.toggle("hidden", activeDetailTab !== "files");
  panelPeers.classList.toggle("hidden", activeDetailTab !== "peers");
}

function openDetails(id) {
  selectedId = id;
  delete detailPanel.dataset.errToast;
  for (const [rowId, li] of rows) {
    li.classList.toggle("is-selected", rowId === id);
  }
  const t = torrentById.get(id);
  setText(detailTitle, (t && (t.name || t.infohash)) || `Torrent ${id}`);
  setDetailTab(activeDetailTab);
  detailPanel.classList.remove("hidden");
  workspace.classList.add("with-detail");
  refreshDetails();
  if (!detailTimer) {
    detailTimer = setInterval(refreshDetails, 1000);
  }
}

function closeDetails() {
  selectedId = null;
  for (const li of rows.values()) {
    li.classList.remove("is-selected");
  }
  detailPanel.classList.add("hidden");
  workspace.classList.remove("with-detail");
  if (detailTimer) {
    clearInterval(detailTimer);
    detailTimer = null;
  }
}

function renderDetailList(ul, emptyEl, items, renderItem) {
  const list = Array.isArray(items) ? items : [];
  emptyEl.classList.toggle("hidden", list.length > 0);

  const existing = new Map();
  for (const child of ul.children) {
    existing.set(child.dataset.key, child);
  }

  const seen = new Set();
  for (const item of list) {
    const key = renderItem.key(item);
    seen.add(key);
    let li = existing.get(key);
    if (!li) {
      li = document.createElement("li");
      li.className = "detail-item";
      li.dataset.key = key;
      li.innerHTML = `
        <p class="detail-item-title"></p>
        <div class="bar"><span data-bar></span></div>
        <p class="detail-item-meta"><span data-left></span><span data-right></span></p>
      `;
      ul.appendChild(li);
    }
    renderItem.update(li, item);
  }

  for (const [key, li] of existing) {
    if (!seen.has(key)) li.remove();
  }
}

async function refreshDetails() {
  if (selectedId == null || detailRefreshing) return;
  detailRefreshing = true;
  try {
    const detail = await window.avalanche.getDetails(selectedId);
    setText(detailSpeed, speedLine(detail.down_rate, detail.up_rate));

    renderDetailList(detailFiles, detailFilesEmpty, detail.files, {
      key: (f) => f.name,
      update: (li, f) => {
        setText(li.querySelector(".detail-item-title"), f.name || "file");
        const pct = f.total > 0 ? Math.min(100, (100 * f.done) / f.total) : 0;
        const bar = li.querySelector("[data-bar]");
        const width = `${pct.toFixed(1)}%`;
        if (bar.style.width !== width) bar.style.width = width;
        setText(li.querySelector("[data-left]"), `${formatBytes(f.done)} / ${formatBytes(f.total)}`);
        setText(li.querySelector("[data-right]"), `${pct.toFixed(0)}%`);
      },
    });

    renderDetailList(detailPeers, detailPeersEmpty, detail.peers, {
      key: (p) => p.endpoint,
      update: (li, p) => {
        const title = p.client ? `${p.endpoint} · ${p.client}` : p.endpoint || "peer";
        setText(li.querySelector(".detail-item-title"), title);
        const barWrap = li.querySelector(".bar");
        if (barWrap) barWrap.classList.add("hidden");
        setText(li.querySelector("[data-left]"), p.client || "peer");
        setText(li.querySelector("[data-right]"), `▼ ${formatRate(p.down_rate)}`);
      },
    });
  } catch (err) {
    setText(detailSpeed, "details unavailable");
    if (!detailPanel.dataset.errToast) {
      detailPanel.dataset.errToast = "1";
      toast(err.message || String(err));
    }
  } finally {
    detailRefreshing = false;
  }
}

async function refreshTorrents() {
  if (refreshing) return;
  refreshing = true;
  try {
    const status = await refreshDaemon();
    if (!status.healthy) {
      renderTorrents([]);
      if (lastMeta !== "Waiting for daemon") {
        lastMeta = "Waiting for daemon";
        torrentMeta.textContent = lastMeta;
      }
      if (lastOverall !== speedLine(0, 0)) {
        lastOverall = speedLine(0, 0);
        overallSpeed.textContent = lastOverall;
      }
      return;
    }
    const list = await window.avalanche.listTorrents();
    renderTorrents(list);
  } catch (err) {
    toast(err.message || String(err));
  } finally {
    refreshing = false;
  }
}

btnDetailClose.addEventListener("click", () => closeDetails());

for (const btn of detailTabs) {
  btn.addEventListener("click", () => setDetailTab(btn.dataset.tab));
}

btnDaemonToggle.addEventListener("click", async () => {
  const status = await window.avalanche.daemonStatus();
  try {
    if (status.healthy && status.managed) {
      await window.avalanche.daemonStop();
      toast("Stopping daemon");
    } else if (!status.healthy) {
      btnDaemonToggle.disabled = true;
      const res = await window.avalanche.daemonStart();
      if (!res.ok) throw new Error(res.error || "failed to start daemon");
      toast(res.already ? "Already connected" : "Daemon started");
    }
  } catch (err) {
    toast(err.message || String(err));
  } finally {
    lastDaemonKey = "";
    await refreshTorrents();
  }
});

btnAddMagnet.addEventListener("click", async () => {
  const magnet = magnetInput.value.trim();
  if (!magnet) {
    toast("Paste a magnet URI first");
    return;
  }
  try {
    const res = await window.avalanche.addMagnet(magnet);
    magnetInput.value = "";
    toast(`Added torrent #${res.id}`);
    await refreshTorrents();
  } catch (err) {
    toast(err.message || String(err));
  }
});

magnetInput.addEventListener("keydown", (e) => {
  if (e.key === "Enter") btnAddMagnet.click();
});

btnOpenTorrent.addEventListener("click", async () => {
  try {
    const filePath = await window.avalanche.openTorrentDialog();
    if (!filePath) return;
    const res = await window.avalanche.addPath(filePath);
    toast(`Added torrent #${res.id}`);
    await refreshTorrents();
  } catch (err) {
    toast(err.message || String(err));
  }
});

window.avalanche.onDaemonExit(() => {
  lastDaemonKey = "";
  toast("Daemon exited");
  closeDetails();
  refreshTorrents();
});

refreshTorrents();
pollTimer = setInterval(refreshTorrents, 1500);
