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
  bar.title = onClick ? "Click to open" : "";
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
  audio: "M12 3v10.55c-.59-.34-1.27-.55-2-.55-2.21 0-4 1.79-4 4s1.79 4 4 4 4-1.79 4-4V7h4V3h-6z",
  download: "M19 9h-4V3H9v6H5l7 7 7-7zM5 18v2h14v-2H5z",
  edit: "M3 17.25V21h3.75L17.81 9.94l-3.75-3.75L3 17.25zM20.71 7.04a1 1 0 0 0 0-1.41l-2.34-2.34a1 1 0 0 0-1.41 0l-1.83 1.83 3.75 3.75 1.83-1.83z",
  trash: "M6 19c0 1.1.9 2 2 2h8c1.1 0 2-.9 2-2V7H6v12zM19 4h-3.5l-1-1h-5l-1 1H5v2h14V4z",
  swarm: "M12 2a3 3 0 0 0-1 5.83V10H7.83A3 3 0 1 0 6 12.83V15a3 3 0 1 0 2 0v-2.17A3 3 0 0 0 9.83 12h4.34A3 3 0 0 0 16 12.83V15a3 3 0 1 0 2 0v-2.17A3 3 0 1 0 16.17 10H13V7.83A3 3 0 0 0 12 2z",
  copy: "M16 1H4c-1.1 0-2 .9-2 2v14h2V3h12V1zm3 4H8c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h11c1.1 0 2-.9 2-2V7c0-1.1-.9-2-2-2zm0 16H8V7h11v14z",
  backup: "M19.35 10.04C18.67 6.59 15.64 4 12 4 9.11 4 6.6 5.64 5.35 8.04 2.34 8.36 0 10.91 0 14c0 3.31 2.69 6 6 6h13c2.76 0 5-2.24 5-5 0-2.64-2.05-4.78-4.65-4.96zM14 13v4h-4v-4H7l5-5 5 5h-3z",
  backup_off: "M19.35 10.04C18.67 6.59 15.64 4 12 4c-1.48 0-2.85.43-4.01 1.17l1.46 1.46C10.21 6.23 11.08 6 12 6c3.04 0 5.5 2.46 5.5 5.5v.5H19c1.66 0 3 1.34 3 3 0 1.13-.64 2.11-1.56 2.62l1.45 1.45C23.16 18.16 24 16.68 24 15c0-2.64-2.05-4.78-4.65-4.96zM3 5.27l2.75 2.74C2.56 8.15 0 10.77 0 14c0 3.31 2.69 6 6 6h11.73l2 2L21 20.73 4.27 4 3 5.27zM7.73 10l8 8H6c-2.21 0-4-1.79-4-4s1.79-4 4-4h1.73z",
  info: "M11 7h2v2h-2zm0 4h2v6h-2zm1-9C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 18c-4.41 0-8-3.59-8-8s3.59-8 8-8 8 3.59 8 8-3.59 8-8 8z",
  open_in: "M19 19H5V5h7V3H5c-1.11 0-2 .9-2 2v14c0 1.1.89 2 2 2h14c1.1 0-2-.9 2-2v-7h-2v7zM14 3v2h3.59l-9.83 9.83 1.41 1.41L19 6.41V10h2V3h-7z",
  link: "M3.9 12c0-1.71 1.39-3.1 3.1-3.1h4V7H7c-2.76 0-5 2.24-5 5s2.24 5 5 5h4v-1.9H7c-1.71 0-3.1-1.39-3.1-3.1zM8 13h8v-2H8v2zm9-6h-4v1.9h4c1.71 0 3.1 1.39 3.1 3.1s-1.39 3.1-3.1 3.1h-4V17h4c2.76 0 5-2.24 5-5s-2.24-5-5-5z",
  move: "M10 4H4c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2h-8l-2-2zm4 13v-3h-4v-2h4V9l4 4-4 4z",
  more: "M12 8c1.1 0 2-.9 2-2s-.9-2-2-2-2 .9-2 2 .9 2 2 2zm0 2c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2zm0 6c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2z",
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

const FILE_TYPES = {
  photo: ["jpg", "jpeg", "png", "gif", "webp", "heic", "avif", "bmp", "svg", "dng", "raw", "cr2", "nef", "arw", "tif", "tiff"],
  video: ["mp4", "mov", "mkv", "webm", "avi", "3gp", "wmv", "flv", "m4v", "ts"],
  audio: ["mp3", "m4a", "flac", "wav", "ogg", "aac", "opus", "wma", "aiff"],
  document: ["pdf", "doc", "docx", "txt", "md", "rtf", "odt", "xls", "xlsx", "csv", "ppt", "pptx", "epub"],
  archive: ["zip", "tar", "gz", "tgz", "7z", "rar", "bz2", "xz"],
  code: ["zig", "rs", "js", "ts", "html", "css", "json", "py", "c", "cpp", "h", "sh", "yaml", "yml", "toml", "go"],
};

function fileType(name, dir) {
  if (dir) return "Folder";
  const ext = (name.split(".").pop() || "").toLowerCase();
  if (FILE_TYPES.photo.includes(ext)) return "Photo";
  if (FILE_TYPES.video.includes(ext)) return "Video";
  if (FILE_TYPES.audio.includes(ext)) return "Audio";
  if (FILE_TYPES.document.includes(ext)) return "Document";
  if (FILE_TYPES.archive.includes(ext)) return "Archive";
  if (FILE_TYPES.code.includes(ext)) return "Code";
  return "File";
}

function iconFor(name, dir) {
  if (dir) return "folder";
  const t = fileType(name, false);
  if (t === "Photo") return "image";
  if (t === "Video") return "video";
  if (t === "Audio") return "audio";
  return "file";
}

/** A Material list row: leading icon, headline + meta, optional trailing button. */
function row({ icon, iconClass = "", headline, meta, meta2, monoMeta = false, onClick, action, actions, cols, menu }) {
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
  h.title = headline;
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
  // Wide layout: Type, Size, Modified, Added by columns (CSS hides them on phones).
  if (cols) {
    li.classList.add("has-cols");
    const colList = [];
    if (cols.type !== undefined) colList.push(["col-type", cols.type]);
    if (cols.size !== undefined) colList.push(["col-size", cols.size]);
    if (cols.date !== undefined) colList.push(["col-date", cols.date]);
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
    li.addEventListener("click", (e) => { if (!li.dataset.menuOpened) onClick(e); delete li.dataset.menuOpened; });
  }
  if (menu?.length) attachMenu(li, menu);
  return li;
}

// ---- The row menu (right-click; a long press on touch screens) ----

let menuEl = null;

/** `items`: { icon, label, run, danger } or "-" (a separator). */
function attachMenu(li, items) {
  li.addEventListener("contextmenu", (e) => {
    e.preventDefault();
    e.stopPropagation();
    showMenu(e.clientX, e.clientY, items);
  });
  // Touch: a long press opens it, and the click that ends it doesn't open the row.
  let timer = 0;
  let start = null;
  li.addEventListener("pointerdown", (e) => {
    if (e.pointerType !== "touch") return;
    start = { x: e.clientX, y: e.clientY };
    timer = setTimeout(() => {
      li.dataset.menuOpened = "1";
      showMenu(start.x, start.y, items);
    }, 550);
  });
  const cancel = () => clearTimeout(timer);
  li.addEventListener("pointerup", cancel);
  li.addEventListener("pointercancel", cancel);
  li.addEventListener("pointermove", (e) => {
    if (start && Math.hypot(e.clientX - start.x, e.clientY - start.y) > 10) cancel();
  });
}

function showMenu(x, y, items) {
  closeMenu();
  menuEl = document.createElement("div");
  menuEl.className = "row-menu";
  menuEl.setAttribute("role", "menu");
  for (const it of items) {
    if (it === "-") {
      menuEl.appendChild(Object.assign(document.createElement("hr"), { className: "row-menu-sep" }));
      continue;
    }
    const b = document.createElement("button");
    b.type = "button";
    b.className = `row-menu-item${it.danger ? " danger" : ""}`;
    b.setAttribute("role", "menuitem");
    b.appendChild(svg(ICONS[it.icon]));
    b.appendChild(document.createTextNode(it.label));
    b.addEventListener("click", (e) => { e.stopPropagation(); closeMenu(); it.run(); });
    menuEl.appendChild(b);
  }
  document.body.appendChild(menuEl);
  syncVideoCover();
  // Inside the window, near the pointer.
  const r = menuEl.getBoundingClientRect();
  menuEl.style.left = `${Math.max(8, Math.min(x, innerWidth - r.width - 8))}px`;
  menuEl.style.top = `${Math.max(8, Math.min(y, innerHeight - r.height - 8))}px`;
  menuEl.querySelector("button")?.focus();
}

function closeMenu() {
  if (!menuEl) return;
  menuEl.remove();
  menuEl = null;
  syncVideoCover();
}

document.addEventListener("pointerdown", (e) => { if (menuEl && !menuEl.contains(e.target)) closeMenu(); }, true);
document.addEventListener("keydown", (e) => { if (e.key === "Escape" && menuEl) { closeMenu(); e.stopPropagation(); } }, true);
addEventListener("scroll", closeMenu, true);
addEventListener("resize", closeMenu);
// The WebView's own menu (Back, Reload...) means nothing here; text fields keep theirs.
document.addEventListener("contextmenu", (e) => {
  if (!e.target.closest("input, textarea, [contenteditable]") && !getSelection()?.toString()) e.preventDefault();
});

/** A file's MIME type, from its extension: what another app opens it as. */
function mimeFor(name) {
  const ext = (name.split(".").pop() || "").toLowerCase();
  return ({
    mkv: "video/x-matroska", mp4: "video/mp4", m4v: "video/mp4", mov: "video/quicktime", avi: "video/x-msvideo", webm: "video/webm", ts: "video/mp2t", wmv: "video/x-ms-wmv",
    mp3: "audio/mpeg", m4a: "audio/mp4", flac: "audio/flac", ogg: "audio/ogg", opus: "audio/opus", wav: "audio/wav", aac: "audio/aac",
    jpg: "image/jpeg", jpeg: "image/jpeg", png: "image/png", gif: "image/gif", webp: "image/webp", heic: "image/heic",
    pdf: "application/pdf", txt: "text/plain", md: "text/markdown", zip: "application/zip",
  })[ext] || "application/octet-stream";
}

