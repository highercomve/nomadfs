// ---- Mount (desktop Linux) ----

import { $, snack } from "./core.js";
import { isRunning, ensureConfig, onNodeChange } from "./state.js";

const { invoke } = window.oriel;

let mountPath = "";
let mounted = false;

function renderMount(status) {
  mounted = status.mounted;
  if (status.mounted) mountPath = status.path;
  else if (!mountPath) mountPath = status.default_path;
  // Windows mounts on a drive letter; "*" takes the first free one.
  $("mount-path").textContent = mountPath === "*" ? "The first free drive letter" : mountPath;
  $("mount-change").hidden = window.oriel.platform?.os === "windows";
  $("mount-state").dataset.state = mounted ? "on" : "off";
  $("mount-label").textContent = mounted ? `Mounted at ${mountPath}` : "Not mounted";
  $("mount-toggle").textContent = mounted ? "Unmount" : "Mount";
  $("mount-open").hidden = !mounted;
  $("mount-change").disabled = mounted;
}

async function loadMount() {
  let status;
  try { status = await invoke("mount_status", null); } catch { return; }
  $("nav-mount").hidden = false;
  $("mount-section").hidden = !status.supported;
  const os = window.oriel.platform?.os;
  if (os === "windows") $("mount-hint").innerHTML = "Uses Windows's WebDAV client (the WebClient service). Also from a terminal: <code>nomadfs --mount Z:</code>";
  else if (os === "macos") $("mount-hint").innerHTML = "Mounted over WebDAV, which macOS reads natively. Also from a terminal: <code>nomadfs --mount ~/NomadFS</code>";
  await loadWebDav();
  renderMount(status);
}

// The tray can mount or unmount while the window is hidden.

/** Wiring attaches once, from app.js: visibility re-checks and the mount
 *  buttons. */
let ctx = null; // injected deps from the root

export function installMount({ setView, nodeState }) {
  ctx = { setView, nodeState };
  onNodeChange(loadMount);
  $("webdav-form").addEventListener("input", () => { webDavDirty = true; });
  $("webdav-form").addEventListener("submit", (event) => {
    event.preventDefault();
    return saveWebDav(false);
  });
  $("webdav-clear").addEventListener("click", () => saveWebDav(true));
  for (const action of ["start", "stop", "restart"]) {
    $(`webdav-${action}`).addEventListener("click", () => controlWebDav(action));
  }
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
        if (!isRunning()) throw new Error("Start the node first");
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
}


export { loadMount };

let webDavError = "";
let webDavBusy = false;
let webDavDirty = false;
let webDavStatus = null;

function renderWebDav() {
  const status = webDavStatus;
  $("webdav-error").textContent = webDavError ? `Error: ${webDavError}` : "";
  $("webdav-state").hidden = !!webDavError;
  $("webdav-error").hidden = !webDavError;
  $("webdav-form").querySelectorAll("button").forEach((b) => { b.disabled = webDavBusy; });
  if (!status) return;
  $("webdav-state").textContent = webDavError ? `Error: ${webDavError}` : status.running ? `Serving at ${status.address}` : "Stopped";
  $("webdav-login").textContent = status.password_set ? "Password set." : "No login: the address uses a random token.";
  $("webdav-other-users").disabled = webDavBusy || !status.password_set;
  $("webdav-other-users-hint").textContent = status.password_set
    ? "Other local users must supply the login on every request."
    : "Set and save a password first. Without a login, only programs running as your user can connect; this option has no effect.";
  $("webdav-address").textContent = status.address;
  $("webdav-clear").disabled = webDavBusy || !status.password_set;
  $("webdav-start").disabled = webDavBusy || status.running || !status.port || !isRunning();
  $("webdav-stop").disabled = webDavBusy || !status.running;
  $("webdav-restart").disabled = webDavBusy || !status.port || !isRunning();
}

function webDavFailure(err, port) {
  return String(err).includes("AddressInUse")
    ? `Port ${port} is already in use by another program. Choose another port.`
    : String(err);
}

async function loadWebDav(refreshFields = true) {
  try {
    const status = await invoke("webdav_info", { config_path: await ensureConfig() });
    // Do not overwrite an edit when node state or window visibility changes.
    if (refreshFields && !webDavDirty && !webDavBusy && !$("webdav-form").contains(document.activeElement)) {
      $("webdav-port").value = status.port || 8080;
      $("webdav-user").value = status.user;
      $("webdav-other-users").checked = status.allow_other_users;
    }
    webDavStatus = status;
    renderWebDav();
  } catch (err) {
    webDavError = `Couldn't read WebDAV settings: ${err}`;
    renderWebDav();
  }
}

async function saveWebDav(clear) {
  if (webDavBusy) return;
  const password = $("webdav-password");
  // Snapshot before awaiting the config path or any background refresh.
  const values = {
    port: Number($("webdav-port").value),
    user: $("webdav-user").value,
    password: password.value,
    clear_password: clear,
    allow_other_users: $("webdav-other-users").checked,
  };
  webDavBusy = true;
  webDavDirty = true;
  webDavError = "";
  renderWebDav();
  try {
    await invoke("webdav_set", { config_path: await ensureConfig(), ...values });
    webDavDirty = false;
    password.value = "";
    if (clear) $("webdav-user").value = "";
    snack("WebDAV settings saved");
  } catch (err) { webDavError = webDavFailure(err, values.port); }
  finally {
    webDavBusy = false;
    await loadWebDav(!webDavError);
  }
}

async function controlWebDav(action) {
  if (webDavBusy) return;
  webDavBusy = true;
  webDavError = "";
  renderWebDav();
  try {
    await invoke(`webdav_${action}`, { config_path: await ensureConfig() });
  } catch (err) { webDavError = webDavFailure(err, webDavStatus?.port); }
  finally {
    webDavBusy = false;
    await loadWebDav();
  }
}
