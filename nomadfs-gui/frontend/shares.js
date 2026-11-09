// ---- Shared folders (settings), swarm backup and Android storage ----

import { $, snack, svg, ICONS, listLoading, listLoaded } from "./core.js";
import { formatSize } from "./format.js";
import { row } from "./overlays.js";
import { isRunning, ensureConfig } from "./state.js";

const { invoke } = window.oriel;
const extensions = window.oriel.extensions;

let storageExt = false; // Android: all-files access extension present

// ---- Shared folders ----

let sharesNav = 0;

async function loadShares() {
  const nav = ++sharesNav;
  const list = $("shares-list");
  if (!isRunning()) {
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
  if (!isRunning()) {
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

/** Wiring attaches once, from app.js: the share form, storage presets,
 *  backup panels and the settings-page timer. */
export function installShares() {
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
}

export { loadShares, loadBackup, storageSetup };