/** The menu items every file has: open elsewhere, download, details, and copyable links. */
function fileMenu(source, e, details) {
  return [
    { icon: "open_in", label: "Open in another app", run: () => openInApp(source, e) },
    { icon: "download", label: "Download", run: () => source.download(e) },
    { icon: "info", label: "Details", run: () => openDetails(e.name, details) },
    { icon: "link", label: "Copy link on this device", run: () => copyLink(source, e) },
    { icon: "link", label: "Copy link on local network", run: () => copyLink(source, e, "lan") },
    { icon: "link", label: "Copy Tailscale link", run: () => copyLink(source, e, "tailscale") },
  ];
}

/** Streams it to the app the system picks for its type (VLC for a video). */
async function openInApp(source, e) {
  try {
    const url = await source.mediaUrl(e, true);
    await window.oriel.openExternal(url, { type: mimeFor(e.name) });
  } catch (err) {
    snack(`Couldn't open it: ${err}`);
  }
}

async function copyLink(source, e, network = "") {
  try {
    const url = await source.mediaUrl(e, true, network);
    const where = network === "lan" ? "on the local network" : network === "tailscale" ? "over Tailscale" : "on this device";
    copyText(url, `Link copied for ${where}`);
  } catch (err) {
    const unavailable = String(err).includes("NoLanAddress") ? "No local network address is available" :
      String(err).includes("NoTailscaleAddress") ? "No Tailscale address is available" : `No link: ${err}`;
    snack(unavailable);
  }
}

// ---- Back (Android's back button and gesture, a mouse's back button) ----

// Back goes up one level from wherever the app is: closes the open file or
// the More sheet, then the parent folder, then Browse; at the top it's
// Android's (the app goes to the background). The WebView's Back follows
// the page history, so the page keeps one history entry per level it can
// go up. They're added as the app goes deeper, right after the tap that
// took it there: the WebView skips entries a page adds on its own.
function upTarget() {
  if (pv) return closePreview;
  if (!$("more-sheet").hidden) return closeMore;
  const view = document.body.dataset.view || "browse";
  if (view === "swarm" && swarmDir) return () => { swarmDir = swarmDir.split("/").slice(0, -1).join("/"); loadSwarm(); };
  if (view !== "browse") return () => { setView("browse"); if (path.length) showLocation(); };
  if (path.length) return () => { path.pop(); path.length ? showLocation() : showDevices(); };
  return null;
}

/** How many Back presses lead to the top of Browse (upTarget's chain). */
function upLevels() {
  const view = document.body.dataset.view || "browse";
  let n = path.length;
  if (view !== "browse") n += 1;
  if (view === "swarm" && swarmDir) n += swarmDir.split("/").length;
  if (!$("more-sheet").hidden) n += 1;
  if (pv) n += 1;
  return n;
}

let backDepth = 0; // our history entries above the page's own
let ignorePops = 0; // history.go() calls of ours still to arrive

/** Matches the history entries to the levels after any move. */
function syncBack() {
  const want = upLevels();
  while (backDepth < want) history.pushState({ nomadfsBack: ++backDepth }, "");
  if (backDepth > want) {
    // Went up through the app (a breadcrumb, the close button).
    ignorePops++;
    const n = backDepth - want;
    backDepth = want;
    history.go(-n);
  }
}

window.addEventListener("popstate", () => {
  if (ignorePops > 0) { ignorePops--; return; }
  backDepth = Math.max(0, backDepth - 1);
  upTarget()?.();
  syncBack();
});

// ---- Phones: the "More" sheet holds sections without a bar slot ----

function closeMore() { $("more-sheet").hidden = true; syncBack(); }
$("bar-more").addEventListener("click", () => {
  const sheet = $("more-sheet");
  for (const it of sheet.querySelectorAll(".sheet-item")) it.classList.toggle("active", it.dataset.view === document.body.dataset.view);
  sheet.hidden = !sheet.hidden;
  syncBack();
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
  if (view === "downloads") loadDownloads();
  if (view === "text") loadSwarmNotes();
  if (view === "about") loadAbout();
  renderNavDevices();
  syncBack();
}

for (const item of document.querySelectorAll(".nav-item[data-view], .bar-item[data-view]")) {
  item.addEventListener("click", () => {
    setView(item.dataset.view);
    if (item.dataset.view === "browse" && path.length) showDevices();
  });
}

// The mount's folder name: a paired device's label, or an unpaired device's claimed nickname with a
// fingerprint suffix, so an unpaired device never shows a paired device's name.
const deviceTitle = (d) => d.mount_name || (d.trusted === true ? d.label : `Device ${d.fingerprint ? d.fingerprint.slice(0, 9) : (d.peer ? d.peer.slice(0, 8) : "")}`);
const deviceBadge = (d) => (d.trusted === true) ? "Paired" : "Not paired";

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
    label.textContent = deviceTitle(d);
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
    const started = state.running && !running;
    running = state.running;
    // The swarm's notes, and moving this device's old ones there.
    if (started) loadSwarmNotes();
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
    snack(String(err).includes("NodeAlreadyRunning")
      ? "Another NomadFS node already runs on this device (a service or the command line): stop it first."
      : `Open failed: ${err}`);
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

/** Breadcrumbs into `nav`: [{ label, go }], the last one is where we are.
 *  Hidden at the top level, where there is nothing to go back to. */
function drawCrumbs(nav, parts) {
  nav.replaceChildren();
  nav.hidden = parts.length < 2;
  parts.forEach((part, i) => {
    if (i > 0) {
      const sep = document.createElement("span");
      sep.className = "sep";
      sep.textContent = "›";
      nav.appendChild(sep);
    }
    const b = document.createElement("button");
    b.type = "button";
    b.textContent = part.label;
    if (i < parts.length - 1) b.addEventListener("click", part.go);
    nav.appendChild(b);
  });
}

function renderCrumbs() {
  $("remote-head").hidden = path.length === 0;
  $("device-about").hidden = path.length === 0;
  $("browse-tools").hidden = path.length === 0;
  renderNavDevices();
  const parts = [{ label: "Devices" }, ...path.map((p) => ({ label: p.name }))];
  drawCrumbs($("crumbs"), parts.map((part, i) => ({ ...part, go: () => { path = path.slice(0, i); showLocation(); } })));
  syncBack();
}

function setEmpty(text) {
  const el = $("remote-empty");
  el.hidden = !text;
  el.textContent = text || "";
}

/** A list that is loading something new: the old rows go at once, and
 *  placeholder rows stand in until the new ones arrive. */
function listLoading(list, rows = 4) {
  list.replaceChildren();
  for (let i = 0; i < rows; i++) {
    const li = document.createElement("li");
    li.className = "skeleton";
    li.setAttribute("aria-hidden", "true");
    li.innerHTML = '<span class="row-icon"></span><span class="row-text"><span class="sk-bar"></span><span class="sk-bar short"></span></span>';
    list.appendChild(li);
  }
  list.setAttribute("aria-busy", "true");
}

function listLoaded(list) {
  list.removeAttribute("aria-busy");
}

// Each navigation in Browse gets a number; a response for an older one
// (the user moved on while it loaded) is dropped instead of drawn.
let browseNav = 0;
// What Browse shows now ("devices", or the path), to tell a new place from
// a refresh of the same one (which keeps its rows while it reloads).
let browseShowing = "";

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
  const nav = ++browseNav;
  const list = $("remote-list");
  if (!running) {
    list.replaceChildren();
    setEmpty("Start the node, then add your other devices under Connect devices.");
    browseShowing = "";
    return;
  }
  if (browseShowing !== "devices") {
    setEmpty("");
    listLoading(list);
  }
  busy(true);
  let found;
  try {
    found = await invoke("remote_devices", null);
  } catch (err) {
    found = [];
    if (nav === browseNav) snack(`Devices failed: ${err}`);
  }
  if (nav !== browseNav) return;
  devices = found;
  browseShowing = "devices";
  busy(false);
  listLoaded(list);
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
    const title = deviceTitle(d);
    const badge = deviceBadge(d);
    const fpShort = d.fingerprint ? d.fingerprint.slice(0, 9) : (d.peer ? d.peer.slice(0, 8) : "");
    const sharesText = d.shares.length
      ? `${d.shares.length} shared folder${d.shares.length === 1 ? "" : "s"} · ${formatSize(total)}`
      : "Shares nothing yet";
    const qualifier = (!d.trusted && d.nickname) ? ` · claims to be "${d.nickname}"` : "";
    list.appendChild(row({
      icon: "device",
      iconClass: "device",
      headline: title,
      meta: `${badge} · ${fpShort}${qualifier} · ${sharesText}`,
      onClick: () => { path = [{ name: title, device: d }]; showLocation(); },
      actions: [{ icon: "info", label: `About ${title}`, run: () => openDeviceInfo(title, d.peer) }],
    }));
  }
}

// ---- Browse: search and sort ----

// ---- File tables: search, sort and sortable columns (Browse, Swarm folder) ----

const SEARCH_ICON = "M15.5 14h-.79l-.28-.27A6.47 6.47 0 0 0 16 9.5 6.5 6.5 0 1 0 9.5 16c1.61 0 3.09-.59 4.23-1.57l.27.28v.79l5 4.99L20.49 19l-4.99-5zm-6 0C7.01 14 5 11.99 5 9.5S7.01 5 9.5 5 14 7.01 14 9.5 11.99 14 9.5 14z";
const SORT_DIR_ICON = "M4 12l1.41 1.41L11 7.83V20h2V7.83l5.58 5.59L20 12l-8-8-8 8z";

/**
 * A list of files and folders with a search field, a sort menu (phones) and
 * sortable column headers (wide windows). The owner gives the entries
 * ({ name, size, mtime, dir, ... }) and draws each row; the table filters,
 * sorts (folders first) and remembers the order across runs.
 *
 *   columns: [{ key, label, cls }] after Name, e.g. size, mtime, author
 *   renderRow(entry, files): an <li>; files = the shown files, in order
 *   emptyText(query): what an empty list says
 */
