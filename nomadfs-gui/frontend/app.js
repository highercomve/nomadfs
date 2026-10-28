// `window.oriel` is injected by Oriel: `invoke()` talks typed Zig.
const { invoke } = window.oriel;
const extensions = window.oriel.extensions;

const $ = (id) => document.getElementById(id);

let configPath = null;
let storageExt = false; // Android: all-files access extension present

let snackTimer;
// The desktop can open folders in the file manager (the same check as mounting).
let canOpenPaths = false;
function snack(msg, ms = 3000, onClick = null) {
  const bar = $("snackbar");
  bar.textContent = msg;
  bar.classList.toggle("clickable", !!onClick);
  bar.title = onClick ? "Open the folder" : "";
  bar.onclick = onClick ? () => { bar.classList.remove("show"); onClick(); } : null;
  bar.classList.add("show");
  clearTimeout(snackTimer);
  snackTimer = setTimeout(() => bar.classList.remove("show"), ms);
}

function setChip(state, label) {
  $("node-chip").dataset.state = state;
  $("node-chip-label").textContent = label;
}

function formatSize(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  const units = ["KB", "MB", "GB", "TB"];
  let v = bytes / 1024;
  let i = 0;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
  return `${v < 10 ? v.toFixed(1) : Math.round(v)} ${units[i]}`;
}

function formatDate(seconds) {
  if (!seconds) return "";
  return new Date(seconds * 1000).toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });
}

const ICONS = {
  device: "M17 1.01L7 1c-1.1 0-2 .9-2 2v18c0 1.1.9 2 2 2h10c1.1 0 2-.9 2-2V3c0-1.1-.9-1.99-2-1.99zM17 19H7V5h10v14z",
  folder: "M10 4H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2h-8l-2-2z",
  file: "M14 2H6c-1.1 0-1.99.9-1.99 2L4 20c0 1.1.89 2 1.99 2H18c1.1 0 2-.9 2-2V8l-6-6zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z",
  image: "M21 19V5c0-1.1-.9-2-2-2H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2zM8.5 13.5l2.5 3.01L14.5 12l4.5 6H5l3.5-4.5z",
  video: "M17 10.5V7c0-.55-.45-1-1-1H4c-.55 0-1 .45-1 1v10c0 .55.45 1 1 1h12c.55 0 1-.45 1-1v-3.5l4 4v-11l-4 4z",
  download: "M19 9h-4V3H9v6H5l7 7 7-7zM5 18v2h14v-2H5z",
  edit: "M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04a1 1 0 0 0 0-1.41l-2.34-2.34a1 1 0 0 0-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z",
  trash: "M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z",
  swarm: "M12 2a3 3 0 0 0-1 5.83V10H7.83A3 3 0 1 0 6 12.83V15a3 3 0 1 0 2 0v-2.17A3 3 0 0 0 9.83 12h4.34A3 3 0 0 0 16 12.83V15a3 3 0 1 0 2 0v-2.17A3 3 0 1 0 16.17 10H13V7.83A3 3 0 0 0 12 2z",
  copy: "M16 1H4c-1.1 0-2 .9-2 2v14h2V3h12V1zm3 4H8c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h11c1.1 0 2-.9 2-2V7c0-1.1-.9-2-2-2zm0 16H8V7h11v14z",
  remove: "M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z",
};

function svg(path) {
  const ns = "http://www.w3.org/2000/svg";
  const el = document.createElementNS(ns, "svg");
  el.setAttribute("viewBox", "0 0 24 24");
  const p = document.createElementNS(ns, "path");
  p.setAttribute("d", path);
  el.appendChild(p);
  return el;
}

function iconFor(name, dir) {
  if (dir) return "folder";
  const ext = name.split(".").pop().toLowerCase();
  if (["jpg", "jpeg", "png", "gif", "webp", "heic", "avif", "bmp"].includes(ext)) return "image";
  if (["mp4", "mov", "mkv", "webm", "avi", "3gp"].includes(ext)) return "video";
  return "file";
}

/** A Material list row: leading icon, headline + meta, optional trailing button. */
function row({ icon, iconClass = "", headline, meta, meta2, monoMeta = false, onClick, action, actions, cols }) {
  if (action && !actions) actions = [action];
  const li = document.createElement("li");
  const lead = document.createElement("span");
  lead.className = `row-icon ${iconClass}`;
  lead.appendChild(svg(ICONS[icon]));
  li.appendChild(lead);
  const text = document.createElement("span");
  text.className = "row-text";
  const h = document.createElement("span");
  h.className = "headline";
  h.textContent = headline;
  text.appendChild(h);
  // `meta` may be several lines (an array), each on its own row.
  const metaLines = (Array.isArray(meta) ? meta : [meta]).map((m) => [m, monoMeta]);
  for (const [line, mono] of [...metaLines, [meta2, true]]) {
    if (!line) continue;
    const m = document.createElement("span");
    m.className = mono ? "meta mono" : "meta";
    m.textContent = line;
    text.appendChild(m);
  }
  li.appendChild(text);
  // Wide layout: Size and Modified columns (CSS hides them on phones).
  if (cols) {
    li.classList.add("has-cols");
    const colList = [["col-size", cols.size], ["col-date", cols.date]];
    if (cols.by !== undefined) colList.push(["col-by", cols.by]);
    for (const [cls, value] of colList) {
      const c = document.createElement("span");
      c.className = `col ${cls}`;
      c.textContent = value || "";
      li.appendChild(c);
    }
    if (!actions) {
      const pad = document.createElement("span");
      pad.className = "col act-spacer";
      li.appendChild(pad);
    }
  }
  if (actions) {
    const box = document.createElement("span");
    box.className = "row-actions";
    for (const a of actions) {
      const b = document.createElement("button");
      b.className = "icon-btn";
      b.title = a.label;
      b.setAttribute("aria-label", a.label);
      b.appendChild(svg(ICONS[a.icon]));
      b.addEventListener("click", (e) => { e.stopPropagation(); a.run(b); });
      box.appendChild(b);
    }
    li.appendChild(box);
  }
  if (onClick) {
    li.classList.add("clickable");
    li.addEventListener("click", onClick);
  }
  return li;
}

// ---- Phones: the "More" sheet holds sections without a bar slot ----

function closeMore() { $("more-sheet").hidden = true; }
$("bar-more").addEventListener("click", () => {
  const sheet = $("more-sheet");
  for (const it of sheet.querySelectorAll(".sheet-item")) it.classList.toggle("active", it.dataset.view === document.body.dataset.view);
  sheet.hidden = !sheet.hidden;
});
$("more-sheet").addEventListener("click", (e) => { if (e.target === $("more-sheet")) closeMore(); });
for (const it of document.querySelectorAll("#more-sheet .sheet-item")) {
  it.addEventListener("click", () => { closeMore(); setView(it.dataset.view); });
}

// ---- Views (wide layout: one section at a time, picked in the drawer) ----

function setView(view) {
  document.body.dataset.view = view;
  for (const item of document.querySelectorAll(".nav-item[data-view], .bar-item[data-view]")) {
    item.classList.toggle("active", item.dataset.view === view);
  }
  $("bar-more").classList.toggle("active", view === "text" || view === "settings" || view === "about");
  window.scrollTo(0, 0);
  try { localStorage.setItem("view", view); } catch {}
  if (view === "settings") { $("devices-refresh").click(); loadBackup(); }
  if (view === "swarm") loadSwarm();
  if (view === "about") loadAbout();
  renderNavDevices();
}

for (const item of document.querySelectorAll(".nav-item[data-view], .bar-item[data-view]")) {
  item.addEventListener("click", () => {
    setView(item.dataset.view);
    if (item.dataset.view === "browse" && path.length) showDevices();
  });
}

/** Reachable devices in the drawer, like a file manager's locations. */
function renderNavDevices() {
  const box = $("nav-devices");
  if (!box) return;
  box.replaceChildren();
  const current = path.length ? path[0].device.peer : null;
  for (const d of devices) {
    const b = document.createElement("button");
    b.className = "nav-item";
    if (document.body.dataset.view === "browse" && d.peer === current) b.classList.add("active");
    b.appendChild(svg(ICONS.device));
    const label = document.createElement("span");
    label.textContent = d.nickname || d.peer.slice(0, 12);
    b.appendChild(label);
    const dot = document.createElement("span");
    dot.className = "dot";
    b.appendChild(dot);
    b.addEventListener("click", () => {
      path = [{ name: label.textContent, device: d }];
      setView("browse");
      showLocation();
    });
    box.appendChild(b);
  }
}

