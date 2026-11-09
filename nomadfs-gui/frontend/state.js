// The app-wide node state, shared by the screens: whether the node runs,
// the reachable devices, this copy's config path.

export function isRunning() {
  return running;
}
export function setRunning(v) {
  running = v;
}
let running = false;

export function devices() {
  return deviceList;
}
export function setDevices(list) {
  deviceList = list;
}
let deviceList = [];

let configPath = null;

/** Reads or creates the config lazily; every settings call goes through it. */
export async function ensureConfig() {
  if (!configPath) configPath = (await window.oriel.invoke("ensure_config", null)).path;
  return configPath;
}

/** The mount's folder names: a paired device's label, or an unpaired device's claimed nickname with a
 *  fingerprint suffix, so an unpaired device never shows a paired device's name. */
export const deviceTitle = (d) => d.mount_name || (d.trusted === true ? d.label : `Device ${d.fingerprint ? d.fingerprint.slice(0, 9) : (d.peer ? d.peer.slice(0, 8) : "")}`);
export const deviceBadge = (d) => (d.trusted === true) ? "Paired" : "Not paired";