class FileTable {
  constructor({ view, tools, head, list, columns, storageKey, actions, placeholder = "Search this folder", renderRow, emptyText, setEmpty }) {
    Object.assign(this, { view, tools, head, list, columns, storageKey, renderRow, emptyText, setEmpty });
    this.entries = null;
    this.sort = { key: "name", dir: 1 };
    this.filterType = "all";
    try { Object.assign(this.sort, JSON.parse(localStorage.getItem(storageKey) || "{}")); } catch {}
    if (!this.allColumns().some((c) => c.key === this.sort.key)) this.sort = { key: "name", dir: 1 };
    // Room for the row buttons, so the header lines up with the rows.
    head.closest(".table-scroll").style.setProperty("--act-w", `${actions * 34}px`);
    this.buildTools(placeholder);
    this.buildHead();
    FileTable.all.push(this);
  }

  allColumns() {
    return [{ key: "name", label: "Name", cls: "th-name" }, ...this.columns];
  }

  buildTools(placeholder) {
    const searchRow = document.createElement("div");
    searchRow.className = "tools-search-row";

    const field = document.createElement("label");
    field.className = "search-field";
    field.append(svg(SEARCH_ICON));
    const input = document.createElement("input");
    Object.assign(input, { type: "search", placeholder, autocomplete: "off", spellcheck: false });
    input.setAttribute("aria-label", placeholder);
    input.addEventListener("input", () => this.render());
    input.addEventListener("keydown", (e) => {
      if (e.key === "Escape" && input.value) { input.value = ""; this.render(); e.stopPropagation(); }
    });
    field.append(input);

    const select = document.createElement("select");
    select.className = "sort-select";
    select.setAttribute("aria-label", "Sort by");
    for (const c of this.allColumns()) select.append(new Option(c.label, c.key));
    select.addEventListener("change", () => this.setSort(select.value, this.sort.dir));

    const dir = document.createElement("button");
    dir.type = "button";
    dir.className = "icon-btn sort-dir";
    dir.setAttribute("aria-label", "Sort direction");
    dir.append(svg(SORT_DIR_ICON));
    dir.addEventListener("click", () => this.setSort(this.sort.key, -this.sort.dir));

    searchRow.append(field, select, dir);

    const chipsBox = document.createElement("div");
    chipsBox.className = "type-chips";
    chipsBox.hidden = true;

    this.tools.replaceChildren(searchRow, chipsBox);
    Object.assign(this, { input, select, dirBtn: dir, chipsBox });
  }

  updateFilterChips() {
    if (!this.entries || !this.chipsBox) return;
    const counts = { all: this.entries.length };
    for (const e of this.entries) {
      const t = e.dir ? "Folder" : fileType(e.name, false);
      counts[t] = (counts[t] || 0) + 1;
    }
    const categories = ["Photo", "Video", "Audio", "Document", "Archive", "Code", "Folder", "File"];
    const activeCats = categories.filter((c) => (counts[c] || 0) > 0);

    if (activeCats.length <= 1) {
      this.chipsBox.replaceChildren();
      this.chipsBox.hidden = true;
      return;
    }
    this.chipsBox.hidden = false;

    const makeChip = (id, label, count) => {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = `type-chip${this.filterType === id ? " active" : ""}`;
      btn.dataset.type = id;
      const lbl = document.createElement("span");
      lbl.textContent = label;
      btn.appendChild(lbl);
      const cnt = document.createElement("span");
      cnt.className = "count";
      cnt.textContent = count;
      btn.appendChild(cnt);
      btn.addEventListener("click", () => {
        this.filterType = this.filterType === id && id !== "all" ? "all" : id;
        this.render();
      });
      return btn;
    };

    const chips = [makeChip("all", "All", counts.all)];
    const pluralLabels = {
      Photo: "Photos",
      Video: "Videos",
      Audio: "Audio",
      Document: "Documents",
      Archive: "Archives",
      Code: "Code",
      Folder: "Folders",
      File: "Files",
    };
    for (const c of activeCats) {
      chips.push(makeChip(c, pluralLabels[c] || c, counts[c]));
    }
    this.chipsBox.replaceChildren(...chips);
  }

  buildHead() {
    this.head.replaceChildren();
    for (const c of this.allColumns()) {
      const th = document.createElement("button");
      th.type = "button";
      th.className = `${c.cls} th-sort`;
      th.dataset.sort = c.key;
      th.textContent = c.label;
      th.addEventListener("click", () => {
        // Sizes and dates read best biggest/newest first.
        const first = c.key === "size" || c.key === "mtime" ? -1 : 1;
        this.setSort(c.key, this.sort.key === c.key ? -this.sort.dir : first);
      });
      this.head.append(th);
    }
    const act = document.createElement("span");
    act.className = "th-act";
    this.head.append(act);
  }

  setSort(key, dir) {
    this.sort = { key, dir };
    try { localStorage.setItem(this.storageKey, JSON.stringify(this.sort)); } catch {}
    this.render();
  }

  compare(a, b) {
    // Folders stay above files whatever the order.
    if (!!a.dir !== !!b.dir) return b.dir - a.dir;
    const { key, dir } = this.sort;
    let c = 0;
    if (key !== "name") {
      let x = a[key] ?? "";
      let y = b[key] ?? "";
      if (key === "type") {
        x = a.dir ? "Folder" : fileType(a.name, false);
        y = b.dir ? "Folder" : fileType(b.name, false);
      }
      c = typeof x === "number" && typeof y === "number" ? x - y : String(x).localeCompare(String(y), undefined, { sensitivity: "base" });
    }
    if (c === 0) c = a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: "base" });
    return c * dir;
  }

  /** A new place: new entries, search cleared. */
  show(entries) {
    this.entries = entries;
    this.input.value = "";
    this.filterType = "all";
    this.render();
  }

  render() {
    if (!this.entries) return;
    this.select.value = this.sort.key;
    this.dirBtn.title = this.sort.dir > 0 ? "Ascending" : "Descending";
    this.dirBtn.classList.toggle("desc", this.sort.dir < 0);
    for (const th of this.head.querySelectorAll(".th-sort")) {
      th.classList.toggle("sorted", th.dataset.sort === this.sort.key);
      th.classList.toggle("desc", this.sort.dir < 0);
    }
    const raw = this.input.value.trim();
    const query = raw.toLocaleLowerCase();
    const filter = this.filterType || "all";
    const shown = this.entries
      .filter((e) => {
        if (filter !== "all") {
          const t = e.dir ? "Folder" : fileType(e.name, false);
          if (t !== filter) return false;
        }
        return !query || e.name.toLocaleLowerCase().includes(query);
      })
      .sort((a, b) => this.compare(a, b));

    this.updateFilterChips();

    this.list.replaceChildren();
    if (!shown.length) {
      if (filter !== "all") {
        const plural = { Photo: "photos", Video: "videos", Audio: "audio files", Document: "documents", Folder: "folders" }[filter] || filter.toLowerCase() + "s";
        this.setEmpty(query ? `Nothing matches "${raw}" in ${plural}.` : `No ${plural} found in this folder.`);
      } else {
        this.setEmpty(query ? `Nothing here matches "${raw}".` : this.emptyText());
      }
      return;
    }
    this.setEmpty("");
    // Previews step through the files in the order shown.
    const files = shown.filter((x) => !x.dir);
    for (const e of shown) this.list.appendChild(this.renderRow(e, files));
  }

  focusSearch() {
    this.input.focus();
    this.input.select();
  }
}
FileTable.all = [];

// "/" or Ctrl+F searches the open folder (not while typing elsewhere).
document.addEventListener("keydown", (e) => {
  const table = FileTable.all.find((t) => t.view === document.body.dataset.view && !t.tools.hidden);
  if (!table) return;
  const typing = /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement?.tagName || "");
  if ((e.key === "/" && !typing) || ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "f")) {
    e.preventDefault();
    table.focusSearch();
  }
});

// What the open location lists: { device, shares } (shares: a device's top
// level, whose entries are its shared folders).
let browse = null;

const browseTable = new FileTable({
  view: "browse",
  tools: $("browse-tools"),
  head: $("remote-head"),
  list: $("remote-list"),
  columns: [
    { key: "type", label: "Type", cls: "th-type" },
    { key: "size", label: "Size", cls: "th-size" },
    { key: "mtime", label: "Modified", cls: "th-date" },
  ],
  storageKey: "browseSort",
  actions: 2,
  setEmpty: (text) => setEmpty(text),
  emptyText: () => browse?.shares ? "This device shares nothing yet."
    : path.at(-1)?.pending ? "Not indexed yet: the device is still scanning this share. Check back soon."
    : "Empty folder.",
  renderRow: (e, files) => browseRow(e, files),
});

function browseRow(e, files) {
  const { device, shares } = browse;
  if (e.dir) {
    // A share's first scan lists folders it hasn't reached yet: empty,
    // without a date.
    const pending = !e.mtime && !e.size;
    return row({
      icon: "folder",
      iconClass: "folder",
      headline: e.name,
      meta: pending ? "Indexing…" : shares ? `${formatSize(e.size)} · updated ${formatDate(e.mtime)}` : formatSize(e.size),
      cols: {
        type: pending ? "" : "Folder",
        size: pending ? "Indexing…" : formatSize(e.size),
        date: pending ? "" : formatDate(e.mtime),
      },
      onClick: () => { path.push({ name: e.name, cid: e.cid, pending }); showLocation(); },
    });
  }
  const fetchIt = (btn) => downloadFile(device, e, btn);
  return row({
    icon: iconFor(e.name, false),
    headline: e.name,
    meta: `${formatSize(e.size)} · ${formatDate(e.mtime)}`,
    cols: {
      type: fileType(e.name, false),
      size: formatSize(e.size),
      date: formatDate(e.mtime),
    },
    onClick: () => openPreview(deviceSource(device), files, files.indexOf(e)),
    menu: deviceSource(device).menu(e),
    actions: [
      { icon: "info", label: `Details of ${e.name}`, run: () => openDetails(e.name, { cid: e.cid, peer: device.peer }) },
      { icon: "download", label: "Download", run: fetchIt },
    ],
  });
}