// ---- Node ----

async function refreshState() {
  const state = await invoke("app_info", null);
  // Credit line; the build details stay available as a tooltip.
  const build = `Zig ${state.zig} · ${state.mode} · ${state.dev ? "dev" : "release"}`;
  for (const el of [$("info"), $("nav-info")]) {
    el.textContent = "Built with Zig & Oriel · foreachdeveloper";
    el.title = build;
    el.classList.add("credit");
    el.onclick = () => setView("about");
  }
}

let running = false;

async function nodeState() {
  try {
    const state = await invoke("node_state", null);
    running = state.running;
    $("node-state").textContent = state.running
      ? `Running · device ${state.device_id.slice(0, 12)}…`
      : "Not running";
    setChip(state.running ? "on" : "off", state.running ? "Online" : "Offline");
    $("open-node").disabled = state.running;
    $("close-node").disabled = !state.running;
  } catch {
    $("node-state").textContent = "State unknown";
    setChip("off", "Unknown");
  }
}

async function ensureConfig() {
  if (!configPath) configPath = (await invoke("ensure_config", null)).path;
  return configPath;
}

async function startNode() {
  $("node-state").textContent = "Opening…";
  setChip("busy", "Starting");
  $("open-node").disabled = true;
  try {
    await invoke("node_open", { config_path: await ensureConfig() });
  } catch (err) {
    snack(`Open failed: ${err}`);
  }
  await nodeState();
  if (running) {
    loadShares();
    deviceRetries = 0;
    showDevices();
  }
}

$("open-node").addEventListener("click", startNode);

$("close-node").addEventListener("click", async () => {
  try { await invoke("node_close", null); } catch {}
  await nodeState();
  loadShares();
  showDevices();
});

// ---- Devices: browse other devices' shares ----

// The current location: [] = device list; [{device}] = its shares;
// then one {name, cid} per folder below the share.
let path = [];

function renderCrumbs() {
  $("remote-head").hidden = path.length === 0;
  $("browse-tools").hidden = path.length === 0;
  renderNavDevices();
  const nav = $("crumbs");
  nav.replaceChildren();
  nav.hidden = path.length === 0;
  const parts = [{ label: "Devices" }, ...path.map((p) => ({ label: p.name }))];
  parts.forEach((part, i) => {
    if (i > 0) {
      const sep = document.createElement("span");
      sep.className = "sep";
      sep.textContent = "›";
      nav.appendChild(sep);
    }
    const b = document.createElement("button");
    b.textContent = part.label;
    if (i < parts.length - 1) b.addEventListener("click", () => { path = path.slice(0, i); showLocation(); });
    nav.appendChild(b);
  });
}

function setEmpty(text) {
  const el = $("remote-empty");
  el.hidden = !text;
  el.textContent = text || "";
}

function busy(on) {
  $("remote-refresh").classList.toggle("spin", on);
}

let devices = [];
// Right after the node starts, peers are still being dialed: retry the
// empty device list a few times before settling on "none reachable".
let deviceRetries = 0;

async function showDevices() {
  path = [];
  renderCrumbs();
  const list = $("remote-list");
  if (!running) {
    list.replaceChildren();
    setEmpty("Start the node, then add your other devices under Connect devices.");
    return;
  }
  busy(true);
  try {
    devices = await invoke("remote_devices", null);
  } catch (err) {
    devices = [];
    snack(`Devices failed: ${err}`);
  }
  busy(false);
  renderNavDevices();
  list.replaceChildren();
  if (!devices.length) {
    setEmpty("No devices reachable yet. Add one under Connect devices.");
    if (deviceRetries < 5) {
      deviceRetries++;
      setTimeout(() => { if (path.length === 0) showDevices(); }, 2000);
    }
    return;
  }
  deviceRetries = 0;
  setEmpty("");
  for (const d of devices) {
    const total = d.shares.reduce((s, x) => s + x.size, 0);
    list.appendChild(row({
      icon: "device",
      iconClass: "device",
      headline: d.nickname || d.peer.slice(0, 12),
      meta: d.shares.length
        ? `${d.shares.length} shared folder${d.shares.length === 1 ? "" : "s"} · ${formatSize(total)}`
        : "Shares nothing yet",
      onClick: () => { path = [{ name: d.nickname || d.peer.slice(0, 12), device: d }]; showLocation(); },
    }));
  }
}

// ---- Browse: search and sort ----

// What the open location lists: { device, entries, shares } (shares: a
// device's top level, whose entries are its shared folders).
let browse = null;
// Sort order, remembered across locations and runs; the filter isn't.
let browseSort = { key: "name", dir: 1 };
try { Object.assign(browseSort, JSON.parse(localStorage.getItem("browseSort") || "{}")); } catch {}

function setBrowseSort(key, dir) {
  browseSort = { key, dir };
  try { localStorage.setItem("browseSort", JSON.stringify(browseSort)); } catch {}
  renderBrowse();
}

$("browse-search").addEventListener("input", () => renderBrowse());
$("browse-search").addEventListener("keydown", (e) => {
  if (e.key === "Escape" && e.target.value) { e.target.value = ""; renderBrowse(); e.stopPropagation(); }
});
// "/" or Ctrl+F searches the open folder (not while typing elsewhere).
document.addEventListener("keydown", (e) => {
  if (document.body.dataset.view !== "browse" || $("browse-tools").hidden) return;
  const typing = /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement?.tagName || "");
  if ((e.key === "/" && !typing) || ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "f")) {
    e.preventDefault();
    $("browse-search").focus();
    $("browse-search").select();
  }
});
$("browse-sort").addEventListener("change", (e) => setBrowseSort(e.target.value, browseSort.dir));
$("browse-dir").addEventListener("click", () => setBrowseSort(browseSort.key, -browseSort.dir));
// Wide windows: the column headers sort too; a second click reverses.
for (const th of document.querySelectorAll("#remote-head .th-sort")) {
  th.addEventListener("click", () => {
    const key = th.dataset.sort;
    // Sizes and dates read best biggest/newest first.
    const first = key === "name" ? 1 : -1;
    setBrowseSort(key, browseSort.key === key ? -browseSort.dir : first);
  });
}

function compareEntries(a, b) {
  // Folders stay above files whatever the order.
  if (a.dir !== b.dir) return b.dir - a.dir;
  const { key, dir } = browseSort;
  let c = 0;
  if (key === "size") c = a.size - b.size;
  else if (key === "mtime") c = a.mtime - b.mtime;
  if (c === 0) c = a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: "base" });
  return c * dir;
}

function renderSortControls() {
  $("browse-sort").value = browseSort.key;
  const btn = $("browse-dir");
  btn.title = browseSort.dir > 0 ? "Ascending" : "Descending";
  btn.classList.toggle("desc", browseSort.dir < 0);
  for (const th of document.querySelectorAll("#remote-head .th-sort")) {
    th.classList.toggle("sorted", th.dataset.sort === browseSort.key);
    th.classList.toggle("desc", browseSort.dir < 0);
  }
}

function renderBrowse() {
  if (!browse) return;
  renderSortControls();
  const { device, entries, shares } = browse;
  const query = $("browse-search").value.trim().toLocaleLowerCase();
  const shown = entries
    .filter((e) => !query || e.name.toLocaleLowerCase().includes(query))
    .sort(compareEntries);
  const list = $("remote-list");
  list.replaceChildren();
  if (!shown.length) {
    setEmpty(query ? `Nothing here matches "${$("browse-search").value.trim()}".`
      : shares ? "This device shares nothing yet." : "Empty folder.");
    return;
  }
  setEmpty("");
  // Previews step through the files in the order shown.
  const files = shown.filter((x) => !x.dir);
  for (const e of shown) {
    if (e.dir) {
      list.appendChild(row({
        icon: "folder",
        iconClass: "folder",
        headline: e.name,
        meta: shares ? `${formatSize(e.size)} · updated ${formatDate(e.mtime)}` : formatSize(e.size),
        cols: { size: formatSize(e.size), date: formatDate(e.mtime) },
        onClick: () => { path.push({ name: e.name, cid: e.cid }); showLocation(); },
      }));
    } else {
      const fetchIt = (btn) => downloadFile(device, e, btn);
      list.appendChild(row({
        icon: iconFor(e.name, false),
        headline: e.name,
        meta: `${formatSize(e.size)} · ${formatDate(e.mtime)}`,
        cols: { size: formatSize(e.size), date: formatDate(e.mtime) },
        onClick: () => openPreview(deviceSource(device), files, files.indexOf(e)),
        action: { icon: "download", label: "Download", run: fetchIt },
      }));
    }
  }
}

