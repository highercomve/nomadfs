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
  $("webdav-form").addEventListener("submit", (event) => {
    event.preventDefault();
    saveWebDav(false);
  });
  $("webdav-clear").addEventListener("click", () => saveWebDav(true));
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

async function loadWebDav() {
  try {
    const status = await invoke("webdav_info", { config_path: await ensureConfig() });
    // Do not overwrite an edit when node state or window visibility changes.
    if (!$("webdav-form").contains(document.activeElement)) {
      $("webdav-enabled").checked = status.port > 0;
      $("webdav-port").value = status.port || 8080;
      $("webdav-user").value = status.user;
    }
    $("webdav-state").textContent = `${status.running ? "Serving" : status.port ? "Starts with the node" : "Off"}. ${status.password_set ? "Password set." : "No login: the address uses a random token."}`;
    $("webdav-address").textContent = status.address;
    $("webdav-clear").disabled = !status.password_set;
  } catch (err) { snack(`Couldn't read WebDAV settings: ${err}`); }
}

async function saveWebDav(clear) {
  const form = $("webdav-form");
  const password = $("webdav-password");
  const buttons = form.querySelectorAll("button");
  buttons.forEach((b) => { b.disabled = true; });
  try {
    await invoke("webdav_set", {
      config_path: await ensureConfig(),
      port: $("webdav-enabled").checked ? Number($("webdav-port").value) : 0,
      user: $("webdav-user").value,
      password: password.value,
      clear_password: clear,
    });
    password.value = "";
    if (clear) $("webdav-user").value = "";
    snack("WebDAV settings saved");
  } catch (err) { snack(`Couldn't save WebDAV settings: ${err}`); }
  finally {
    password.value = "";
    buttons.forEach((b) => { b.disabled = false; });
    await loadWebDav();
  }
}
