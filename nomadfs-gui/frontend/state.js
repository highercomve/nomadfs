// The app-wide node state, shared by the screens: whether the node runs,
// the reachable devices, this copy's config path.

export function isRunning() {
  return running;
}
/** `session` (node_state's) moves on every node open and close: a restart
 *  the page missed still fires the listeners, though `running` stays true. */
export function setRunning(v, session = nodeSessionId) {
  const changed = v !== running || session !== nodeSessionId;
  running = v;
  nodeSessionId = session;
  if (changed) for (const cb of nodeListeners) cb();
}
let running = false;

/** The node session the page last saw (null before the first node_state). */
export function nodeSession() {
  return nodeSessionId;
}
let nodeSessionId = null;

// The app starts the node itself at boot: until that settles, a screen
// that needs it shows that it's loading, not that the node is stopped.
let starting = true;
export function isStarting() {
  return starting && !running;
}
export function setStarting(v) {
  const was = isStarting();
  starting = v;
  if (isStarting() !== was) for (const cb of nodeListeners) cb();
}
const nodeListeners = new Set();
/** `cb()` whenever the node starts, stops, restarts, or stops starting. */
export function onNodeChange(cb) {
  nodeListeners.add(cb);
  return () => nodeListeners.delete(cb);
}

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
