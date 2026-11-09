// ---- Devices: browse other devices' shares ----

import { $, snack, svg, ICONS, drawCrumbs, listLoading, listLoaded } from "./core.js";
import { formatSize, formatDate } from "./format.js";
import { fileType, iconFor } from "./file-types.js";
import { row } from "./overlays.js";
import { FileTable } from "./file-table.js";
import { syncBack, registerUp } from "./back.js";
import { isRunning, devices, setDevices, deviceTitle, deviceBadge } from "./state.js";
import { fileMenu } from "./file-actions.js";
import { startDownload, downloadFile } from "./downloads.js";
import { openPreview, closePreview } from "./preview.js";
import { openDetails, openDeviceInfo } from "./about.js";

const { invoke } = window.oriel;

// The current location: [] = device list; [{device}] = its shares;
// then one {name, cid} per folder below the share.
let path = [];

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

/** Reachable devices in the drawer, like a file manager's locations. */
function renderNavDevices() {
  const box = $("nav-devices");
  if (!box) return;
  box.replaceChildren();
  const current = path.length ? path[0].device.peer : null;
  for (const d of devices()) {
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
      ctx.setView("browse");
      showLocation();
    });
    box.appendChild(b);
  }
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

// Right after the node starts, peers are still being dialed: retry the
// empty device list a few times before settling on "none reachable".
let deviceRetries = 0;

async function showDevices() {
  path = [];
  renderCrumbs();
  const nav = ++browseNav;
  const list = $("remote-list");
  if (!isRunning()) {
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
  setDevices(found);
  browseShowing = "devices";
  busy(false);
  listLoaded(list);
  renderNavDevices();
  list.replaceChildren();
  if (!devices().length) {
    setEmpty("No devices reachable yet. Add one under Connect devices.");
    if (deviceRetries < 5) {
      deviceRetries++;
      setTimeout(() => { if (path.length === 0) showDevices(); }, 2000);
    }
    return;
  }
  deviceRetries = 0;
  setEmpty("");
  for (const d of devices()) {
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

// What the open location lists: { device, shares } (shares: a device's top
// level, whose entries are its shared folders).
let browse = null;

let browseTable = null; // built when the screen installs (the constructor wires the DOM)

// The table itself and the two screen buttons attach once, in installBrowse.
function buildBrowseTable() {
  browseTable = new FileTable({
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
}

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
  const fetchIt = () => downloadFile(device, e);
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

/** Where a preview reads from: a device's share... */
function deviceSource(device) {
  const source = {
    read: (e, offset, len) => invoke("read_range", { peer: device.peer, cid: e.cid, offset, len }),
    mediaUrl: (e, external = false, network = "") => invoke("media_url", { kind: "device", id: device.peer, cid: e.cid, size: e.size, name: e.name, external, network }),
    download: (e) => downloadFile(device, e),
    menu: (e) => fileMenu(source, e, { cid: e.cid, peer: device.peer }),
  };
  return source;
}
/** ...or the swarm folder (the device that added it, then anyone). */

/** Reloads the open folder as it is now: a share's root changes with every
 *  edit (and while a first scan fills it in), so the path is walked again
 *  by name from the device's current share list. */
async function refreshLocation() {
  const snapshot = [...path];
  const nav = ++browseNav;
  const peer = snapshot[0].device.peer;
  busy(true);
  try {
    const fresh = (await invoke("remote_devices", null)).find((d) => d.peer === peer);
    if (nav !== browseNav) return;
    if (!fresh) throw new Error("the device isn't reachable");
    const walked = [{ ...snapshot[0], device: fresh }];
    let entries = fresh.shares.map((sh) => ({ ...sh, dir: true }));
    for (const step of snapshot.slice(1)) {
      const e = entries.find((x) => x.dir && x.name === step.name);
      if (!e) break; // gone: stop at the deepest folder still there
      walked.push({ name: e.name, cid: e.cid, pending: !e.mtime && !e.size });
      if (walked.length < snapshot.length) {
        entries = await invoke("browse", { peer, cid: e.cid });
        if (nav !== browseNav) return;
      }
    }
    if (path[0]?.device.peer !== peer) return;
    path = walked;
  } catch (err) {
    if (nav !== browseNav) return;
    snack(`Couldn't refresh: ${err.message || err}`);
  } finally {
    if (nav === browseNav) busy(false);
  }
  if (nav === browseNav && path[0]?.device.peer === peer) showLocation();
}

const deviceKey = (list) => list.map((d) => d.peer).sort().join(",");

/** Runs `showDevices` or a drawer refresh when the reachable set changes. */
function refreshDevicesNow(list) {
  if (deviceKey(list) === deviceKey(devices())) return;
  if (document.body.dataset.view === "browse" && path.length === 0) showDevices();
  else { setDevices(list); renderNavDevices(); }
}

/** Wiring attaches once, from app.js: the device watcher, the two Browse
 *  buttons, and Back's last provider. */
let ctx = null; // injected: instal deps from the root

export function installBrowse({ setView, nodeState }) {
  ctx = { setView, nodeState };
  buildBrowseTable();
  $("device-about").addEventListener("click", () => { if (path.length) openDeviceInfo(path[0].name, path[0].device.peer); });
  $("remote-refresh").addEventListener("click", () => (path.length ? refreshLocation() : showDevices()));
  registerUp({
    depth: () => (((document.body.dataset.view || "browse") !== "browse") ? 1 + path.length : path.length),
    up: () => {
      const view = document.body.dataset.view || "browse";
      if (view !== "browse") { ctx.setView("browse"); if (path.length) showLocation(); }
      else if (path.length) { path.pop(); path.length ? showLocation() : showDevices(); }
    },
  });
  // Devices come and go (a phone wakes, a laptop rejoins): keep the drawer's
  // list current, and the Browse list when it shows the devices.
  setInterval(async () => {
    if (!isRunning() || document.hidden) return;
    let now;
    try { now = await invoke("remote_devices", null); } catch { return; }
    refreshDevicesNow(now);
  }, 10000);
}

export { renderNavDevices, showDevices, showLocation, refreshDevicesNow };

/** For app.js: is Browse inside a folder (nav items re-show the devices). */
export const browsePath = () => path;

/** For app.js: the node just started; retry the empty device list again. */
export function resetDeviceRetries() { deviceRetries = 0; }

