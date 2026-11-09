// ---- Settings (trusted devices, swarm-key rotation, Android background) ----

import { $, snack, listLoading, listLoaded } from "./core.js";
import { formatDate } from "./format.js";
import { row, askDialog } from "./overlays.js";
import { isRunning, ensureConfig, setDevices, deviceTitle } from "./state.js";
import { renderNavDevices } from "./browse.js";

const { invoke } = window.oriel;

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

/** Wiring attaches once, from app.js: the trusted list, key rotation and the
 *  Android background switch. */
let ctx = null; // injected: installs deps from the root

export function installSettings({ setView, nodeState }) {
  ctx = { setView, nodeState };
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

  loadBackground();  $("devices-refresh").addEventListener("click", async () => {
    const list = $("devices-list");
    if (!list.children.length) listLoading(list, 3);
    try {
      const trusted = await invoke("devices_list", { config_path: await ensureConfig() });
      // Reachable now: the same swarm key, online. Not the same as trusted.
      let reachable = [];
      if (isRunning()) {
        try {
          reachable = await invoke("remote_devices", null);
          setDevices(reachable);
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
    if (!isRunning()) return snack("Start the node first");
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
    await ctx.nodeState();
    $("devices-refresh").click();
  });
}
