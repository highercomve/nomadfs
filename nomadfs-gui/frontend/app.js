// `window.oriel` is injected by Oriel: `invoke()` talks typed Zig.
import { initNotes } from "./notes.js";
import { formatSize } from "./format.js";
import { $, snack, copyText, svg, ICONS } from "./core.js";
import { installTableShortcuts } from "./file-table.js";
import { syncBack, registerUp, installBack } from "./back.js";
import { showMenu, installOverlays } from "./overlays.js";
import { installPreview } from "./preview.js";
import { loadSwarm, openSwarmAt, installSwarm } from "./swarm.js";
import { loadDownloads, installDownloads } from "./downloads.js";
import { loadJoinInfo, installConnect } from "./connect.js";
import { loadMount, installMount } from "./mount.js";
import { loadShares, loadBackup, storageSetup, installShares } from "./shares.js";
import { installSettings } from "./settings.js";
import { loadAbout, openDetails, installAbout } from "./about.js";
import { installUpdates } from "./updates.js";
import { renderNavDevices, showDevices, installBrowse, browsePath, resetDeviceRetries } from "./browse.js";
import { isRunning, setRunning, ensureConfig } from "./state.js";
const { invoke } = window.oriel;

let notesApi = null; // the Notes screen (notes.js), set once the page is wired

function setChip(state, label) {
  $("node-chip").dataset.state = state;
  $("node-chip-label").textContent = label;
}


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

export function setView(view) {
  document.body.dataset.view = view;
  for (const item of document.querySelectorAll(".nav-item[data-view], .bar-item[data-view]")) {
    item.classList.toggle("active", item.dataset.view === view);
  }
  $("bar-more").classList.toggle("active", view === "notes" || view === "settings" || view === "about");
  window.scrollTo(0, 0);
  try { localStorage.setItem("view", view); } catch {}
  if (view === "settings") { $("devices-refresh").click(); loadBackup(); }
  if (view === "swarm") { loadSwarm(); }
  if (view === "downloads") loadDownloads();
  if (view === "notes") notesApi?.show();
  else notesApi?.hide();
  if (view === "about") loadAbout();
  renderNavDevices();
  syncBack();
}

for (const item of document.querySelectorAll(".nav-item[data-view], .bar-item[data-view]")) {
  item.addEventListener("click", () => {
    setView(item.dataset.view);
    if (item.dataset.view === "browse" && browsePath().length) showDevices();
  });
}

// "/" or Ctrl+F searches the open folder's table (one install, at boot wiring).
installTableShortcuts(() => document.body.dataset.view);

// Overlays attach their document-level wiring once, before any screen shows.
installOverlays();
installPreview();
// Back goes: the menu, the preview, the More sheet, then the open notes
// editor. The swarm and browse providers register inside their installs.
registerUp({
  depth: () => ($("more-sheet").hidden ? 0 : 1),
  up: closeMore,
});
// notesApi is wired below; the provider reads it lazily.
registerUp({
  depth: () => (notesApi?.editing() ? 1 : 0),
  up: () => notesApi.closeEditor(),
});
installAbout({ setView, nodeState });
installUpdates({ setView, nodeState });
installSettings({ setView, nodeState });
installShares({ setView, nodeState });
installMount({ setView, nodeState });
installConnect({ setView, nodeState });
installSwarm({ setView, nodeState });
installBrowse({ setView, nodeState });
installDownloads({ setView, nodeState });

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

export async function nodeState() {
  try {
    const state = await invoke("node_state", null);
    const started = state.running && !isRunning();
    setRunning(state.running);
    // The swarm's notes (the first listing also renames this device's old ones).
    if (started) notesApi?.refresh();
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
  if (isRunning()) {
    loadShares();
    resetDeviceRetries();
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

// ---- Notes: Markdown files in the swarm folder (notes.js) ----

notesApi = initNotes({
  invoke,
  snack,
  icons: ICONS,
  svg,
  showMenu,
  copyText,
  syncBack,
  isRunning: () => isRunning(),
  startNode,
  deviceName: () => $("device-name").textContent.trim(),
  openDetails,
  openInFiles: (dir) => { openSwarmAt(dir); setView("swarm"); },
  showNotesView: () => setView("notes"),
});

installBack();

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
  if (!isRunning()) await startNode();
  else {
    loadShares();
    showDevices();
  }
}

boot();

