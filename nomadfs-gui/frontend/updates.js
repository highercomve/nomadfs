// ---- Updates: signed releases from GitHub (src/updates.zig) ----

import { $, snack } from "./core.js";
import { formatSize } from "./format.js";
import { openLink } from "./about.js";

const { invoke } = window.oriel;

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
    if (upd.info.mode === "store") {
      renderUpdate(`NomadFS ${upd.info.current}. Google Play keeps it up to date.`);
      return;
    }
    const r = await invoke("updater_check", null);
    upd.version = r.available ? r.version : null;
    renderUpdate(upd.version
      ? `NomadFS ${upd.version} is available (you have ${upd.info.current}).`
      : `NomadFS ${upd.info.current} is the latest version.`);
    if (upd.version && quiet) snack(`NomadFS ${upd.version} is available. Tap to update.`, 10000, () => ctx.setView("about"));
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

/** Wiring attaches once, from app.js: the check button and the automatic
 *  checks (shortly after start, then every few hours). */
let ctx = null; // injected: install deps from the root

export function installUpdates({ setView, nodeState }) {
  ctx = { setView, nodeState };
  $("update-check").addEventListener("click", () => checkUpdate(false));
  $("update-action").addEventListener("click", runUpdate);
  $("update-auto").checked = updateAutoOn();
  $("update-auto").addEventListener("change", (e) => {
    try { localStorage.setItem("updateAuto", e.target.checked ? "1" : "0"); } catch {}
  });
  // Shortly after start, then every few hours while the app runs.
  setTimeout(() => updateAutoOn() && checkUpdate(true), 15000);
  setInterval(() => updateAutoOn() && checkUpdate(true), UPDATE_EVERY_MS);
}
