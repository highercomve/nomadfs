// `window.oriel` is injected by Oriel: `invoke()` talks typed Zig.
const { invoke } = window.oriel;
const extensions = window.oriel.extensions;

const $ = (id) => document.getElementById(id);

let configPath = null;
let storageExt = false; // Android: all-files access extension present

let snackTimer;
function snack(msg, ms = 3000) {
  const bar = $("snackbar");
  bar.textContent = msg;
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
function row({ icon, iconClass = "", headline, meta, monoMeta = false, onClick, action, cols }) {
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
  if (meta) {
    const m = document.createElement("span");
    m.className = monoMeta ? "meta mono" : "meta";
    m.textContent = meta;
    text.appendChild(m);
  }
  li.appendChild(text);
  // Wide layout: Size and Modified columns (CSS hides them on phones).
  if (cols) {
    li.classList.add("has-cols");
    for (const [cls, value] of [["col-size", cols.size], ["col-date", cols.date]]) {
      const c = document.createElement("span");
      c.className = `col ${cls}`;
      c.textContent = value || "";
      li.appendChild(c);
    }
    if (!action) {
      const pad = document.createElement("span");
      pad.className = "col act-spacer";
      li.appendChild(pad);
    }
  }
  if (action) {
    const b = document.createElement("button");
    b.className = "icon-btn";
    b.title = action.label;
    b.setAttribute("aria-label", action.label);
    b.appendChild(svg(ICONS[action.icon]));
    b.addEventListener("click", (e) => { e.stopPropagation(); action.run(b); });
    li.appendChild(b);
  }
  if (onClick) {
    li.classList.add("clickable");
    li.addEventListener("click", onClick);
  }
  return li;
}

// ---- Views (wide layout: one section at a time, picked in the drawer) ----

function setView(view) {
  document.body.dataset.view = view;
  for (const item of document.querySelectorAll(".nav-item[data-view], .bar-item[data-view]")) {
    item.classList.toggle("active", item.dataset.view === view);
  }
  window.scrollTo(0, 0);
  if (view === "text") $("text-drop").open = true;
  try { localStorage.setItem("view", view); } catch {}
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
  $("info").textContent = `Zig ${state.zig} · ${state.mode} · ${state.dev ? "dev" : "release"}`;
  $("nav-info").textContent = $("info").textContent;
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

async function showLocation() {
  if (path.length === 0) return showDevices();
  renderCrumbs();
  const list = $("remote-list");
  const device = path[0].device;

  if (path.length === 1) {
    list.replaceChildren();
    setEmpty(device.shares.length ? "" : "This device shares nothing yet.");
    for (const s of device.shares) {
      list.appendChild(row({
        icon: "folder",
        iconClass: "folder",
        headline: s.name,
        meta: `${formatSize(s.size)} · updated ${formatDate(s.mtime)}`,
        cols: { size: formatSize(s.size), date: formatDate(s.mtime) },
        onClick: () => { path.push({ name: s.name, cid: s.cid }); showLocation(); },
      }));
    }
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
  // Folders first, then files, each by name.
  entries.sort((a, b) => (b.dir - a.dir) || a.name.localeCompare(b.name));
  const files = entries.filter((x) => !x.dir);
  list.replaceChildren();
  setEmpty(entries.length ? "" : "Empty folder.");
  for (const e of entries) {
    if (e.dir) {
      list.appendChild(row({
        icon: "folder",
        iconClass: "folder",
        headline: e.name,
        meta: formatSize(e.size),
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
        onClick: () => openPreview(device, files, files.indexOf(e)),
        action: { icon: "download", label: "Download", run: fetchIt },
      }));
    }
  }
}

const downloading = new Set();

async function downloadFile(device, entry, btn) {
  if (downloading.has(entry.cid)) return;
  downloading.add(entry.cid);
  if (btn) btn.classList.add("spin");
  snack(`Downloading ${entry.name} (${formatSize(entry.size)})…`, 60000);
  try {
    const res = await invoke("download", { peer: device.peer, cid: entry.cid, name: entry.name });
    snack(`Saved to ${res.path}`, 5000);
  } catch (err) {
    snack(`Download failed: ${err}`);
  }
  downloading.delete(entry.cid);
  if (btn) btn.classList.remove("spin");
}

// ---- Preview ----

const KINDS = {
  image: { ext: ["jpg", "jpeg", "png", "gif", "webp", "bmp", "svg", "avif", "heic"], max: 64 << 20 },
  video: { ext: ["mp4", "webm", "mov", "m4v", "mkv", "3gp"], max: 512 << 20 },
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

let pv = null; // { device, files, index, token, url }

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

function openPreview(device, files, index) {
  pv = { device, files, index, token: 0, url: null };
  $("preview").hidden = false;
  showPreview();
}

function closePreview() {
  if (!pv) return;
  pv.token++;
  if (pv.url) URL.revokeObjectURL(pv.url);
  pv = null;
  $("pv-body").replaceChildren();
  $("preview").hidden = true;
}

async function showPreview() {
  const token = ++pv.token;
  if (pv.url) { URL.revokeObjectURL(pv.url); pv.url = null; }
  const entry = pv.files[pv.index];
  $("pv-name").textContent = entry.name;
  $("pv-meta").textContent = `${formatSize(entry.size)} · ${formatDate(entry.mtime)} · ${pv.index + 1} of ${pv.files.length}`;
  $("pv-prev").disabled = pv.index === 0;
  $("pv-next").disabled = pv.index === pv.files.length - 1;

  const { kind, ext } = kindOf(entry.name);
  if (!kind) return previewMessage("file", "No preview for this kind of file.");
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
      const b64 = await invoke("read_range", { peer: pv.device.peer, cid: entry.cid, offset, len });
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
    if (pv && token === pv.token) previewMessage("file", "This app can't display that format. Download it to open it.");
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
$("pv-download").addEventListener("click", () => { if (pv) downloadFile(pv.device, pv.files[pv.index], null); });
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
  $("nav-mount").hidden = !status.supported;
  if (!status.supported && document.body.dataset.view === "mount") setView("browse");
  renderMount(status);
}

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
    if (picked) { mountPath = picked.path; $("mount-path").textContent = mountPath; }
  } catch (err) {
    snack(`Folder picker failed: ${err}`);
  }
});

$("mount-open").addEventListener("click", async () => {
  try { await invoke("open_path", { path: mountPath }); } catch (err) { snack(`Couldn't open the folder: ${err}`); }
});

$("remote-refresh").addEventListener("click", () => (path.length ? showLocation() : showDevices()));

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
      meta: s.ready ? `${s.files} files · ${formatSize(s.size)} · ${s.path}` : `Scanning… ${s.path}`,
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
    if (picked) stageShare(picked.path, picked.name);
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
    $("join-code").textContent = info.code;
    $("device-name").textContent = info.nickname;
    $("nick-in").value = info.nickname;
    return info;
  } catch (err) {
    $("join-code").textContent = `Unavailable: ${err}`;
  }
}

