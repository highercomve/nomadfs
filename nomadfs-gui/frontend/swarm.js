// ---- Swarm folder: one folder all devices read and write ----

import { $, snack, svg, ICONS, drawCrumbs, listLoading, listLoaded } from "./core.js";
import { formatSize, formatDate, timeAgo } from "./format.js";
import { fileType, iconFor } from "./file-types.js";
import { row, askDialog } from "./overlays.js";
import { FileTable } from "./file-table.js";
import { syncBack, registerUp } from "./back.js";
import { isRunning } from "./state.js";
import { fileMenu } from "./file-actions.js";
import { startDownload } from "./downloads.js";
import { openPreview } from "./preview.js";
import { openDetails } from "./about.js";
import { Selection, selectionBar, rangeBetween, deleteCopy, deleteMany, deletedText } from "./selection.js";

const { invoke } = window.oriel;

const swarmSource = {
  read: (e, offset, len) => invoke("swarm_read_range", { cid: e.cid, author_id: e.author_id, offset, len }),
  mediaUrl: (e, external = false, network = "") => invoke("media_url", { kind: "swarm", id: e.author_id, cid: e.cid, size: e.size, name: e.name, external, network }),
  download: (e) => swarmDownload(e),
  menu: (it) => swarmMenu(it),
};

let swarmDir = ""; // "" = top; "a/b" below

function swarmCrumbs() {
  const parts = swarmDir ? swarmDir.split("/") : [];
  drawCrumbs($("swarm-crumbs"), [{ label: "Swarm", dir: "" }, ...parts.map((p, i) => ({ label: p, dir: parts.slice(0, i + 1).join("/") }))]
    .map((c) => ({ label: c.label, go: () => { swarmDir = c.dir; loadSwarm(); } })));
  syncBack();
}