async function showLocation() {
  if (path.length === 0) return showDevices();
  renderCrumbs();
  // A new place starts unfiltered.
  $("browse-search").value = "";
  const device = path[0].device;

  if (path.length === 1) {
    browse = { device, shares: true, entries: device.shares.map((sh) => ({ ...sh, dir: true })) };
    renderBrowse();
    return;
  }

  const here = path[path.length - 1];
  busy(true);
  let entries;
  try {
    entries = await invoke("browse", { peer: device.peer, cid: here.cid });
  } catch (err) {
    busy(false);
    snack(`Could not open ${here.name}: ${err}`);
    return;
  }
  busy(false);
  browse = { device, shares: false, entries };
  renderBrowse();
}

const downloading = new Set();

/** "Saved to …"; on the desktop a click opens the folder it landed in. */
function savedSnack(file) {
  if (!canOpenPaths) return snack(`Saved to ${file}`, 5000);
  const dir = file.slice(0, file.lastIndexOf("/")) || "/";
  snack(`Saved to ${file} · click to open the folder`, 8000, () => {
    invoke("open_path", { path: dir }).catch((err) => snack(`Couldn't open the folder: ${err}`));
  });
}

async function downloadFile(device, entry, btn) {
  if (downloading.has(entry.cid)) return;
  downloading.add(entry.cid);
  if (btn) btn.classList.add("spin");
  snack(`Downloading ${entry.name} (${formatSize(entry.size)})…`, 60000);
  try {
    const res = await invoke("download", { peer: device.peer, cid: entry.cid, name: entry.name });
    savedSnack(res.path);
  } catch (err) {
    snack(`Download failed: ${err}`);
  }
  downloading.delete(entry.cid);
  if (btn) btn.classList.remove("spin");
}

// ---- Preview ----

const KINDS = {
  image: { ext: ["jpg", "jpeg", "png", "gif", "webp", "bmp", "svg", "avif", "heic"], max: 64 << 20 },
  // Camcorder MPEG-TS (.mts/.m2ts), WMV, MXF and the rest play in the native
  // player (oriel.video), which takes what the system's media stack plays.
  video: { ext: ["mp4", "webm", "mov", "m4v", "mkv", "3gp", "mts", "m2ts", "avi", "wmv", "flv", "mpg", "mpeg", "mxf", "ogv", "vob"], max: 512 << 20 },
  audio: { ext: ["mp3", "m4a", "aac", "ogg", "opus", "wav", "flac"], max: 256 << 20 },
  pdf: { ext: ["pdf"], max: 64 << 20 },
  text: { ext: ["txt", "md", "json", "log", "csv", "xml", "yaml", "yml", "toml", "ini", "conf", "zig", "c", "h", "js", "ts", "py", "rs", "go", "sh", "html", "css"], max: 1 << 20 },
};
const MIME = {
  jpg: "image/jpeg", jpeg: "image/jpeg", png: "image/png", gif: "image/gif", webp: "image/webp", bmp: "image/bmp",
  svg: "image/svg+xml", avif: "image/avif", heic: "image/heic", mp4: "video/mp4", m4v: "video/mp4", webm: "video/webm",
  mov: "video/quicktime", mkv: "video/x-matroska", "3gp": "video/3gpp", mp3: "audio/mpeg", m4a: "audio/mp4",
  aac: "audio/aac", ogg: "audio/ogg", opus: "audio/ogg", wav: "audio/wav", flac: "audio/flac", pdf: "application/pdf",
};
const RANGE = 4 << 20;

function kindOf(name) {
  const ext = name.includes(".") ? name.split(".").pop().toLowerCase() : "";
  for (const [kind, k] of Object.entries(KINDS)) if (k.ext.includes(ext)) return { kind, ext };
  return { kind: null, ext };
}

let pv = null; // { source, files, index, token, url }

/** Where a preview reads from: a device's share... */
function deviceSource(device) {
  return {
    read: (e, offset, len) => invoke("read_range", { peer: device.peer, cid: e.cid, offset, len }),
    mediaUrl: (e) => invoke("media_url", { kind: "device", id: device.peer, cid: e.cid, size: e.size, name: e.name }),
    download: (e, btn) => downloadFile(device, e, btn),
  };
}
/** ...or the swarm folder (the device that added it, then anyone). */
const swarmSource = {
  read: (e, offset, len) => invoke("swarm_read_range", { cid: e.cid, author_id: e.author_id, offset, len }),
  mediaUrl: (e) => invoke("media_url", { kind: "swarm", id: e.author_id, cid: e.cid, size: e.size, name: e.name }),
  download: (e, btn) => swarmDownload(e, btn),
};

function previewMessage(icon, text, extra) {
  const box = document.createElement("div");
  box.className = "preview-msg";
  box.appendChild(svg(ICONS[icon]));
  const p = document.createElement("p");
  p.textContent = text;
  box.appendChild(p);
  if (extra) box.appendChild(extra);
  $("pv-body").replaceChildren(box);
  return box;
}

