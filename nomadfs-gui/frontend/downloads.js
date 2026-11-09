// ---- Downloads: what was saved, where, and how far a copy has got ----

import { $, snack, copyText, mimeFor } from "./core.js";
import { formatSize, formatDate, errText } from "./format.js";
import { iconFor } from "./file-types.js";
import { row, askDialog } from "./overlays.js";
import { openPreview, closePreview } from "./preview.js";
import { isRunning } from "./state.js";

const { invoke } = window.oriel;

function goToDownloads() {
  closePreview();
  ctx.setView("downloads");
}

/** Starts a download (it runs in the background; Downloads follows it). */
async function startDownload(command, args) {
  const stillRunning = [...downloads.values()].find((d) => d.state === "running" && d.source_id === (args.peer ?? args.author_id) && d.name === args.name);
  if (stillRunning) return snack(`${args.name} is already downloading`, 4000, goToDownloads);
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
    snack(`Couldn't load downloads: ${errText(err)}`);
  }
  renderDownloads();
}

/** The download progress events and the two Downloads buttons attach once,
 *  from app.js. */
let ctx = null; // injected: installdo deps from the root

export function installDownloads({ setView, nodeState }) {
  ctx = { setView, nodeState };
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
  $("downloads-folder").addEventListener("click", showDownloadsFolder);
  $("downloads-clear").addEventListener("click", async () => {
    await invoke("downloads_clear", null).catch((err) => snack(`${err}`));
    loadDownloads();
  });
}

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
  const stillRunning = d.state === "running";
  const ok = playable(d);
  const actions = stillRunning
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
  const stillRunning = d.state === "running";
  const meta = li.querySelector(".meta");
  if (d.state === "failed") meta.classList.add("dl-failed");
  if (isRunning()) {
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

export { loadDownloads, startDownload, downloadFile };