async function showLocation() {
  if (path.length === 0) return showDevices();
  renderCrumbs();
  const nav = ++browseNav;
  const device = path[0].device;
  const where = [device.peer, ...path.slice(1).map((p) => p.name)].join("/");

  if (path.length === 1) {
    busy(false);
    browse = { device, shares: true };
    browseShowing = where;
    listLoaded($("remote-list"));
    browseTable.show(device.shares.map((sh) => ({ ...sh, dir: true })));
    return;
  }

  const here = path[path.length - 1];
  if (browseShowing !== where) {
    setEmpty("");
    listLoading($("remote-list"));
  }
  busy(true);
  let entries;
  try {
    entries = await invoke("browse", { peer: device.peer, cid: here.cid });
  } catch (err) {
    if (nav !== browseNav) return;
    busy(false);
    listLoaded($("remote-list"));
    $("remote-list").replaceChildren();
    setEmpty(`Couldn't open ${here.name}: ${err}`);
    browseShowing = "";
    return;
  }
  if (nav !== browseNav) return;
  busy(false);
  listLoaded($("remote-list"));
  browse = { device, shares: false };
  browseShowing = where;
  browseTable.show(entries);
}

/** Downloads, from wherever the app is (the viewer closes). */
function goToDownloads() {
  closePreview();
  setView("downloads");
}

/** Starts a download (it runs in the background; Downloads follows it). */
async function startDownload(command, args) {
  const running = [...downloads.values()].find((d) => d.state === "running" && d.cid === args.cid);
  if (running) return snack(`${args.name} is already downloading`, 4000, goToDownloads);
  try {
    const d = await invoke(command, args);
    downloads.set(d.id, d);
    renderDownloads();
    snack(`Downloading ${d.name} · tap to see it in Downloads`, 5000, goToDownloads);
  } catch (err) {
    snack(`Download failed: ${err}`);
  }
}

function downloadFile(device, entry) {
  return startDownload("download", { peer: device.peer, cid: entry.cid, name: entry.name, size: entry.size });
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
  const source = {
    read: (e, offset, len) => invoke("read_range", { peer: device.peer, cid: e.cid, offset, len }),
    mediaUrl: (e, external = false, network = "") => invoke("media_url", { kind: "device", id: device.peer, cid: e.cid, size: e.size, name: e.name, external, network }),
    download: (e, btn) => downloadFile(device, e, btn),
    menu: (e) => fileMenu(source, e, { cid: e.cid, peer: device.peer }),
  };
  return source;
}
/** ...or the swarm folder (the device that added it, then anyone). */
const swarmSource = {
  read: (e, offset, len) => invoke("swarm_read_range", { cid: e.cid, author_id: e.author_id, offset, len }),
  mediaUrl: (e, external = false, network = "") => invoke("media_url", { kind: "swarm", id: e.author_id, cid: e.cid, size: e.size, name: e.name, external, network }),
  download: (e, btn) => swarmDownload(e, btn),
  menu: (it) => swarmMenu(it),
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
  document.body.classList.add("pv-open");
  showPreview();
  syncBack();
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
  stopNative();
  pv.token++;
  if (pv.url) URL.revokeObjectURL(pv.url);
  pv = null;
  $("pv-body").replaceChildren();
  $("preview").hidden = true;
  document.body.classList.remove("pv-open");
  syncBack();
}

// The native player: GPU rendering and every format the system plays,
// shown over the whole window. Null where the platform has none.
const nativeVideo = window.oriel.video?.available ? window.oriel.video : null;

async function streamPreview(entry, kind, token) {
  let url;
  try {
    // The native player gets an address other apps can open too, so its
    // "Open in another app" works (Android's in-app scheme is WebView-only).
    url = await pv.source.mediaUrl(entry, kind === "video" && !!nativeVideo);
  } catch (err) {
    if (pv && token === pv.token) previewMessage("file", `Preview failed: ${err}`);
    return;
  }
  if (!pv || token !== pv.token) return;
  if (kind === "video" && nativeVideo) return playNative(entry, url, token);
  inPagePlayer(kind, url, token);
}

// The native player, embedded in the viewer under its bar: { slot, observer }.
// Its fullscreen button covers the screen; Esc or Back come back here.
let pvNative = null;

/** Plays in the native player over the viewer's body (the bar stays the
 * page's: name, previous and next, the ⋮ menu). Falls back to the page's
 * player if the native one fails. */
async function playNative(entry, url, token) {
  stopNative();
  const slot = document.createElement("div");
  slot.className = "pv-native";
  $("pv-body").replaceChildren(slot);
  const rect = () => slot.getBoundingClientRect();
  const observer = new ResizeObserver(() => { if (pvNative?.slot === slot) nativeVideo.setRect(rect()).catch(() => {}); });
  pvNative = { slot, observer, entry, url, token };
  try {
    await nativeVideo.play({ url, title: entry.name, rect: rect() });
    observer.observe(slot);
    syncVideoCover();
  } catch (err) {
    if (pvNative?.slot === slot) pvNative = null;
    if (pv && token === pv.token) inPagePlayer("video", url, token);
  }
}

/** Closes the embedded player, if one plays (the viewer moved on or closed). */
function stopNative() {
  if (!pvNative) return;
  pvNative.observer.disconnect();
  pvNative = null;
  nativeVideo?.close().catch(() => {});
}

// Closed under the viewer (its Activity went away): offer to play it again.
window.oriel.listen?.("video:closed", () => {
  if (!pvNative || !pv || pvNative.token !== pv.token) return;
  const { entry, url, token, observer } = pvNative;
  observer.disconnect();
  pvNative = null;
  const again = document.createElement("button");
  again.className = "btn filled";
  again.textContent = "Play";
  again.addEventListener("click", () => playNative(entry, url, token));
  previewMessage("video", "The video player closed.", again);
});

/** Native views draw above the page: while a menu or dialog shows over the
 * viewer, the player hides (and keeps its place). */
function syncVideoCover() {
  if (!pvNative) return;
  const covered = !!menuEl || !$("details").hidden || !$("ask").hidden;
  if (covered === pvNative.covered) return;
  pvNative.covered = covered;
  nativeVideo.setVisible(!covered).catch(() => {});
}
for (const id of ["details", "ask"]) new MutationObserver(syncVideoCover).observe($(id), { attributes: true, attributeFilter: ["hidden"] });

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
  stopNative();
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
// The open file's menu: what its row's right-click offers. An edit
// (rename, move, delete) closes the viewer: the file it shows changed.
$("pv-menu").addEventListener("click", () => {
  if (!pv) return;
  const r = $("pv-menu").getBoundingClientRect();
  const items = pv.source.menu(pv.files[pv.index]).map((it) => it === "-" || !it.changes ? it : { ...it, run: () => { closePreview(); it.run(); } });
  showMenu(r.right - 220, r.bottom + 4, items);
});

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

$("device-about").addEventListener("click", () => { if (path.length) openDeviceInfo(path[0].name, path[0].device.peer); });
$("remote-refresh").addEventListener("click", () => (path.length ? refreshLocation() : showDevices()));

/** Reloads the open folder as it is now: a share's root changes with every
 *  edit (and while a first scan fills it in), so the path is walked again
 *  by name from the device's current share list. */
async function refreshLocation() {
  const peer = path[0].device.peer;
  busy(true);
  try {
    const fresh = (await invoke("remote_devices", null)).find((d) => d.peer === peer);
    if (!fresh) throw new Error("the device isn't reachable");
    const walked = [{ ...path[0], device: fresh }];
    let entries = fresh.shares.map((sh) => ({ ...sh, dir: true }));
    for (const step of path.slice(1)) {
      const e = entries.find((x) => x.dir && x.name === step.name);
      if (!e) break; // gone: stop at the deepest folder still there
      walked.push({ name: e.name, cid: e.cid, pending: !e.mtime && !e.size });
      if (walked.length < path.length) entries = await invoke("browse", { peer, cid: e.cid });
    }
    path = walked;
  } catch (err) {
    snack(`Couldn't refresh: ${err.message || err}`);
  } finally {
    busy(false);
  }
  showLocation();
}

// ---- Swarm folder: one folder all devices read and write ----

let swarmDir = ""; // "" = top; "a/b" below

function swarmCrumbs() {
  const parts = swarmDir ? swarmDir.split("/") : [];
  drawCrumbs($("swarm-crumbs"), [{ label: "Swarm", dir: "" }, ...parts.map((p, i) => ({ label: p, dir: parts.slice(0, i + 1).join("/") }))]
    .map((c) => ({ label: c.label, go: () => { swarmDir = c.dir; loadSwarm(); } })));
  syncBack();
}

function swarmStatusText(st) {
  if (!running) return "Node stopped";
  const devices = st.peers_synced === 1 ? "1 device" : `${st.peers_synced} devices`;
  const when = st.last_sync ? timeAgo(st.last_sync * 1000) : "not yet";
  const failed = st.peers_failed ? ` · ${st.peers_failed} couldn't sync` : "";
  return `${st.entries} item${st.entries === 1 ? "" : "s"} · synced with ${devices} · ${when}${failed}`;
}

let swarmNav = 0;

async function loadSwarm() {
  swarmCrumbs();
  const nav = ++swarmNav;
  const list = $("swarm-list");
  if (!running) {
    list.replaceChildren();
    $("swarm-empty").hidden = false;
    $("swarm-empty").textContent = "Start the node to see the swarm folder.";
    $("swarm-status").textContent = "Node stopped";
    swarmTable.dir = null;
    return;
  }
  // Another folder: its rows aren't these. A refresh keeps them meanwhile.
  if (swarmTable.dir !== swarmDir) {
    $("swarm-empty").hidden = true;
    listLoading(list);
  }
  let res;
  try {
    res = await invoke("swarm_list", { dir: swarmDir });
  } catch (err) {
    if (nav !== swarmNav) return;
    listLoaded(list);
    snack(`Swarm folder: ${err}`);
    return;
  }
  if (nav !== swarmNav) return;
  listLoaded(list);
  $("swarm-status").textContent = swarmStatusText(res);
  if (!res.items.length && swarmDir) { // folder vanished (deleted elsewhere): go up
    swarmDir = swarmDir.split("/").slice(0, -1).join("/");
    return loadSwarm();
  }
  // Same folder (a refresh): keep what is typed in the search.
  if (swarmTable.dir === swarmDir) {
    swarmTable.entries = res.items;
    swarmTable.render();
  } else {
    swarmTable.dir = swarmDir;
    swarmTable.show(res.items);
  }
}