function decodeBase64(b64) {
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

function openPreview(source, files, index) {
  pv = { source, files, index, token: 0, url: null };
  $("preview").hidden = false;
  showPreview();
}

/** Stops a streaming player so it stops fetching ranges. */
function stopMedia() {
  for (const m of $("pv-body").querySelectorAll("video, audio")) {
    m.pause();
    m.removeAttribute("src");
    m.load();
  }
}

function closePreview() {
  if (!pv) return;
  stopMedia();
  nativeVideo?.close().catch(() => {});
  pv.token++;
  if (pv.url) URL.revokeObjectURL(pv.url);
  pv = null;
  $("pv-body").replaceChildren();
  $("preview").hidden = true;
}

// The native player: GPU rendering and every format the system plays,
// shown over the whole window. Null where the platform has none.
const nativeVideo = window.oriel.video?.available ? window.oriel.video : null;

async function streamPreview(entry, kind, token) {
  let url;
  try {
    url = await pv.source.mediaUrl(entry);
  } catch (err) {
    if (pv && token === pv.token) previewMessage("file", `Preview failed: ${err}`);
    return;
  }
  if (!pv || token !== pv.token) return;
  if (kind === "video" && nativeVideo) return playNative(entry, url, token);
  inPagePlayer(kind, url, token);
}

/** Plays in the native player; the preview offers to play it again once
 * it's closed. Falls back to the page's player if the native one fails. */
async function playNative(entry, url, token) {
  const again = document.createElement("button");
  again.className = "btn filled";
  again.textContent = "Play again";
  again.addEventListener("click", () => playNative(entry, url, token));
  previewMessage("video", "Playing in the video player. Esc or its close button comes back here.", again);
  try {
    await nativeVideo.play({ url, title: entry.name });
  } catch (err) {
    if (pv && token === pv.token) inPagePlayer("video", url, token);
  }
}

window.oriel.listen?.("video:error", ({ message }) => {
  if (pv) snack(`This video can't play: ${message || "unsupported format"}. Download it to open it in another app.`, 6000);
});

function inPagePlayer(kind, url, token) {
  const el = document.createElement(kind);
  el.controls = true;
  el.autoplay = true;
  el.preload = "auto";
  el.src = url;
  el.addEventListener("error", () => {
    if (!pv || token !== pv.token) return;
    previewMessage(kind === "video" ? "video" : "file",
      `This ${kind === "video" ? "video" : "audio file"} can't play here (its format may not be supported). Download it to open it in another app.`);
  });
  $("pv-body").replaceChildren(el);
}

async function showPreview() {
  stopMedia();
  const token = ++pv.token;
  if (pv.url) { URL.revokeObjectURL(pv.url); pv.url = null; }
  const entry = pv.files[pv.index];
  $("pv-name").textContent = entry.name;
  $("pv-meta").textContent = `${formatSize(entry.size)} · ${formatDate(entry.mtime)} · ${pv.index + 1} of ${pv.files.length}`;
  $("pv-prev").disabled = pv.index === 0;
  $("pv-next").disabled = pv.index === pv.files.length - 1;

  const { kind, ext } = kindOf(entry.name);
  if (!kind) return previewMessage("file", "No preview for this kind of file.");
  // Video and audio stream: the player asks for byte ranges as it plays
  // and seeks, so it starts at once and size doesn't matter.
  if (kind === "video" || kind === "audio") return streamPreview(entry, kind, token);

  const limit = KINDS[kind].max;
  if (kind !== "text" && entry.size > limit) {
    return previewMessage(kind === "image" ? "image" : "video", `Too large to preview here (${formatSize(entry.size)}). Download it or open it from the mount.`);
  }

  const total = kind === "text" ? Math.min(entry.size, limit) : entry.size;
  const bar = document.createElement("div");
  bar.className = "progress determinate";
  const msg = previewMessage(kind === "image" ? "image" : kind === "video" ? "video" : "file", `Loading ${formatSize(total)}…`, bar);
  const parts = [];
  let offset = 0;
  try {
    while (offset < total) {
      const len = Math.min(RANGE, total - offset);
      const b64 = await pv.source.read(entry, offset, len);
      if (!pv || token !== pv.token) return; // closed or moved on
      const bytes = decodeBase64(b64);
      if (bytes.length === 0) break;
      parts.push(bytes);
      offset += bytes.length;
      bar.style.setProperty("--p", `${Math.round((offset / Math.max(total, 1)) * 100)}%`);
      msg.querySelector("p").textContent = `Loading ${formatSize(offset)} of ${formatSize(total)}…`;
    }
  } catch (err) {
    if (pv && token === pv.token) previewMessage("file", `Preview failed: ${err}`);
    return;
  }

  const body = $("pv-body");
  if (kind === "text") {
    const pre = document.createElement("pre");
    pre.textContent = new TextDecoder().decode(concat(parts));
    if (entry.size > total) pre.textContent += `\n\n… (first ${formatSize(total)} of ${formatSize(entry.size)})`;
    body.replaceChildren(pre);
    return;
  }
  pv.url = URL.createObjectURL(new Blob(parts, { type: MIME[ext] || "application/octet-stream" }));
  let el;
  if (kind === "image") { el = document.createElement("img"); el.alt = entry.name; }
  else if (kind === "video") { el = document.createElement("video"); el.controls = true; el.autoplay = true; }
  else if (kind === "audio") { el = document.createElement("audio"); el.controls = true; el.autoplay = true; }
  else { el = document.createElement("iframe"); el.title = entry.name; }
  el.src = pv.url;
  el.addEventListener("error", () => {
    if (!pv || token !== pv.token) return;
    const what = kind === "video" ? "video" : kind === "audio" ? "audio file" : "file";
    previewMessage(kind === "video" ? "video" : "file",
      `This ${what} uses a format this device can't play here. Download it, or open it from the mount with your usual player.`);
  });
  body.replaceChildren(el);
}

function concat(parts) {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) { out.set(p, at); at += p.length; }
  return out;
}

$("pv-close").addEventListener("click", closePreview);
$("preview").addEventListener("click", (e) => { if (e.target === $("preview")) closePreview(); });
$("pv-prev").addEventListener("click", () => { if (pv && pv.index > 0) { pv.index--; showPreview(); } });
$("pv-next").addEventListener("click", () => { if (pv && pv.index < pv.files.length - 1) { pv.index++; showPreview(); } });
$("pv-download").addEventListener("click", () => { if (pv) pv.source.download(pv.files[pv.index], null); });

// Swipe left or right on a touch screen for the next or previous file. The
// photo follows the finger; a short or mostly vertical drag springs back.
// Video and audio keep their controls, text its scrolling.
{
  const body = $("pv-body");
  let swipe = null;
  const springBack = (img) => {
    if (!img) return;
    img.style.transition = "transform 0.2s ease";
    img.style.transform = "";
    img.addEventListener("transitionend", () => { img.style.transition = ""; }, { once: true });
  };
  body.addEventListener("pointerdown", (e) => {
    if (!pv || e.pointerType === "mouse" || e.target.closest("video, audio, pre")) return;
    swipe = { id: e.pointerId, x: e.clientX, y: e.clientY, t: performance.now() };
  });
  body.addEventListener("pointermove", (e) => {
    if (!swipe || e.pointerId !== swipe.id) return;
    const dx = e.clientX - swipe.x;
    const img = body.querySelector("img");
    if (img && Math.abs(dx) > Math.abs(e.clientY - swipe.y)) img.style.transform = `translateX(${dx}px)`;
  });
  body.addEventListener("pointerup", (e) => {
    if (!swipe || e.pointerId !== swipe.id) return;
    const dx = e.clientX - swipe.x;
    const dy = e.clientY - swipe.y;
    const quick = performance.now() - swipe.t < 600;
    swipe = null;
    const sideways = Math.abs(dx) > 60 && Math.abs(dx) > 1.5 * Math.abs(dy);
    if (sideways && (quick || Math.abs(dx) > body.clientWidth / 3)) {
      const button = dx < 0 ? $("pv-next") : $("pv-prev");
      if (!button.disabled) return button.click();
    }
    springBack(body.querySelector("img"));
  });
  body.addEventListener("pointercancel", () => {
    swipe = null;
    springBack(body.querySelector("img"));
  });
}
document.addEventListener("keydown", (e) => {
  if (!pv) return;
  if (e.key === "Escape") closePreview();
  else if (e.key === "ArrowLeft") $("pv-prev").click();
  else if (e.key === "ArrowRight") $("pv-next").click();
});

// ---- Mount (desktop Linux) ----

let mountPath = "";
let mounted = false;

function renderMount(status) {
  mounted = status.mounted;
  if (status.mounted) mountPath = status.path;
  else if (!mountPath) mountPath = status.default_path;
  $("mount-path").textContent = mountPath;
  $("mount-state").dataset.state = mounted ? "on" : "off";
  $("mount-label").textContent = mounted ? `Mounted at ${mountPath}` : "Not mounted";
  $("mount-toggle").textContent = mounted ? "Unmount" : "Mount";
  $("mount-open").hidden = !mounted;
  $("mount-change").disabled = mounted;
}

async function loadMount() {
  let status;
  try { status = await invoke("mount_status", null); } catch { return; }
  canOpenPaths = status.supported;
  $("nav-mount").hidden = !status.supported;
  if (!status.supported && document.body.dataset.view === "mount") setView("browse");
  renderMount(status);
}

// The tray can mount or unmount while the window is hidden.
document.addEventListener("visibilitychange", () => { if (document.visibilityState === "visible") loadMount(); });

$("mount-toggle").addEventListener("click", async () => {
  const btn = $("mount-toggle");
  btn.disabled = true;
  $("mount-state").dataset.state = "busy";
  $("mount-label").textContent = mounted ? "Unmounting…" : "Mounting…";
  try {
    if (mounted) {
      await invoke("mount_stop", null);
      snack("Unmounted");
    } else {
      if (!running) throw new Error("Start the node first");
      await invoke("mount_start", { path: mountPath });
      snack(`Mounted at ${mountPath}`);
    }
  } catch (err) {
    snack(`${mounted ? "Unmount" : "Mount"} failed: ${err}`);
  }
  btn.disabled = false;
  loadMount();
});

$("mount-change").addEventListener("click", async () => {
  try {
    const picked = await invoke("pick_folder", null);
    if (picked && typeof picked.path === "string" && picked.path) { mountPath = picked.path; $("mount-path").textContent = mountPath; }
  } catch (err) {
    snack(`Folder picker failed: ${err}`);
  }
});

$("mount-open").addEventListener("click", async () => {
  try { await invoke("open_path", { path: mountPath }); } catch (err) { snack(`Couldn't open the folder: ${err}`); }
});

$("remote-refresh").addEventListener("click", () => (path.length ? showLocation() : showDevices()));

// ---- Swarm folder: one folder all devices read and write ----

let swarmDir = ""; // "" = top; "a/b" below

