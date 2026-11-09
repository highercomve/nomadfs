// ---- About: build details, read cache, file details, device info ----

import { $, snack } from "./core.js";
import { formatSize, formatUptime, errText, timeAgo } from "./format.js";
import { ensureConfig } from "./state.js";

const { invoke } = window.oriel;

// ---- About ----

let aboutText = "";

export function openLink(url) {
  window.oriel.openExternal(url).catch(() => window.open(url, "_blank"));
}

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

let detailsGeneration = 0;

async function openDetails(name, src) {
  const gen = ++detailsGeneration;
  $("dt-name").textContent = name;
  $("dt-meta").textContent = "Reading the file's structure…";
  const body = $("dt-body");
  body.replaceChildren();
  $("details").hidden = false;
  let d;
  try {
    d = await invoke("file_details", src);
  } catch (err) {
    if (gen !== detailsGeneration) return;
    $("dt-meta").textContent = `Couldn't read the details: ${errText(err)}`;
    return;
  }
  if (gen !== detailsGeneration) return;
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
  requestAnimationFrame(() => { if (gen === detailsGeneration) drawChunkMap(canvas, d); });

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
  const gen = ++detailsGeneration;
  $("dt-name").textContent = title;
  $("dt-meta").textContent = "Asking the device…";
  const body = $("dt-body");
  body.replaceChildren();
  $("details").hidden = false;
  let i;
  try {
    i = await invoke("device_info", peer ? { peer } : {});
  } catch (err) {
    if (gen !== detailsGeneration) return;
    const why = String(err);
    $("dt-meta").textContent = why.includes("NeedsUpdate")
      ? "This device runs an older NomadFS that can't answer: update it."
      : why.includes("NotTrusted")
        ? "This device doesn't trust this one yet: pair them."
        : `Couldn't ask the device: ${err}`;
    return;
  }
  if (gen !== detailsGeneration) return;
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

/** Wiring attaches once, from app.js: the About/cache/feedback controls and
 *  the shared details dialog; updates.js installs its own timers. */
let ctx = null; // injected: insta deps from the root

export function installAbout({ setView, nodeState }) {
  ctx = { setView, nodeState };
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

  // File details' close wiring (the openers live above; the shared surface
  // invalidates both request kinds on close).
  $("dt-close").addEventListener("click", () => { detailsGeneration++; $("details").hidden = true; });
  $("details").addEventListener("click", (e) => { if (e.target === $("details")) { detailsGeneration++; $("details").hidden = true; } });
  document.addEventListener("keydown", (e) => { if (e.key === "Escape" && !$("details").hidden) { detailsGeneration++; $("details").hidden = true; } });
}

export { loadAbout, openDetails, openDeviceInfo };