const swarmTable = new FileTable({
  view: "swarm",
  tools: $("swarm-tools"),
  head: $("swarm-head"),
  list: $("swarm-list"),
  columns: [
    { key: "type", label: "Type", cls: "th-type" },
    { key: "size", label: "Size", cls: "th-size" },
    { key: "mtime", label: "Modified", cls: "th-date" },
    { key: "author", label: "Added by", cls: "th-by" },
  ],
  storageKey: "swarmSort",
  actions: 4,
  setEmpty: (text) => {
    $("swarm-empty").hidden = !text;
    $("swarm-empty").textContent = text;
  },
  emptyText: () => "Empty. Add a file, or create a folder; every device sees it.",
  renderRow: (it, files) => swarmRow(it, files),
});

function swarmRow(it, files) {
  const by = it.author || "";
  const actions = [
    { icon: "edit", label: `Rename ${it.name}`, run: () => swarmRenamePrompt(it) },
    { icon: "trash", label: `Delete ${it.name}`, run: () => swarmDeleteConfirm(it) },
  ];
  if (!it.dir) actions.unshift({ icon: "download", label: "Download", run: (btn) => swarmDownload(it, btn) });
  if (!it.dir && it.cid) actions.unshift({ icon: "info", label: `Details of ${it.name}`, run: () => openDetails(it.name, { cid: it.cid, author_id: it.author_id }) });
  return row({
    menu: swarmMenu(it),
    icon: it.dir ? "folder" : iconFor(it.name, false),
    iconClass: it.dir ? "folder" : "",
    headline: it.name,
    meta: it.dir ? formatSize(it.size) : `${formatSize(it.size)} · ${formatDate(it.mtime)}${by ? ` · ${by}` : ""}`,
    cols: {
      type: it.dir ? "Folder" : fileType(it.name, false),
      size: formatSize(it.size),
      date: formatDate(it.mtime),
      by,
    },
    onClick: it.dir
      ? () => { swarmDir = it.path; loadSwarm(); }
      : () => openPreview(swarmSource, files, files.indexOf(it)),
    actions,
  });
}

/** A swarm item's menu: a file's actions, then the edits (a folder has only those). */
function swarmMenu(it) {
  const edits = [
    { icon: "edit", label: "Rename", run: () => swarmRenamePrompt(it), changes: true },
    { icon: "move", label: "Move to…", run: () => swarmMovePrompt(it), changes: true },
    { icon: "trash", label: "Delete", run: () => swarmDeleteConfirm(it), danger: true, changes: true },
  ];
  return it.dir || !it.cid ? edits : [...fileMenu(swarmSource, it, { cid: it.cid, author_id: it.author_id }), "-", ...edits];
}

function swarmDownload(it) {
  return startDownload("swarm_download", { cid: it.cid, author_id: it.author_id, name: it.name, size: it.size });
}

// ---- Downloads: what was saved, where, and how far a copy has got ----

const downloads = new Map(); // id → a download, as downloads_list gives it

/** A finished download plays and previews from its saved file. */
const downloadSource = {
  read: (e, offset, len) => invoke("download_read_range", { id: e.id, offset, len }),
  mediaUrl: (e, external = false) => invoke("media_url", { kind: "download", id: String(e.id), size: e.size, name: e.name, external }),
  download: () => showDownloadsFolder(),
  menu: (d) => downloadMenu(d),
};

let downloadsFolder = "";

async function loadDownloads() {
  try {
    const list = await invoke("downloads_list", null);
    downloads.clear();
    for (const d of list) downloads.set(d.id, d);
    downloadsFolder ||= await invoke("downloads_dir", null);
    $("downloads-where").textContent = `Saved in ${downloadsFolder}`;
  } catch (err) {
    $("downloads-where").textContent = `${err}`;
  }
  renderDownloads();
}

window.oriel.listen?.("download://progress", ({ id, done, size, state, error }) => {
  const d = downloads.get(id);
  if (!d) return loadDownloads();
  const was = d.state;
  Object.assign(d, { done, size, state, error });
  if (state !== "running") {
    d.exists = state === "done";
    if (was === "running" && state === "done") snack(`${d.name} downloaded · tap to open Downloads`, 6000, goToDownloads);
    if (was === "running" && state === "failed") snack(`${d.name} failed: ${error}`, 6000, goToDownloads);
    return renderDownloads();
  }
  updateDownloadRow(d);
});

/** The downloads folder in the system's file manager (Files on Android). */
function showDownloadsFolder() {
  invoke("downloads_open_folder", null).catch((err) => snack(`Couldn't open the folder: ${err}`));
}

/** The saved file in the app the system picks for it. */
function openDownloadElsewhere(d) {
  invoke("download_open", { id: d.id, mime: mimeFor(d.name) }).catch((err) => snack(`Couldn't open it: ${err}`));
}

function downloadProgressText(d) {
  if (!d.size) return `${formatSize(d.done)}`;
  const pct = Math.min(100, Math.floor((d.done / d.size) * 100));
  return `${formatSize(d.done)} of ${formatSize(d.size)} · ${pct}%`;
}

function downloadMeta(d) {
  if (d.state === "running") return downloadProgressText(d);
  if (d.state === "done") return d.exists ? `${formatSize(d.size)} · ${formatDate(d.finished)} · ${d.path}` : `Moved or deleted · was ${d.path}`;
  if (d.state === "canceled") return `Canceled · ${formatSize(d.done)} of ${formatSize(d.size)}`;
  return `Failed: ${d.error || "unknown error"}`;
}

function retryDownload(d) {
  return d.kind === "swarm"
    ? startDownload("swarm_download", { cid: d.cid, author_id: d.source_id, name: d.name, size: d.size })
    : startDownload("download", { peer: d.source_id, cid: d.cid, name: d.name, size: d.size });
}

async function removeDownload(d, deleteFile) {
  if (deleteFile && !(await askDialog({ title: `Delete ${d.name}?`, text: `${d.path} will be deleted from this device.`, confirm: "Delete", danger: true }))) return;
  try {
    await invoke("download_remove", { id: d.id, delete_file: deleteFile });
    downloads.delete(d.id);
    renderDownloads();
  } catch (err) {
    snack(`Couldn't remove it: ${err}`);
  }
}

function playable(d) { return d.state === "done" && d.exists; }

function downloadRow(d, files) {
  const running = d.state === "running";
  const ok = playable(d);
  const actions = running
    ? [{ icon: "remove", label: `Cancel ${d.name}`, run: () => invoke("download_cancel", { id: d.id }).catch((err) => snack(`${err}`)) }]
    : ok
      ? [
        { icon: "open_in", label: "Open in another app", run: () => openDownloadElsewhere(d) },
        { icon: "folder", label: "Show in folder", run: showDownloadsFolder },
      ]
      : [
        { icon: "download", label: `Download ${d.name} again`, run: () => retryDownload(d) },
        { icon: "remove", label: "Remove from the list", run: () => removeDownload(d, false) },
      ];
  const li = row({
    menu: downloadMenu(d),
    icon: iconFor(d.name, false),
    headline: d.name,
    meta: downloadMeta(d),
    onClick: ok ? () => openPreview(downloadSource, files, files.indexOf(d)) : null,
    actions,
  });
  li.dataset.download = d.id;
  return decorateDownloadRow(li, d);
}

/** A download's menu (its row's right-click, the viewer's ⋮). */
function downloadMenu(d) {
  const ok = playable(d);
  if (d.state === "running") return [{ icon: "remove", label: "Cancel", run: () => invoke("download_cancel", { id: d.id }).catch((err) => snack(`${err}`)) }];
  return [
    ...(ok ? [
      { icon: "open_in", label: "Open in another app", run: () => openDownloadElsewhere(d) },
      { icon: "folder", label: "Show in folder", run: showDownloadsFolder },
      { icon: "copy", label: "Copy path", run: () => copyText(d.path, "Path copied") },
    ] : [{ icon: "download", label: "Download again", run: () => retryDownload(d) }]),
    "-",
    { icon: "remove", label: "Remove from the list", run: () => removeDownload(d, false), changes: true },
    ...(ok ? [{ icon: "trash", label: "Delete the file", run: () => removeDownload(d, true), danger: true, changes: true }] : []),
  ];
}

/** A failed download's red line; a running one's progress bar. */
function decorateDownloadRow(li, d) {
  const running = d.state === "running";
  const meta = li.querySelector(".meta");
  if (d.state === "failed") meta.classList.add("dl-failed");
  if (running) {
    const bar = document.createElement("span");
    bar.className = "dl-progress";
    meta.after(bar);
    paintProgress(li, d);
  }
  return li;
}

function paintProgress(li, d) {
  const bar = li.querySelector(".dl-progress");
  if (!bar) return;
  bar.classList.toggle("indeterminate", !d.size);
  bar.style.setProperty("--p", d.size ? `${Math.min(100, (d.done / d.size) * 100)}%` : "0%");
}

/** A running copy's row, updated in place (no re-render every tick). */
function updateDownloadRow(d) {
  const li = $("downloads-list").querySelector(`li[data-download="${d.id}"]`);
  if (!li) return renderDownloads();
  li.querySelector(".meta").textContent = downloadProgressText(d);
  paintProgress(li, d);
}

function renderDownloads() {
  const all = [...downloads.values()].sort((a, b) => b.id - a.id);
  const running = all.filter((d) => d.state === "running").length;
  for (const badge of document.querySelectorAll("[data-downloads-badge]")) {
    badge.hidden = running === 0;
    badge.textContent = String(running);
  }
  if (document.body.dataset.view !== "downloads") return;
  const files = all.filter(playable);
  $("downloads-list").replaceChildren(...all.map((d) => downloadRow(d, files)));
  $("downloads-empty").hidden = all.length > 0;
  $("downloads-clear").hidden = !all.some((d) => d.state !== "running");
}

$("downloads-folder").addEventListener("click", showDownloadsFolder);
$("downloads-clear").addEventListener("click", async () => {
  await invoke("downloads_clear", null).catch((err) => snack(`${err}`));
  loadDownloads();
});

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