function swarmCrumbs() {
  const nav = $("swarm-crumbs");
  nav.replaceChildren();
  const parts = swarmDir ? swarmDir.split("/") : [];
  const all = [{ label: "Swarm", dir: "" }, ...parts.map((p, i) => ({ label: p, dir: parts.slice(0, i + 1).join("/") }))];
  all.forEach((c, i) => {
    if (i > 0) {
      const sep = document.createElement("span");
      sep.className = "sep";
      sep.textContent = "›";
      nav.appendChild(sep);
    }
    const b = document.createElement("button");
    b.textContent = c.label;
    if (i < all.length - 1) b.addEventListener("click", () => { swarmDir = c.dir; loadSwarm(); });
    nav.appendChild(b);
  });
}

function swarmStatusText(st) {
  if (!running) return "Node stopped";
  const devices = st.peers_synced === 1 ? "1 device" : `${st.peers_synced} devices`;
  const when = st.last_sync ? timeAgo(st.last_sync * 1000) : "not yet";
  return `${st.entries} item${st.entries === 1 ? "" : "s"} · synced with ${devices} · ${when}`;
}

async function loadSwarm() {
  swarmCrumbs();
  const list = $("swarm-list");
  if (!running) {
    list.replaceChildren();
    $("swarm-empty").hidden = false;
    $("swarm-empty").textContent = "Start the node to see the swarm folder.";
    $("swarm-status").textContent = "Node stopped";
    return;
  }
  let res;
  try {
    res = await invoke("swarm_list", { dir: swarmDir });
  } catch (err) {
    snack(`Swarm folder: ${err}`);
    return;
  }
  $("swarm-status").textContent = swarmStatusText(res);
  const items = res.items.sort((a, b) => (b.dir - a.dir) || a.name.localeCompare(b.name));
  if (!items.length && swarmDir) { // folder vanished (deleted elsewhere): go up
    swarmDir = swarmDir.split("/").slice(0, -1).join("/");
    return loadSwarm();
  }
  const files = items.filter((x) => !x.dir);
  list.replaceChildren();
  $("swarm-empty").hidden = items.length > 0;
  $("swarm-empty").textContent = "Empty. Add a file, or create a folder; every device sees it.";
  for (const it of items) {
    const by = it.author || "";
    const actions = [
      { icon: "edit", label: `Rename ${it.name}`, run: () => swarmRenamePrompt(it) },
      { icon: "trash", label: `Delete ${it.name}`, run: () => swarmDeleteConfirm(it) },
    ];
    if (!it.dir) actions.unshift({ icon: "download", label: "Download", run: (btn) => swarmDownload(it, btn) });
    list.appendChild(row({
      icon: it.dir ? "folder" : iconFor(it.name, false),
      iconClass: it.dir ? "folder" : "",
      headline: it.name,
      meta: it.dir ? formatSize(it.size) : `${formatSize(it.size)} · ${formatDate(it.mtime)}${by ? ` · ${by}` : ""}`,
      cols: { size: formatSize(it.size), date: formatDate(it.mtime), by },
      onClick: it.dir
        ? () => { swarmDir = it.path; loadSwarm(); }
        : () => openPreview(swarmSource, files, files.indexOf(it)),
      actions,
    }));
  }
}

async function swarmDownload(it, btn) {
  if (downloading.has(it.cid)) return;
  downloading.add(it.cid);
  if (btn) btn.classList.add("spin");
  snack(`Downloading ${it.name} (${formatSize(it.size)})…`, 60000);
  try {
    const res = await invoke("swarm_download", { cid: it.cid, author_id: it.author_id, name: it.name });
    savedSnack(res.path);
  } catch (err) {
    snack(`${err}`.includes("BlockNotFound") || `${err}`.includes("AllAddressesFailed")
      ? `${it.name} isn't reachable: the device that added it is offline.`
      : `Download failed: ${err}`);
  }
  downloading.delete(it.cid);
  if (btn) btn.classList.remove("spin");
}

/** A small dialog: ask for a name, or confirm. Resolves null on cancel. */
function askDialog({ title, text = "", value = null, confirm = "OK", danger = false }) {
  return new Promise((resolve) => {
    const dlg = $("ask");
    $("ask-title").textContent = title;
    $("ask-text").textContent = text;
    $("ask-text").hidden = !text;
    const field = $("ask-field");
    field.hidden = value === null;
    $("ask-input").value = value ?? "";
    const ok = $("ask-ok");
    ok.textContent = confirm;
    ok.classList.toggle("danger", danger);
    dlg.hidden = false;
    if (value !== null) {
      const input = $("ask-input");
      input.focus();
      const dot = input.value.lastIndexOf(".");
      input.setSelectionRange(0, dot > 0 ? dot : input.value.length);
    } else ok.focus();
    const done = (result) => {
      dlg.hidden = true;
      $("ask-form").onsubmit = null;
      $("ask-cancel").onclick = null;
      resolve(result);
    };
    $("ask-form").onsubmit = (e) => { e.preventDefault(); done(value === null ? true : $("ask-input").value.trim()); };
    $("ask-cancel").onclick = () => done(null);
  });
}

async function swarmRenamePrompt(it) {
  const name = await askDialog({ title: `Rename ${it.dir ? "folder" : "file"}`, value: it.name, confirm: "Rename" });
  if (!name || name === it.name) return;
  try {
    await invoke("swarm_rename", { path: it.path, name });
    snack(`Renamed to ${name}`);
  } catch (err) {
    snack(`${err}`.includes("PathAlreadyExists") ? `"${name}" already exists here.` : `Rename failed: ${err}`);
  }
  loadSwarm();
}

async function swarmDeleteConfirm(it) {
  const ok = await askDialog({
    title: `Delete ${it.name}?`,
    text: it.dir ? "The folder and everything in it disappear from every device." : "It disappears from every device.",
    confirm: "Delete",
    danger: true,
  });
  if (!ok) return;
  try {
    await invoke("swarm_delete", { path: it.path });
    snack(`Deleted ${it.name}`);
  } catch (err) {
    snack(`Delete failed: ${err}`);
  }
  loadSwarm();
}

$("swarm-add").addEventListener("click", async () => {
  if (!running) return snack("Start the node first");
  try {
    const name = await invoke("swarm_add_file", { dir: swarmDir });
    if (name) snack(`Added ${name}: every device can see it now`);
  } catch (err) {
    snack(`Add failed: ${err}`);
  }
  loadSwarm();
});

$("swarm-mkdir").addEventListener("click", async () => {
  if (!running) return snack("Start the node first");
  const name = await askDialog({ title: "New folder", value: "New folder", confirm: "Create" });
  if (!name) return;
  try {
    await invoke("swarm_mkdir", { dir: swarmDir, name });
  } catch (err) {
    snack(`Couldn't create it: ${err}`);
  }
  loadSwarm();
});

$("swarm-sync").addEventListener("click", async () => {
  const btn = $("swarm-sync");
  btn.classList.add("spin");
  try {
    const changed = await invoke("swarm_sync", null);
    snack(changed ? `${changed} change${changed === 1 ? "" : "s"} from your devices` : "Up to date");
  } catch (err) {
    snack(`Sync failed: ${err}`);
  }
  btn.classList.remove("spin");
  loadSwarm();
});

// While the view is open, pick up other devices' changes.
setInterval(() => { if (document.body.dataset.view === "swarm" && !document.hidden && running) loadSwarm(); }, 10000);

// Devices come and go (a phone wakes, a laptop rejoins): keep the drawer's
// list current, and the Browse list when it shows the devices.
const deviceKey = (list) => list.map((d) => d.peer).sort().join(",");
setInterval(async () => {
  if (!running || document.hidden) return;
  let now;
  try { now = await invoke("remote_devices", null); } catch { return; }
  if (deviceKey(now) === deviceKey(devices)) return;
  if (document.body.dataset.view === "browse" && path.length === 0) {
    showDevices();
  } else {
    devices = now;
    renderNavDevices();
  }
}, 10000);

// ---- Shared folders ----

async function loadShares() {
  const list = $("shares-list");
  list.replaceChildren();
  if (!running) return;
  let shares = [];
  try {
    shares = await invoke("shares_local", null);
  } catch (err) {
    snack(`Shares failed: ${err}`);
    return;
  }
  for (const s of shares) {
    list.appendChild(row({
      icon: "folder",
      iconClass: "folder",
      headline: s.name,
      meta: !s.ready ? `Scanning… ${s.path}`
        : s.indexing ? `Indexing… ${s.files} files so far · ${formatSize(s.size)} · ${s.path}`
        : `${s.files} files · ${formatSize(s.size)} · ${s.path}`,
      action: { icon: "remove", label: `Stop sharing ${s.name}`, run: () => removeShare(s.name) },
    }));
  }
}