$("join-copy").addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText($("join-code").textContent);
    snack("Code copied");
  } catch {
    snack("Clipboard unavailable");
  }
});

$("join-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const code = $("join-in").value.trim();
  if (!code) return;
  try {
    await invoke("join", { config_path: await ensureConfig(), code });
    $("join-in").value = "";
    snack("Joined. Looking for devices…");
    await nodeState();
    await loadJoinInfo();
    setTimeout(showDevices, 1500);
  } catch (err) {
    snack(`Join failed: ${err}`);
  }
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

$("put-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const text = $("text-in").value;
  if (!text) return;
  const box = $("cid-box");
  try {
    const cid = await invoke("put_text", { text });
    box.classList.remove("error");
    $("cid-output").textContent = cid;
    $("cid-use").hidden = false;
    $("cid-copy").hidden = false;
    $("cid-use").onclick = () => {
      $("cid-in").value = cid;
      $("cid-in").scrollIntoView({ behavior: "smooth", block: "center" });
    };
    $("cid-copy").onclick = async () => {
      try {
        await navigator.clipboard.writeText(cid);
        snack("CID copied");
      } catch {
        snack("Clipboard unavailable");
      }
    };
    snack(`Stored ${new TextEncoder().encode(text).length} bytes`);
  } catch (err) {
    box.classList.add("error");
    $("cid-output").textContent = `Store failed: ${err}`;
    $("cid-use").hidden = true;
    $("cid-copy").hidden = true;
  }
  box.hidden = false;
});

$("fetch").addEventListener("click", async () => {
  const cid = $("cid-in").value.trim();
  if (cid.length !== 64) {
    snack("A CID is 64 hex characters");
    return;
  }
  const out = $("text-out");
  try {
    out.textContent = await invoke("get_text", { cid });
    out.classList.remove("error");
  } catch (err) {
    out.textContent = `Fetch failed: ${err}`;
    out.classList.add("error");
  }
  out.hidden = false;
});

// ---- Trusted devices ----

$("devices-refresh").addEventListener("click", async () => {
  const list = $("devices-list");
  try {
    const trusted = await invoke("devices_list", { config_path: await ensureConfig() });
    list.replaceChildren();
    if (!trusted.length) {
      list.appendChild(row({ icon: "device", headline: "No trusted devices yet" }));
      return;
    }
    for (const d of trusted) {
      list.appendChild(row({ icon: "device", headline: d.label || "Unnamed device", meta: `${d.fingerprint} · added ${d.added_at}`, monoMeta: true }));
    }
  } catch (err) {
    snack(`Devices failed: ${err}`);
  }
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