async function swarmMovePrompt(it) {
  const here = it.path.includes("/") ? it.path.slice(0, it.path.lastIndexOf("/")) : "";
  const to = await askDialog({
    title: `Move ${it.name}`,
    text: "To which folder of the swarm folder? Like Photos/2024; empty for the top.",
    value: here,
    confirm: "Move",
  });
  if (to === null || to === undefined) return;
  const dir = to.trim().replace(/^\/+|\/+$/g, "");
  if (dir === here) return;
  try {
    await invoke("swarm_move", { path: it.path, to_dir: dir });
    snack(`Moved to ${dir || "the top"}`);
  } catch (err) {
    snack(`${err}`.includes("PathAlreadyExists") ? `"${it.name}" already exists there.` : `Move failed: ${err}`);
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

let sharesNav = 0;

async function loadShares() {
  const nav = ++sharesNav;
  const list = $("shares-list");
  if (!running) {
    list.replaceChildren();
    return;
  }
  if (!list.children.length) listLoading(list, 2);
  let shares = [];
  try {
    shares = await invoke("shares_local", null);
  } catch (err) {
    if (nav !== sharesNav) return;
    listLoaded(list);
    list.replaceChildren();
    snack(`Shares failed: ${err}`);
    return;
  }
  if (nav !== sharesNav) return;
  listLoaded(list);
  list.replaceChildren();
  for (const s of shares) {
    const li = row({
      icon: "folder",
      iconClass: "folder",
      headline: s.name,
      meta: [
        s.scan_error ? `Can't read the folder (${s.scan_error}) · ${s.path}`
          : !s.ready ? `Scanning… ${s.path}`
          : s.indexing ? `Indexing… ${s.files} files so far · ${formatSize(s.size)} · ${s.path}`
          : `${s.files} files · ${formatSize(s.size)} · ${s.path}`,
        s.backup ? "Backup: checking…" : "",
      ],
      actions: [
        { icon: s.backup ? "backup" : "backup_off", label: s.backup ? `Stop backing up ${s.name}` : `Back up ${s.name}`, run: () => setShareBackup(s.name, !s.backup) },
        { icon: "remove", label: `Stop sharing ${s.name}`, run: () => removeShare(s.name) },
      ],
    });
    li.dataset.share = s.name;
    list.appendChild(li);
  }
  if (shares.some((s) => s.backup)) loadBackupStatus();
}

/** Where each folder marked for backup is kept, on its row. */
async function loadBackupStatus() {
  let status = [];
  try {
    status = await invoke("backup_status", null);
  } catch {
    return;
  }
  for (const s of status) {
    const li = [...$("shares-list").children].find((el) => el.dataset.share === s.share);
    const meta = li && li.querySelectorAll(".meta")[1];
    if (!meta) continue;
    const where = `In the swarm folder at ${s.path} (${s.files} file${s.files === 1 ? "" : "s"})`;
    const kept = s.keepers.length ? `kept by ${s.keepers.join(" · ")}` : "no backup device met yet";
    meta.textContent = s.unmetered ? `${where} · ${kept}` : `${where} · new files wait for Wi-Fi`;
  }
}

async function setShareBackup(name, on) {
  try {
    await invoke("share_backup_set", { config_path: await ensureConfig(), name, on });
    snack(on ? `${name} goes into the swarm folder; the backup devices keep it` : `Stopped backing up ${name}; copies already made stay`);
  } catch (err) {
    snack(`Couldn't change the backup: ${err}`);
  }
  loadShares();
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

/** Shows the share form for `path`, with the name pre-filled; `backup`
 *  ticks "Back up" (the camera presets). */
function stageShare(path, name, backup = false) {
  path = String(path || "");
  $("share-path").textContent = path;
  $("share-name").value = name || path.split("/").filter(Boolean).pop() || "";
  $("share-backup").checked = backup;
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
    await invoke("share_add", { config_path: await ensureConfig(), name, path: sharePath, backup: $("share-backup").checked });
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
  // Camera, Screenshots and WhatsApp come with "Back up" ticked.
  const items = [
    ["Camera", info.camera, true],
    ["Screenshots", info.screenshots, true],
    ["WhatsApp", info.whatsapp, true],
    ["Pictures", info.pictures, false],
    ["Documents", info.documents, false],
    ["Download", info.downloads, false],
  ];
  for (const [label, p, backup] of items) {
    if (!p) continue;
    const b = document.createElement("button");
    b.type = "button";
    b.textContent = label;
    b.addEventListener("click", () => stageShare(p, label, backup));
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

// ---- Text drop: notes in the swarm folder's Notes, on every device ----

const NOTES_DIR = "Notes";
// Before 0.3.6 each device kept its own list of notes it had stored or
// opened here; the ones it stored move into the swarm (migrateOldNotes).
const OLD_NOTES_KEY = "notes";

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

let swarmNotes = []; // swarm_list items of Notes, newest first

/** "2026-10-28 17-49-03 Shopping list.txt" -> "Shopping list". */
function noteTitle(name) {
  return name.replace(/^\d{4}-\d\d-\d\d \d\d-\d\d-\d\d /, "").replace(/\.txt$/i, "") || name;
}

async function loadSwarmNotes() {
  if (!running) {
    swarmNotes = [];
    renderNotes();
    return;
  }
  try {
    const res = await invoke("swarm_list", { dir: NOTES_DIR });
    swarmNotes = res.items.filter((it) => !it.dir).sort((a, b) => b.mtime - a.mtime);
  } catch {
    swarmNotes = [];
  }
  renderNotes();
  migrateOldNotes();
}

function renderNotes() {
  const list = $("notes-list");
  list.replaceChildren();
  $("notes-empty").hidden = swarmNotes.length > 0;
  for (const n of swarmNotes) {
    list.appendChild(row({
      icon: "file",
      headline: noteTitle(n.name),
      meta: `${n.author || "A device"} · ${timeAgo(n.mtime * 1000)} · ${formatSize(n.size)}`,
      onClick: () => showNote(n),
      action: { icon: "copy", label: "Copy code", run: () => copyText(n.cid, "Code copied") },
    }));
  }
}

/** A note's text, from its author or any device that has it. */
async function readSwarmNote(n) {
  const parts = [];
  for (let offset = 0; offset < n.size;) {
    const len = Math.min(RANGE, n.size - offset);
    const bytes = decodeBase64(await invoke("swarm_read_range", { cid: n.cid, author_id: n.author_id, offset, len }));
    if (bytes.length === 0) break;
    parts.push(bytes);
    offset += bytes.length;
  }
  return new TextDecoder().decode(concat(parts));
}

/** Shows a note in the viewer: `load` resolves to its text. */
async function viewNote(label, cid, load) {
  const view = $("note-view");
  view.hidden = false;
  view.classList.remove("error");
  $("note-meta").textContent = `Opening ${label}…`;
  $("text-out").textContent = "";
  $("note-copy").hidden = true;
  try {
    const text = await load();
    $("text-out").textContent = text;
    $("note-meta").textContent = `${label} · ${formatSize(new TextEncoder().encode(text).length)} · ${shortCid(cid)}`;
    $("note-copy").hidden = false;
    $("note-copy").onclick = () => copyText(text, "Text copied");
    view.scrollIntoView({ block: "nearest", behavior: "smooth" });
  } catch (err) {
    view.classList.add("error");
    $("note-meta").textContent = label;
    $("text-out").textContent = `Couldn't open this note: ${err}. The devices that have it may be offline.`;
  }
}

function showNote(n) {
  $("cid-in").value = n.cid;
  return viewNote(noteTitle(n.name), n.cid, () => readSwarmNote(n));
}

/** Notes this device stored before they went into the swarm: copied into
 *  Notes once, then dropped from the old list. */
let migrating = false;
async function migrateOldNotes() {
  if (migrating || !running) return;
  let old;
  try { old = JSON.parse(localStorage.getItem(OLD_NOTES_KEY) || "[]"); } catch { old = []; }
  if (!old.length) return;
  migrating = true;
  const keep = [];
  for (const n of old) {
    if (n.kind !== "stored" || swarmNotes.some((x) => x.cid === n.cid)) continue;
    try {
      await invoke("note_store", { text: await invoke("get_text", { cid: n.cid }) });
    } catch {
      keep.push(n); // try again next time
    }
  }
  try {
    if (keep.length) localStorage.setItem(OLD_NOTES_KEY, JSON.stringify(keep));
    else localStorage.removeItem(OLD_NOTES_KEY);
  } catch {}
  migrating = false;
  if (keep.length < old.length) loadSwarmNotes();
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
    const note = await invoke("note_store", { text });
    $("cid-output").textContent = `${NOTES_DIR}/${note.name}`;
    $("cid-output").title = note.cid;
    $("cid-copy").onclick = () => copyText(note.cid, "Code copied");
    $("cid-box").hidden = false;
    $("text-in").value = "";
    loadSwarmNotes();
  } catch (err) {
    snack(`Store failed: ${err}`);
  }
  updateComposer();
});

/** By code: a note in the swarm's Notes, else any file with that CID. */
async function openNote(cid) {
  if (!/^[0-9a-fA-F]{64}$/.test(cid)) {
    snack("A note code is 64 hex characters");
    return;
  }
  cid = cid.toLowerCase();
  const known = swarmNotes.find((n) => n.cid === cid);
  if (known) return showNote(known);
  return viewNote(shortCid(cid), cid, () => invoke("get_text", { cid }));
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

renderNotes();
updateComposer();

// ---- About ----

let aboutText = "";

function openLink(url) {
  invoke("open_path", { path: url }).catch(() => window.open(url, "_blank"));
}

// ---- Updates: signed releases from GitHub (src/updates.zig) ----

// How this copy updates ("install": the AppImage replaces itself,
// "download": the browser fetches the new APK, "manual": deb, rpm or a
// build from source), then what the last check found.
const upd = { info: null, version: null, busy: false, ready: false };
const UPDATE_EVERY_MS = 6 * 60 * 60 * 1000;

function updateAutoOn() {
  try { return localStorage.getItem("updateAuto") !== "0"; } catch { return true; }
}

function renderUpdate(status) {
  if (status) $("update-status").textContent = status;
  const action = $("update-action");
  action.hidden = !(upd.version && !upd.busy);
  if (upd.ready) action.textContent = "Restart now";
  else if (upd.info?.mode === "install") action.textContent = `Update to ${upd.version}`;
  else if (upd.info?.mode === "download") action.textContent = `Download ${upd.version}`;
  else action.textContent = `Get ${upd.version}`;
  $("update-check").disabled = upd.busy;
  for (const el of document.querySelectorAll('.nav-item[data-view="about"], #bar-more')) el.classList.toggle("has-update", !!upd.version);
}

/** Asks the release server; `quiet` (automatic checks) stays silent
 *  unless something new is out. */
async function checkUpdate(quiet) {
  if (upd.busy || upd.ready) return;
  upd.busy = true;
  renderUpdate("Checking for updates…");
  try {
    upd.info ||= await invoke("update_info", null);
    const r = await invoke("updater_check", null);
    upd.version = r.available ? r.version : null;
    renderUpdate(upd.version
      ? `NomadFS ${upd.version} is available (you have ${upd.info.current}).`
      : `NomadFS ${upd.info.current} is the latest version.`);
    if (upd.version && quiet) snack(`NomadFS ${upd.version} is available. Tap to update.`, 10000, () => setView("about"));
  } catch (err) {
    renderUpdate(quiet ? "Couldn't check for updates." : `Couldn't check for updates: ${err}`);
  } finally {
    upd.busy = false;
    renderUpdate();
  }
}

async function runUpdate() {
  if (upd.ready) return invoke("updater_restart", null).catch((err) => snack(`Couldn't restart: ${err}`));
  if (!upd.version || upd.busy) return;
  if (upd.info.mode === "download") return openLink(upd.info.apk.replaceAll("{v}", upd.version));
  if (upd.info.mode !== "install") {
    snack("Install it with your package manager, or download it from the release page.", 6000);
    return openLink(upd.info.releases);
  }
  upd.busy = true;
  const bar = $("update-progress");
  bar.hidden = false;
  bar.style.setProperty("--p", "0%");
  renderUpdate(`Downloading NomadFS ${upd.version}…`);
  const stop = window.oriel.listen?.("updater://progress", ({ downloaded, total }) => {
    if (!total) return;
    bar.style.setProperty("--p", `${Math.round((downloaded / total) * 100)}%`);
    $("update-status").textContent = `Downloading NomadFS ${upd.version}… ${formatSize(downloaded)} of ${formatSize(total)}`;
  });
  try {
    await invoke("updater_install", null);
    upd.ready = true;
    renderUpdate(`NomadFS ${upd.version} is installed. Restart to use it.`);
    snack(`NomadFS ${upd.version} is installed. Tap to restart.`, 15000, () => runUpdate());
  } catch (err) {
    renderUpdate(`The update failed: ${err}. The current version stays in place.`);
  } finally {
    stop?.();
    upd.busy = false;
    bar.hidden = true;
    renderUpdate();
  }
}

$("update-check").addEventListener("click", () => checkUpdate(false));
$("update-action").addEventListener("click", runUpdate);
$("update-auto").checked = updateAutoOn();
$("update-auto").addEventListener("change", (e) => {
  try { localStorage.setItem("updateAuto", e.target.checked ? "1" : "0"); } catch {}
});
// Shortly after start, then every few hours while the app runs.
setTimeout(() => updateAutoOn() && checkUpdate(true), 15000);
setInterval(() => updateAutoOn() && checkUpdate(true), UPDATE_EVERY_MS);

// ---- Read cache (About) ----

async function loadCache() {
  let c;
  try {
    c = await invoke("cache_info", { config_path: await ensureConfig() });
  } catch (err) {
    $("cache-status").textContent = `Couldn't read the cache: ${err}`;
    return;
  }
  const limit = c.limit_mb ? formatSize(c.limit_mb * 1024 * 1024) : "no limit";
  $("cache-status").textContent = `${formatSize(c.bytes)} of ${limit} · ${c.blocks} blocks`;
  const sel = $("cache-limit");
  const want = String(c.limit_mb);
  if (![...sel.options].some((o) => o.value === want)) {
    const o = document.createElement("option");
    o.value = want;
    o.textContent = formatSize(c.limit_mb * 1024 * 1024);
    sel.append(o);
  }
  sel.value = want;
}

$("cache-clear").addEventListener("click", async (e) => {
  const btn = e.currentTarget;
  btn.disabled = true;
  try {
    const freed = await invoke("cache_clear", { config_path: await ensureConfig() });
    snack(`Cleared the read cache: ${formatSize(freed)} freed.`);
  } catch (err) {
    snack(`Couldn't clear the cache: ${err}`);
  }
  btn.disabled = false;
  loadCache();
});

$("cache-limit").addEventListener("change", async (e) => {
  try {
    await invoke("cache_set_limit", { config_path: await ensureConfig(), limit_mb: Number(e.target.value) });
    snack("Read cache limit saved.");
  } catch (err) {
    snack(`Couldn't change the limit: ${err}`);
  }
  loadCache();
});

async function loadAbout() {
  let a;
  try {
    a = await invoke("about_info", { config_path: await ensureConfig() });
  } catch (err) {
    $("about-body").textContent = `Couldn't read the details: ${err}`;
    return;
  }
  $("about-version").textContent = a.nomadfs;
  loadCache();
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
  // The copies settings are for every device; backing up all of it, for desktops.
  $("backup-section").hidden = false;
  $("swarm-backup-row").hidden = !st.supported;
  $("swarm-copies").value = String(Math.min(Math.max(st.copies ?? 1, 1), 4));
  $("accept-copies").checked = !!st.accept_copies;
  $("copies-state").textContent = st.accept_copies
    ? (st.kept_copies ? `Keeps ${st.kept_copies} file${st.kept_copies === 1 ? "" : "s"} for other devices.` : "")
    : "This device keeps only its own files (and backups, if on).";
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

$("swarm-copies").addEventListener("change", async (e) => {
  const copies = Number(e.target.value);
  try {
    renderBackup(await invoke("swarm_copies_set", { config_path: await ensureConfig(), copies }));
    snack(copies === 1 ? "Each swarm file stays where it was added (and on backup devices)" : `Each swarm file is kept on ${copies} devices`);
  } catch (err) {
    snack(`Couldn't change it: ${err}`);
    loadBackup();
  }
});

$("accept-copies").addEventListener("change", async (e) => {
  const on = e.target.checked;
  try {
    renderBackup(await invoke("accept_copies_set", { config_path: await ensureConfig(), on }));
    snack(on ? "This device keeps copies of other devices' files" : "This device no longer takes copies of other devices' files");
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
  if (!list.children.length) listLoading(list, 3);
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
    const unpaired = reachable.filter((d) => !d.trusted);
    list.replaceChildren();
    for (const d of trusted) {
      const online = reachable.some((r) => r.trusted && r.fingerprint === d.fingerprint);
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
      const title = deviceTitle(d);
      const qualifier = d.nickname ? `Claims to be "${d.nickname}". ` : "";
      list.appendChild(row({
        icon: "device",
        headline: title,
        meta: `${qualifier}Connected, not paired: shares your swarm key, but its identity isn't verified. Pair it with an invite.`,
        meta2: d.fingerprint,
      }));
    }
    if (!trusted.length && !unpaired.length) {
      list.appendChild(row({ icon: "device", headline: "No devices yet", meta: "Connect one under Connect devices" }));
    }
  } catch (err) {
    list.replaceChildren();
    snack(`Devices failed: ${err}`);
  }
  listLoaded(list);
});

// ---- Swarm key rotation ----

$("rotate-key").addEventListener("click", async () => {
  if (!running) return snack("Start the node first");
  let trusted = [], reachable = [];
  try {
    trusted = await invoke("devices_list", { config_path: await ensureConfig() });
    reachable = await invoke("remote_devices", null);
  } catch {}
  const online = new Set(reachable.filter((r) => r.trusted).map((r) => r.fingerprint));
  const gets = trusted.filter((d) => online.has(d.fingerprint)).map((d) => d.label);
  const offline = trusted.filter((d) => !online.has(d.fingerprint)).map((d) => d.label);
  const unpaired = reachable.filter((r) => !r.trusted).map(deviceTitle);
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
  if (view !== "downloads") loadDownloads(); // the running count on its tab
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

// ---- File details: how NomadFS stores a file ----

// Chunk map colours: the app's primary and tertiary, its muted text colour, and the
// outline for chunks this device doesn't hold.
const DT_STATES = [
  ["kept", "Kept on this device", "--md-primary"],
  ["cached", "In the read cache", "--md-tertiary"],
  ["external", "Read from the shared file here", "--md-on-surface-variant"],
  ["missing", "Not here: fetched when read", "--md-outline-variant"],
];

function cssVar(name) {
  return getComputedStyle(document.body).getPropertyValue(name).trim() || "#888";
}

async function openDetails(name, src) {
  $("dt-name").textContent = name;
  $("dt-meta").textContent = "Reading the file's structure…";
  const body = $("dt-body");
  body.replaceChildren();
  $("details").hidden = false;
  let d;
  try {
    d = await invoke("file_details", src);
  } catch (err) {
    $("dt-meta").textContent = `Couldn't read the details: ${err}`;
    return;
  }
  $("dt-meta").textContent = `${formatSize(d.size)} · ${d.chunks} chunk${d.chunks === 1 ? "" : "s"}`;
  const el = (tag, cls, text) => {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text !== undefined) n.textContent = text;
    return n;
  };
  const section = (title, ...nodes) => {
    body.append(el("h3", "", title), ...nodes);
  };

  // Identity
  const cidRow = el("div", "dt-cid");
  cidRow.append(el("code", "", d.cid));
  const copy = el("button", "btn outlined", "Copy");
  copy.type = "button";
  copy.addEventListener("click", async () => {
    try { await navigator.clipboard.writeText(d.cid); snack("CID copied"); } catch { snack("Select the CID to copy it"); }
  });
  cidRow.append(copy);
  section("Content ID (CID)", cidRow,
    el("p", "", "The SHA-256 hash of the file's root block. Every device names this file by it; any change to the content gives a different CID, so a block can't be swapped without being noticed."));

  // Structure
  const stats = el("div", "dt-stats");
  const stat = (value, label) => {
    const s = el("div", "dt-stat");
    s.append(el("b", "", value), el("span", "", label));
    stats.append(s);
  };
  stat(String(d.chunks), "chunks (leaf blocks)");
  stat(String(d.parents), d.parents === 1 ? "parent block" : "parent blocks");
  stat(String(d.depth + 1), "levels in the tree");
  stat(formatSize(d.chunk_avg), "average chunk");
  stat(`${formatSize(d.chunk_min)} – ${formatSize(d.chunk_max)}`, "smallest – largest chunk");
  section("How it's stored", stats,
    el("p", "", d.depth === 0
      ? "The file fits in one chunk, so its root block is the chunk itself."
      : `The file is cut into chunks by FastCDC (content-defined chunking: ${formatSize(d.chunker_min)} to ${formatSize(d.chunker_max)}, ${formatSize(d.chunker_avg)} on average). Boundaries follow the content, so an edit in the middle only changes the chunks around it. Parent blocks list the chunks' CIDs and sizes, forming a Merkle tree whose root is the file's CID.`));

  // Chunk map
  const canvas = el("canvas", "dt-map");
  const legend = el("div", "dt-legend");
  const counts = [d.kept, d.cached, d.external, d.missing];
  DT_STATES.forEach(([, label, color], i) => {
    if (!counts[i]) return;
    const item = el("span");
    const sw = el("i");
    sw.style.background = cssVar(color);
    item.append(sw, `${label}: ${counts[i]} (${Math.round(100 * counts[i] / Math.max(1, d.chunks))}%)`);
    legend.append(item);
  });
  section("Chunk map", canvas, legend,
    el("p", "", "Each segment is one chunk, as wide as its share of the file. Reading a range fetches only the chunks it covers; fetched chunks go to the read cache."));
  requestAnimationFrame(() => drawChunkMap(canvas, d));

  // First chunks
  if (d.first.length) {
    const table = el("table", "dt-table");
    const head = el("tr");
    for (const h of ["Offset", "Size", "CID", "Where"]) head.append(el("th", "", h));
    table.append(head);
    for (const c of d.first) {
      const tr = el("tr");
      tr.append(el("td", "", formatSize(c.offset)), el("td", "", formatSize(c.size)), el("td", "", `${c.cid.slice(0, 12)}…`), el("td", "", c.where));
      table.append(tr);
    }
    const wrap = el("div");
    wrap.style.overflowX = "auto";
    wrap.append(table);
    section(d.chunks > d.first.length ? `First ${d.first.length} chunks` : "Chunks", wrap);
  }

  // Learn more
  const links = el("div", "dt-links");
  for (const [label, page] of [["FastCDC", "fastcdc"], ["Merkle DAG", "merkle-dag"], ["SHA-256", "sha-256"]]) {
    const b = el("button", "btn text", label);
    b.type = "button";
    b.addEventListener("click", () => openLink(`https://nomadfs.foreachdeveloper.com/learn/${page}/`));
    links.append(b);
  }
  section("Learn more", links);
}

function drawChunkMap(canvas, d) {
  const ratio = window.devicePixelRatio || 1;
  const w = canvas.clientWidth;
  const h = canvas.clientHeight;
  canvas.width = Math.round(w * ratio);
  canvas.height = Math.round(h * ratio);
  const g = canvas.getContext("2d");
  g.scale(ratio, ratio);
  const colors = DT_STATES.map(([, , c]) => cssVar(c));
  const total = d.size || 1;
  let x = 0;
  for (let i = 0; i < d.sizes.length; i++) {
    const width = (d.sizes[i] / total) * w;
    g.fillStyle = colors[d.states[i]] || colors[3];
    g.fillRect(x, 0, Math.max(width, 0.6), h);
    // A thin gap between chunks while they're wide enough to see.
    if (width > 3) {
      g.fillStyle = "rgb(0 0 0 / .35)";
      g.fillRect(x + width - 1, 0, 1, h);
    }
    x += width;
  }
}

// ---- A device's About and health (device_info, asked on demand) ----

let deviceInfoToken = 0;

function formatUptime(s) {
  if (s < 60) return `${s} s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m} min`;
  const h = Math.floor(m / 60);
  if (h < 48) return `${h} h ${m % 60} min`;
  return `${Math.floor(h / 24)} days ${h % 24} h`;
}

/** [status, text] checks from what the device reported: ok, warn or bad. */
function deviceHealth(i) {
  const checks = [];
  if (i.disk_total > 0) {
    const free = i.disk_free / i.disk_total;
    const text = `${formatSize(i.disk_free)} free of ${formatSize(i.disk_total)} (${Math.round(free * 100)}%)`;
    checks.push([free < 0.05 || i.disk_free < 1e9 ? "bad" : free < 0.1 ? "warn" : "ok", `Disk: ${text}`]);
  } else {
    checks.push(["warn", "Disk: free space not known on this platform"]);
  }
  if (i.quota > 0) {
    const used = i.kept_bytes / i.quota;
    checks.push([used >= 1 ? "bad" : used >= 0.9 ? "warn" : "ok", `Quota: ${formatSize(i.kept_bytes)} of ${formatSize(i.quota)} kept`]);
  }
  if (i.shares_failing > 0) {
    checks.push(["bad", `${i.shares_failing} shared folder${i.shares_failing === 1 ? "" : "s"} can't be read`]);
  } else if (i.shares_indexing > 0) {
    checks.push(["warn", `${i.shares_indexing} shared folder${i.shares_indexing === 1 ? " is" : "s are"} still being scanned`]);
  } else if (i.shares > 0) {
    checks.push(["ok", `${i.shares} shared folder${i.shares === 1 ? "" : "s"}, all readable`]);
  }
  checks.push(i.connections > 0
    ? ["ok", `Connected to ${i.connections} device${i.connections === 1 ? "" : "s"}`]
    : ["warn", "Not connected to any device"]);
  if (!i.swarm_last_sync) {
    checks.push(["warn", "Swarm folder: never synced"]);
  } else {
    const age = Date.now() / 1000 - i.swarm_last_sync;
    checks.push([age > 600 ? "warn" : "ok", `Swarm folder synced ${timeAgo(i.swarm_last_sync * 1000)}`]);
  }
  if (i.swarm_backup) {
    checks.push(i.swarm_unreachable > 0
      ? ["warn", `Swarm backup: ${i.swarm_unreachable} file${i.swarm_unreachable === 1 ? "" : "s"} no device could serve`]
      : ["ok", `Swarm backup: ${i.swarm_backed_up} of ${i.swarm_files} files kept here`]);
  }
  if (!i.unmetered) checks.push(["warn", "On mobile data: backups wait for Wi-Fi"]);
  return checks;
}

async function openDeviceInfo(title, peer) {
  const token = ++deviceInfoToken;
  $("dt-name").textContent = title;
  $("dt-meta").textContent = "Asking the device…";
  const body = $("dt-body");
  body.replaceChildren();
  $("details").hidden = false;
  let i;
  try {
    i = await invoke("device_info", peer ? { peer } : {});
  } catch (err) {
    if (token !== deviceInfoToken) return;
    const why = String(err);
    $("dt-meta").textContent = why.includes("NeedsUpdate")
      ? "This device runs an older NomadFS that can't answer: update it."
      : why.includes("NotTrusted")
        ? "This device doesn't trust this one yet: pair them."
        : `Couldn't ask the device: ${err}`;
    return;
  }
  if (token !== deviceInfoToken) return;
  const el = (tag, cls, text) => {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text !== undefined) n.textContent = text;
    return n;
  };
  const section = (title, ...nodes) => body.append(el("h3", "", title), ...nodes);
  const checks = deviceHealth(i);
  const worst = checks.some(([st]) => st === "bad") ? "bad" : checks.some(([st]) => st === "warn") ? "warn" : "ok";
  $("dt-meta").textContent = `NomadFS ${i.version} · ${i.platform} · up ${formatUptime(i.uptime_s)}`;

  // Health
  const summary = el("div", `dh-summary ${worst}`, worst === "ok" ? "Healthy" : worst === "warn" ? "Needs a look" : "Needs attention");
  const list = el("ul", "dh-checks");
  for (const [st, text] of checks) {
    const li = el("li", st);
    li.append(el("i"), el("span", "", text));
    list.append(li);
  }
  section("Health", summary, list);

  // Storage
  const stats = el("div", "dt-stats");
  const stat = (value, label) => {
    const s = el("div", "dt-stat");
    s.append(el("b", "", value), el("span", "", label));
    stats.append(s);
  };
  const storageNodes = [];
  if (i.disk_total > 0) {
    const used = i.disk_total - i.disk_free;
    const bar = el("div", "dh-bar");
    const fill = el("div", "dh-fill");
    fill.style.width = `${Math.min(100, (used / i.disk_total) * 100)}%`;
    const mine = el("div", "dh-mine");
    mine.style.width = `${Math.min(100, ((i.kept_bytes + i.cache_bytes) / i.disk_total) * 100)}%`;
    bar.append(fill, mine);
    storageNodes.push(bar, el("p", "", `${formatSize(used)} used of ${formatSize(i.disk_total)}, ${formatSize(i.disk_free)} free; the highlighted part is NomadFS's.`));
    stat(formatSize(i.disk_free), "free on the disk");
  }
  stat(formatSize(i.kept_bytes), `kept (${i.kept_blocks} blocks)`);
  stat(i.cache_limit ? `${formatSize(i.cache_bytes)} / ${formatSize(i.cache_limit)}` : formatSize(i.cache_bytes), "read cache");
  if (i.quota) stat(formatSize(i.quota), "quota for others' blocks");
  section("Storage", ...storageNodes, stats,
    el("p", "", "Kept blocks are what the device wrote, backs up or holds as copies; the read cache holds what it opened from others and makes room by itself."));

  // Swarm and network
  const net = el("div", "dt-stats");
  const netStat = (value, label) => {
    const s = el("div", "dt-stat");
    s.append(el("b", "", value), el("span", "", label));
    net.append(s);
  };
  netStat(String(i.connections), "open connections");
  netStat(String(i.peers), "devices known");
  netStat(String(i.trusted), "devices trusted");
  netStat(String(i.shares), "shared folders");
  netStat(String(i.swarm_files), "swarm folder files");
  netStat(i.swarm_backup ? "On" : "Off", "swarm backup");
  netStat(i.unmetered ? "Yes" : "No", "on Wi-Fi or wired");
  netStat(formatSize(i.bytes_sent), "sent");
  netStat(formatSize(i.bytes_received), "received");
  section("Swarm and network", net);

  const again = el("button", "btn outlined", "Ask again");
  again.type = "button";
  again.addEventListener("click", () => openDeviceInfo(title, peer));
  body.append(again);
}

$("dt-close").addEventListener("click", () => { $("details").hidden = true; });
$("details").addEventListener("click", (e) => { if (e.target === $("details")) $("details").hidden = true; });
document.addEventListener("keydown", (e) => { if (e.key === "Escape" && !$("details").hidden) $("details").hidden = true; });