async function removeShare(name) {
  try {
    await invoke("share_remove", { config_path: await ensureConfig(), name });
    snack(`Stopped sharing ${name}`);
  } catch (err) {
    snack(`Remove failed: ${err}`);
  }
  loadShares();
}

/** Shows the share form for `path`, with the name pre-filled. */
function stageShare(path, name) {
  path = String(path || "");
  $("share-path").textContent = path;
  $("share-name").value = name || path.split("/").filter(Boolean).pop() || "";
  $("share-form").hidden = false;
}

async function pickFolder() {
  if (!running) {
    snack("Start the node first");
    return;
  }
  try {
    const picked = await invoke("pick_folder", null);
    if (picked == null) return; // cancelled
    if (typeof picked.path !== "string" || !picked.path) {
      console.warn("pick_folder returned", picked);
      snack("The folder picker didn't return a folder. Try again.");
      return;
    }
    stageShare(picked.path, picked.name);
  } catch (err) {
    snack(`${err}`.includes("UnsupportedFolder")
      ? "That folder isn't on this device's storage. Pick one from internal storage or an SD card."
      : `Folder picker failed: ${err}`);
  }
}

$("share-pick").addEventListener("click", pickFolder);
$("share-repick").addEventListener("click", pickFolder);
$("share-cancel").addEventListener("click", () => { $("share-form").hidden = true; });

$("share-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const name = $("share-name").value.trim();
  const sharePath = $("share-path").textContent;
  if (!name || !sharePath) {
    snack("Give the share a name");
    return;
  }
  const btn = e.submitter;
  if (btn) btn.disabled = true;
  snack(`Indexing ${sharePath}…`, 120000);
  try {
    await invoke("share_add", { config_path: await ensureConfig(), name, path: sharePath });
    snack(`Sharing ${name}`);
    $("share-form").hidden = true;
  } catch (err) {
    snack(`Share failed: ${err}`);
  }
  if (btn) btn.disabled = false;
  loadShares();
});

// Android: storage permission and one-tap presets for the usual folders.
async function storageSetup() {
  if (!extensions) return;
  let info;
  try {
    info = await extensions.call("nomadfs.storage", "info", {});
  } catch {
    return; // not on Android
  }
  storageExt = true;
  $("storage-banner").hidden = info.granted;
  const presets = $("share-presets");
  presets.replaceChildren();
  for (const [label, p] of [["Camera", info.camera], ["Pictures", info.pictures], ["Documents", info.documents], ["Download", info.downloads]]) {
    const b = document.createElement("button");
    b.type = "button";
    b.textContent = label;
    b.addEventListener("click", () => stageShare(p, label));
    presets.appendChild(b);
  }
  presets.hidden = false;
  return info;
}

$("storage-grant").addEventListener("click", async () => {
  try { await extensions.call("nomadfs.storage", "request", {}); } catch (err) { snack(`${err}`); }
});

// Coming back from the settings page: re-check the grant.
document.addEventListener("visibilitychange", async () => {
  if (document.visibilityState !== "visible" || !storageExt) return;
  try {
    const s = await extensions.call("nomadfs.storage", "status", {});
    $("storage-banner").hidden = s.granted;
  } catch {}
});

// ---- Connect devices ----

async function loadJoinInfo() {
  try {
    const info = await invoke("join_info", { config_path: await ensureConfig() });
    $("device-name").textContent = info.nickname;
    $("nick-in").value = info.nickname;
    return info;
  } catch (err) {
    snack(`Couldn't read this device's settings: ${err}`);
  }
}

// One-time invites: the code carries a throwaway token, never the swarm key.
let inviteTimer = null;

function renderInvite(info) {
  const active = info.state !== "none";
  $("invite-idle").hidden = active && info.state === "waiting";
  $("invite-active").hidden = !active;
  if (!active) return;
  const status = $("invite-active").querySelector(".invite-status");
  status.dataset.state = info.state;
  $("invite-code").textContent = info.state === "waiting" ? info.code : "";
  // Only replace the QR when the code changes (it's re-sent every second).
  const qr = $("invite-qr");
  if (info.state !== "waiting") { qr.replaceChildren(); qr.dataset.code = ""; }
  else if (qr.dataset.code !== info.code && info.qr_svg) {
    qr.innerHTML = info.qr_svg; // SVG generated by our own encoder
    qr.dataset.code = info.code;
  }
  $("invite-copy").hidden = info.state !== "waiting";
  $("invite-cancel").textContent = info.state === "waiting" ? "Cancel" : "Done";
  if (info.state === "waiting") {
    $("invite-label").textContent = "Waiting for the other device…";
    const m = Math.floor(info.expires_in / 60), sec = String(info.expires_in % 60).padStart(2, "0");
    $("invite-timer").textContent = `${m}:${sec}`;
  } else if (info.state === "joined") {
    $("invite-label").textContent = `${info.peer || "A device"} joined`;
    $("invite-timer").textContent = "";
  } else {
    $("invite-label").textContent = "Invite expired";
    $("invite-timer").textContent = "";
  }
}

async function pollInvite() {
  let info;
  try { info = await invoke("invite_status", { config_path: await ensureConfig() }); } catch { return; }
  renderInvite(info);
  if (info.state !== "waiting") {
    clearInterval(inviteTimer);
    inviteTimer = null;
    if (info.state === "joined") {
      snack(`${info.peer || "A device"} joined your devices`);
      setTimeout(showDevices, 1500);
    }
  }
}

$("invite-create").addEventListener("click", async () => {
  if (!running) {
    snack("Start the node first");
    return;
  }
  try {
    renderInvite(await invoke("invite_create", { config_path: await ensureConfig() }));
    clearInterval(inviteTimer);
    inviteTimer = setInterval(pollInvite, 1000);
  } catch (err) {
    snack(`Couldn't create an invite: ${err}`);
  }
});

$("invite-cancel").addEventListener("click", async () => {
  try { await invoke("invite_cancel", null); } catch {}
  clearInterval(inviteTimer);
  inviteTimer = null;
  renderInvite({ state: "none" });
  $("invite-idle").hidden = false;
});

$("invite-copy").addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText($("invite-code").textContent);
    snack("Invite copied");
  } catch {
    snack("Clipboard unavailable");
  }
});

// ---- QR scanning (camera + BarcodeDetector where the web view has it) ----

let scan = null; // { stream, timer }

async function scannerAvailable() {
  if (!("BarcodeDetector" in window) || !navigator.mediaDevices?.getUserMedia) return false;
  try { return (await BarcodeDetector.getSupportedFormats()).includes("qr_code"); } catch { return false; }
}

async function openScanner() {
  let stream;
  try {
    stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: "environment", width: { ideal: 1280 }, height: { ideal: 720 } }, audio: false });
  } catch (err) {
    snack(`Camera unavailable: ${err.message || err}`);
    return;
  }
  const video = $("scan-video");
  video.srcObject = stream;
  $("scanner").hidden = false;
  await video.play().catch(() => {});
  const detector = new BarcodeDetector({ formats: ["qr_code"] });
  scan = { stream, timer: null };
  const tick = async () => {
    if (!scan) return;
    try {
      const codes = await detector.detect(video);
      const hit = codes.map((c) => c.rawValue).find((v) => v && v.startsWith("nomadfs://invite?"));
      if (hit) {
        closeScanner();
        if (navigator.vibrate) navigator.vibrate(60);
        $("join-in").value = hit;
        $("join-form").requestSubmit();
        return;
      }
    } catch {}
    if (scan) scan.timer = setTimeout(tick, 200);
  };
  tick();
}

function closeScanner() {
  if (!scan) return;
  clearTimeout(scan.timer);
  for (const t of scan.stream.getTracks()) t.stop();
  $("scan-video").srcObject = null;
  $("scanner").hidden = true;
  scan = null;
}

$("scan-open").addEventListener("click", openScanner);
$("scan-close").addEventListener("click", closeScanner);
document.addEventListener("keydown", (e) => { if (e.key === "Escape" && scan) closeScanner(); });
scannerAvailable().then((ok) => { $("scan-open").hidden = !ok; });