function swarmStatusText(st) {
  if (!isRunning()) return "Node stopped";
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
  if (!isRunning()) {
    swarmSel.leave();
    list.replaceChildren();
    $("swarm-empty").hidden = false;
    $("swarm-empty").textContent = "Start the node to see the swarm folder.";
    $("swarm-status").textContent = "Node stopped";
    swarmTable.dir = null;
    return;
  }
  // Another folder: its rows aren't these. A refresh keeps them meanwhile.
  if (swarmTable.dir !== swarmDir) {
    swarmSel.leave(); // a selection is of one folder's items
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
  // Same folder (a refresh): keep what is typed in the search.
  if (swarmTable.dir === swarmDir) {
    for (const e of res.items) e._type = e.dir ? "Folder" : fileType(e.name, false);
    swarmTable.entries = res.items;
    // What another device deleted or renamed meanwhile is no longer selected.
    swarmSel.retain(new Set(res.items.map((e) => e.path)));
    swarmTable.render();
    swarmSelBar();
  } else {
    swarmTable.dir = swarmDir;
    swarmTable.show(res.items);
  }
}

let swarmTable = null; // built when the screen installs (the constructor wires the DOM)

function buildSwarmTable() {
  swarmTable = new FileTable({
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
}

function swarmRow(it, files) {
  const by = it.author || "";
  const actions = [
    { icon: "edit", label: `Rename ${it.name}`, run: () => swarmRenamePrompt(it) },
    { icon: "trash", label: `Delete ${it.name}`, run: () => swarmDeleteConfirm(it) },
  ];
  if (!it.dir) actions.unshift({ icon: "download", label: "Download", run: (btn) => swarmDownload(it, btn) });
  if (!it.dir && it.cid) actions.unshift({ icon: "info", label: `Details of ${it.name}`, run: () => openDetails(it.name, { cid: it.cid, author_id: it.author_id }) });
  const li = row({
    // While selecting, a tap picks the row: no menu, nothing opens.
    menu: swarmSel.active ? null : swarmMenu(it, true),
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
    onClick: (e) => {
      // Ctrl/Cmd-click picks one, Shift-click everything up to it.
      if (swarmSel.active || e.ctrlKey || e.metaKey || e.shiftKey) swarmSelectClick(it, e);
      else if (it.dir) { swarmDir = it.path; loadSwarm(); }
      else openPreview(swarmSource, files, files.indexOf(it));
    },
    actions,
  });
  li.dataset.path = it.path;
  if (swarmSel.active) {
    const check = document.createElement("button");
    check.type = "button";
    check.className = "row-check";
    check.setAttribute("role", "checkbox");
    check.setAttribute("aria-label", `Select ${it.name}`);
    check.appendChild(svg(ICONS.check));
    check.addEventListener("click", (e) => { e.stopPropagation(); swarmSelectClick(it, e); });
    li.prepend(check);
    swarmRowMark(li);
  }
  return li;
}

// ---- Selecting several items, to delete them at once ----

const swarmSel = new Selection(() => swarmSelChanged());
let swarmSelDrawn = false; // the rows have their checkboxes
let swarmSelBusy = ""; // what the bar says while the delete runs
let swarmBar = null; // built when the screen installs

function swarmRowMark(li) {
  const on = swarmSel.has(li.dataset.path);
  li.classList.toggle("selected", on);
  li.querySelector(".row-check")?.setAttribute("aria-checked", on ? "true" : "false");
}

function swarmSelBar() {
  if (!swarmBar) return;
  swarmBar.el.hidden = !swarmSel.active;
  swarmBar.update({
    count: swarmSel.size,
    all: swarmSel.hasAll(swarmTable.shown.map((e) => e.path)),
    busy: swarmSelBusy,
  });
}

function swarmSelChanged() {
  const on = swarmSel.active;
  if (on !== swarmSelDrawn) {
    // Into or out of select mode: the rows gain or lose their checkboxes.
    swarmSelDrawn = on;
    $("swarm-section").classList.toggle("selecting", on);
    $("swarm-select").setAttribute("aria-pressed", on ? "true" : "false");
    swarmTable.render();
  } else {
    for (const li of $("swarm-list").children) if (li.dataset.path !== undefined) swarmRowMark(li);
  }
  swarmSelBar();
  syncBack(); // Back leaves select mode first
}

function swarmSelectClick(it, e) {
  if (swarmSelBusy) return;
  if (e.shiftKey) {
    getSelection()?.removeAllRanges(); // Shift-click also selects the page's text
    const shown = swarmTable.shown;
    const paths = new Set(rangeBetween(shown.map((x) => x.path), swarmSel.anchor, it.path));
    swarmSel.setMany(shown.filter((x) => paths.has(x.path)).map((x) => [x.path, x]));
    swarmSel.anchor = it.path;
    return;
  }
  swarmSel.toggle(it.path, it);
}

/** "All": everything the list shows (what a search or a type chip left). */
function swarmSelectAll() {
  const entries = swarmTable.shown.map((x) => [x.path, x]);
  swarmSel.setMany(entries, !swarmSel.hasAll(entries.map(([path]) => path)));
}

async function swarmDeleteSelected() {
  if (swarmSelBusy || !swarmSel.size) return;
  const items = swarmSel.values();
  const ok = await askDialog({
    ...deleteCopy(items.length, { folders: items.filter((it) => it.dir).length }),
    confirm: "Delete",
    danger: true,
  });
  if (!ok || !swarmSel.size) return;
  const paths = swarmSel.keys();
  swarmSelBusy = "Deleting…";
  swarmSelBar();
  const res = await deleteMany(invoke, paths, {
    onProgress: (sent, total) => {
      if (!sent) return;
      swarmSelBusy = `Deleting ${sent} of ${total}…`;
      swarmSelBar();
    },
  });
  swarmSelBusy = "";
  snack(deletedText(res));
  swarmSel.leave();
  loadSwarm();
}

/** A swarm item's menu: a file's actions, then the edits (a folder has only
 *  those). In the list (`select`) it also starts a selection with the item. */
function swarmMenu(it, select = false) {
  const menu = swarmItemMenu(it);
  return select ? [{ icon: "check", label: "Select", run: () => swarmSel.toggle(it.path, it) }, "-", ...menu] : menu;
}

function swarmItemMenu(it) {
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

/** For notes.js: point the swarm view at a subfolder path. */
export function openSwarmAt(dir) { swarmDir = dir; }

/** Wiring attaches once, from app.js: the buttons, the open-view poll and
 *  Back's swarm provider (registered before Browse's). */
export function installSwarm() {
  buildSwarmTable();
  swarmBar = selectionBar({
    label: "Selected items",
    onAll: swarmSelectAll,
    onDelete: swarmDeleteSelected,
    onCancel: () => swarmSel.leave(),
  });
  $("swarm-section").appendChild(swarmBar.el);
  $("swarm-select").addEventListener("click", () => {
    if (swarmSel.active) swarmSel.leave();
    else swarmSel.enter();
  });
  document.addEventListener("keydown", (e) => {
    if (e.key !== "Escape" || !swarmSel.active || swarmSelBusy) return;
    if (document.body.dataset.view !== "swarm" || !$("ask").hidden) return;
    swarmSel.leave();
  });
  // Back leaves select mode before it goes up a folder.
  registerUp({
    depth: () => ((document.body.dataset.view || "browse") === "swarm" && swarmSel.active ? 1 : 0),
    up: () => swarmSel.leave(),
  });
  registerUp({
    depth: () => ((document.body.dataset.view || "browse") === "swarm" && swarmDir ? swarmDir.split("/").length : 0),
    up: () => { swarmDir = swarmDir.split("/").slice(0, -1).join("/"); loadSwarm(); },
  });
  $("swarm-add").addEventListener("click", async () => {
    if (!isRunning()) return snack("Start the node first");
    try {
      const name = await invoke("swarm_add_file", { dir: swarmDir });
      if (name) snack(`Added ${name}: every device can see it now`);
    } catch (err) {
      snack(`Add failed: ${err}`);
    }
    loadSwarm();
  });

  $("swarm-mkdir").addEventListener("click", async () => {
    if (!isRunning()) return snack("Start the node first");
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
  setInterval(() => { if (document.body.dataset.view === "swarm" && !document.hidden && isRunning()) loadSwarm(); }, 10000);
}

export { loadSwarm };