$("join-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const code = $("join-in").value.trim();
  if (!code) return;
  const btn = e.submitter;
  if (btn) btn.disabled = true;
  snack("Joining…", 30000);
  try {
    const name = await invoke("invite_accept", { config_path: await ensureConfig(), code });
    $("join-in").value = "";
    snack(`Joined ${name || "the device"}. Looking for devices…`);
    await nodeState();
    await loadJoinInfo();
    setTimeout(showDevices, 1500);
  } catch (err) {
    snack(`${err}`.includes("InviteRejected")
      ? "That invite didn't work: it may have expired or already been used. Ask for a new one."
      : `Join failed: ${err}`);
  }
  if (btn) btn.disabled = false;
});

$("nick-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const nickname = $("nick-in").value.trim();
  if (!nickname) return;
  try {
    await invoke("set_nickname", { config_path: await ensureConfig(), nickname });
    $("device-name").textContent = nickname;
    snack("Renamed. Other devices see it after the node restarts.");
  } catch (err) {
    snack(`Rename failed: ${err}`);
  }
});

// ---- Text drop ----

const NOTES_KEY = "notes";
const MAX_NOTES = 30;

function shortCid(cid) {
  return cid.length > 16 ? `${cid.slice(0, 8)}…${cid.slice(-6)}` : cid;
}

function timeAgo(ms) {
  const s = Math.max(1, Math.round((Date.now() - ms) / 1000));
  if (s < 60) return "just now";
  const m = Math.round(s / 60);
  if (m < 60) return `${m} min ago`;
  const h = Math.round(m / 60);
  if (h < 24) return `${h} h ago`;
  return new Date(ms).toLocaleDateString(undefined, { month: "short", day: "numeric" });
}

/** Recent notes live on this device only: code, a preview and when. */
function loadNotes() {
  try { return JSON.parse(localStorage.getItem(NOTES_KEY) || "[]"); } catch { return []; }
}

function rememberNote(cid, text, kind) {
  const notes = loadNotes().filter((n) => n.cid !== cid);
  notes.unshift({ cid, preview: text.slice(0, 140), size: new TextEncoder().encode(text).length, at: Date.now(), kind });
  try { localStorage.setItem(NOTES_KEY, JSON.stringify(notes.slice(0, MAX_NOTES))); } catch {}
  renderNotes();
}

function renderNotes() {
  const notes = loadNotes();
  const list = $("notes-list");
  list.replaceChildren();
  $("notes-empty").hidden = notes.length > 0;
  $("notes-clear").hidden = notes.length === 0;
  for (const n of notes) {
    const firstLine = n.preview.split("\n").find((l) => l.trim()) || "(empty note)";
    list.appendChild(row({
      icon: "file",
      headline: firstLine,
      meta: `${n.kind === "stored" ? "Stored" : "Opened"} ${timeAgo(n.at)} · ${formatSize(n.size)} · ${shortCid(n.cid)}`,
      onClick: () => { $("cid-in").value = n.cid; openNote(n.cid); },
      action: { icon: "copy", label: "Copy code", run: () => copyText(n.cid, "Code copied") },
    }));
  }
}

async function copyText(text, done) {
  try {
    await navigator.clipboard.writeText(text);
    snack(done);
  } catch {
    snack("Clipboard unavailable");
  }
}

function updateComposer() {
  const t = $("text-in");
  t.style.height = "auto";
  t.style.height = `${t.scrollHeight}px`;
  const n = t.value.length;
  $("text-count").textContent = `${n.toLocaleString()} character${n === 1 ? "" : "s"}`;
  $("put-submit").disabled = n === 0;
}

$("text-in").addEventListener("input", updateComposer);
$("text-in").addEventListener("keydown", (e) => {
  if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
    e.preventDefault();
    $("put-form").requestSubmit();
  }
});

$("put-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const text = $("text-in").value;
  if (!text) return;
  if (!running) {
    snack("Start the node first");
    return;
  }
  $("put-submit").disabled = true;
  try {
    const cid = await invoke("put_text", { text });
    $("cid-output").textContent = shortCid(cid);
    $("cid-output").title = cid;
    $("cid-copy").onclick = () => copyText(cid, "Code copied: open it on another device");
    $("cid-box").hidden = false;
    rememberNote(cid, text, "stored");
    $("text-in").value = "";
  } catch (err) {
    snack(`Store failed: ${err}`);
  }
  updateComposer();
});

async function openNote(cid) {
  if (!/^[0-9a-fA-F]{64}$/.test(cid)) {
    snack("A note code is 64 hex characters");
    return;
  }
  const view = $("note-view");
  view.hidden = false;
  view.classList.remove("error");
  $("note-meta").textContent = `Opening ${shortCid(cid)}…`;
  $("text-out").textContent = "";
  $("note-copy").hidden = true;
  try {
    const text = await invoke("get_text", { cid: cid.toLowerCase() });
    $("text-out").textContent = text;
    $("note-meta").textContent = `${formatSize(new TextEncoder().encode(text).length)} · ${shortCid(cid)}`;
    $("note-copy").hidden = false;
    $("note-copy").onclick = () => copyText(text, "Text copied");
    rememberNote(cid.toLowerCase(), text, "opened");
  } catch (err) {
    view.classList.add("error");
    $("note-meta").textContent = shortCid(cid);
    $("text-out").textContent = `Couldn't open this note: ${err}. The device that stored it may be offline.`;
  }
}

$("fetch-form").addEventListener("submit", (e) => {
  e.preventDefault();
  openNote($("cid-in").value.trim());
});

$("cid-paste").addEventListener("click", async () => {
  try {
    const text = (await navigator.clipboard.readText()).trim();
    $("cid-in").value = text;
    if (/^[0-9a-fA-F]{64}$/.test(text)) openNote(text);
  } catch {
    snack("Clipboard unavailable: paste with Ctrl+V");
    $("cid-in").focus();
  }
});

$("notes-clear").addEventListener("click", () => {
  try { localStorage.removeItem(NOTES_KEY); } catch {}
  renderNotes();
});

renderNotes();
updateComposer();

// ---- About ----

let aboutText = "";

function openLink(url) {
  invoke("open_path", { path: url }).catch(() => window.open(url, "_blank"));
}

async function loadAbout() {
  let a;
  try {
    a = await invoke("about_info", { config_path: await ensureConfig() });
  } catch (err) {
    $("about-body").textContent = `Couldn't read the details: ${err}`;
    return;
  }
  $("about-version").textContent = a.nomadfs;
  const groups = [
    ["Versions", [
      ["NomadFS", a.nomadfs],
      ["Oriel", a.oriel],
      ["Zig", a.zig],
      ["Commit", a.commit],
      ["Build", a.mode],
      ["Platform", a.platform + (a.session ? ` · ${a.session}` : "")],
      ["App file", a.app_path ? `${formatSize(a.app_size)} · ${a.app_path}` : ""],
    ]],
    ["This device", [
      ["Name", a.nickname],
      ["Fingerprint", a.fingerprint],
      ["Node", a.running ? (a.node_id.slice(0, 16) + "…") : "not running"],
      ["Port", String(a.port)],
      ["Addresses", a.addresses.split(",").join("\n")],
      ["Devices", `${a.devices_connected} reachable · ${a.devices_trusted} trusted`],
    ]],
    ["Files", [
      ["Data", `${formatSize(a.data_size)} in ${a.data_files} files`],
      ["Data folder", a.data_path],
      ["Config", a.config_path],
    ]],
  ];
  const body = $("about-body");
  body.replaceChildren();
  const lines = [];
  for (const [title, rows] of groups) {
    const h = document.createElement("h3");
    h.className = "about-group";
    h.textContent = title;
    const dl = document.createElement("dl");
    dl.className = "about-list";
    lines.push(`${title}:`);
    for (const [k, v] of rows) {
      if (!v) continue;
      const dt = document.createElement("dt");
      dt.textContent = k;
      const dd = document.createElement("dd");
      dd.textContent = v;
      dl.append(dt, dd);
      lines.push(`  ${k}: ${v.replace(/\n/g, ", ")}`);
    }
    body.append(h, dl);
  }
  aboutText = lines.join("\n");
}

$("about-copy").addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText(aboutText);
    snack("Details copied");
  } catch {
    // No clipboard access: select the text so it can be copied by hand.
    const range = document.createRange();
    range.selectNodeContents($("about-body"));
    getSelection().removeAllRanges();
    getSelection().addRange(range);
    snack("Selected: copy with Ctrl+C");
  }
});
for (const el of document.querySelectorAll(".about-link")) {
  el.addEventListener("click", (e) => { e.preventDefault(); openLink(el.dataset.url); });
}

// ---- Swarm backup (desktop) ----

function renderBackup(st) {
  $("backup-section").hidden = !st.supported;
  if (!st.supported) return;
  $("swarm-backup").checked = st.enabled;
  let text = "";
  if (st.enabled && !st.running) text = "Starts with the node.";
  else if (st.enabled && st.last_round === 0) text = "Starting the first backup…";
  else if (st.enabled) {
    text = `${st.backed_up} of ${st.files} files backed up (${formatSize(st.bytes)}).`;
    if (st.unreachable_files) text += ` ${st.unreachable_files} waiting for the device that added them to come online.`;
  }
  $("backup-state").textContent = text;
}

async function loadBackup() {
  try { renderBackup(await invoke("swarm_backup_status", { config_path: await ensureConfig() })); } catch {}
}

$("swarm-backup").addEventListener("change", async (e) => {
  const on = e.target.checked;
  try {
    renderBackup(await invoke("swarm_backup_set", { config_path: await ensureConfig(), on }));
    snack(on ? "This device now backs up the swarm folder" : "Swarm backup turned off; copies already made stay");
  } catch (err) {
    e.target.checked = !on;
    snack(`Couldn't change it: ${err}`);
  }
});

// Progress while Settings is open.
setInterval(() => { if (document.body.dataset.view === "settings" && !document.hidden) loadBackup(); }, 5000);
loadBackup();

// ---- Background (Android) ----

async function renderBackground(status) {
  $("background-section").hidden = !status.supported;
  if (!status.supported) return;
  $("keep-running").checked = status.on;
  $("battery-state").textContent = status.battery_unrestricted
    ? "Battery: unrestricted."
    : "Battery: optimized. Android may still stop NomadFS in the background: open the settings, set Battery to No restrictions (Unrestricted), and on Xiaomi phones turn on Autostart.";
}

async function loadBackground() {
  let status;
  try { status = await invoke("keep_running_status", null); } catch { return; }
  // Turned on before: start again with the app (the switch is remembered).
  if (status.supported && !status.on && localStorage.getItem("keepRunning") === "1") {
    try { status = await invoke("keep_running_set", { on: true }); } catch {}
  }
  renderBackground(status);
}

$("keep-running").addEventListener("change", async (e) => {
  const on = e.target.checked;
  try {
    renderBackground(await invoke("keep_running_set", { on }));
    try { localStorage.setItem("keepRunning", on ? "1" : "0"); } catch {}
    snack(on ? "NomadFS keeps running in the background" : "NomadFS stops when you leave it");
  } catch (err) {
    e.target.checked = !on;
    snack(`Couldn't change it: ${err}`);
  }
});

$("battery-settings").addEventListener("click", () => invoke("open_app_settings", null).catch(() => {}));

// The notification's Stop button (Zig has stopped the service already).
window.oriel.listen?.("android:event", ({ name, data }) => {
  if (name !== "action" || data !== "stop") return;
  try { localStorage.setItem("keepRunning", "0"); } catch {}
  $("keep-running").checked = false;
});

// Coming back from the system settings: show the battery state again.
document.addEventListener("visibilitychange", () => {
  if (!document.hidden) invoke("keep_running_status", null).then(renderBackground).catch(() => {});
});

loadBackground();

// ---- Trusted devices ----

async function revokeTrusted(d) {
  const name = d.label || "this device";
  const ok = await askDialog({
    title: `Remove ${name}?`,
    text: `This device stops trusting ${name}, so it won't receive a new swarm key. It still holds the current key until you rotate it: use Rotate swarm key afterwards to cut it off. To connect again it needs a new invite.`,
    confirm: "Remove",
    danger: true,
  });
  if (!ok) return;
  try {
    await invoke("revoke_device", { config_path: await ensureConfig(), query: d.fingerprint });
    snack(`Removed ${name}`);
  } catch (err) {
    snack(`Remove failed: ${err}`);
  }
  $("devices-refresh").click();
}

$("devices-refresh").addEventListener("click", async () => {
  const list = $("devices-list");
  try {
    const trusted = await invoke("devices_list", { config_path: await ensureConfig() });
    // Reachable now: the same swarm key, online. Not the same as trusted.
    let reachable = [];
    if (running) {
      try {
        reachable = await invoke("remote_devices", null);
        devices = reachable;
        renderNavDevices();
      } catch {}
    }
    const trustedNames = new Set(trusted.map((d) => d.label));
    const unpaired = reachable.filter((d) => !trustedNames.has(d.nickname));
    list.replaceChildren();
    for (const d of trusted) {
      const online = reachable.some((r) => r.nickname === d.label);
      list.appendChild(row({
        icon: "device",
        iconClass: "device",
        headline: d.label || "Unnamed device",
        meta: [online ? "Online" : "Offline", `Trusted since ${formatDate(d.added_at)}`],
        meta2: d.fingerprint,
        actions: [{ icon: "trash", label: "Remove", run: () => revokeTrusted(d) }],
      }));
    }
    for (const d of unpaired) {
      list.appendChild(row({
        icon: "device",
        headline: d.nickname || d.peer.slice(0, 12),
        meta: "Connected, not paired: shares your swarm key, but its identity isn't verified. Pair it with an invite.",
      }));
    }
    if (!trusted.length && !unpaired.length) {
      list.appendChild(row({ icon: "device", headline: "No devices yet", meta: "Connect one under Connect devices" }));
    }
  } catch (err) {
    snack(`Devices failed: ${err}`);
  }
});

// ---- Swarm key rotation ----

$("rotate-key").addEventListener("click", async () => {
  if (!running) return snack("Start the node first");
  let trusted = [], reachable = [];
  try {
    trusted = await invoke("devices_list", { config_path: await ensureConfig() });
    reachable = await invoke("remote_devices", null);
  } catch {}
  const online = new Set(reachable.map((d) => d.nickname));
  const gets = trusted.filter((d) => online.has(d.label)).map((d) => d.label);
  const offline = trusted.filter((d) => !online.has(d.label)).map((d) => d.label);
  const unpaired = reachable.filter((d) => !trusted.some((t) => t.label === d.nickname)).map((d) => d.nickname || d.peer.slice(0, 8));
  const lines = [
    "Use this if the swarm key may have leaked. A new key goes to your paired devices that are online; anything that only knew the old key is cut off.",
    gets.length ? `Gets the new key: ${gets.join(", ")}.` : "No paired device is online: only this device changes key.",
  ];
  if (offline.length) lines.push(`Offline, keeps the old key (invite again later): ${offline.join(", ")}.`);
  if (unpaired.length) lines.push(`Not paired, will be cut off: ${unpaired.join(", ")}.`);
  const ok = await askDialog({ title: "Rotate the swarm key?", text: lines.join("\n\n"), confirm: "Rotate key", danger: true });
  if (!ok) return;
  snack("Rotating the swarm key…", 30000);
  try {
    const report = await invoke("swarm_rotate_key", { config_path: await ensureConfig() });
    const label = { delivered: "got the new key", refused: "refused it", failed: "couldn't be reached", not_paired: "not paired: cut off", offline: "offline: invite again" };
    const summary = report.length ? report.map((r) => `${r.name}: ${label[r.status] || r.status}`).join("\n") : "No other devices.";
    await askDialog({ title: "Swarm key rotated", text: `This device now uses the new key.\n\n${summary}`, confirm: "OK" });
  } catch (err) {
    snack(`Rotation failed: ${err}`);
  }
  await nodeState();
  $("devices-refresh").click();
});

// ---- Startup: the node starts with the app ----

async function boot() {
  let view = "browse";
  try { view = localStorage.getItem("view") || view; } catch {}
  setView(view);
  refreshState();
  await nodeState();
  loadMount();
  const storage = await storageSetup();
  const info = await loadJoinInfo();
  // First run on a phone: name the device after its model.
  if (info && info.nickname === "gui" && storage && storage.model) {
    try {
      await invoke("set_nickname", { config_path: await ensureConfig(), nickname: storage.model });
      await loadJoinInfo();
    } catch {}
  }
  if (!running) await startNode();
  else {
    loadShares();
    showDevices();
  }
}

boot();
