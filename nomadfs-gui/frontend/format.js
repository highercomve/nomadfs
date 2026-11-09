// Formatting and error wording: pure helpers, importable from anywhere.

export function formatSize(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  const units = ["KB", "MB", "GB", "TB"];
  let v = bytes / 1024;
  let i = 0;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
  return `${v < 10 ? v.toFixed(1) : Math.round(v)} ${units[i]}`;
}

/** A read error as a sentence: the node reports Zig error names. */
export const READ_ERRORS = {
  HoldersUnreachable: "the devices that keep it can't be reached right now. Try again on Wi-Fi or in a minute.",
  AllAddressesFailed: "the device that has it can't be reached right now.",
  PeerUnreachable: "the device that has it can't be reached right now.",
  NoHolders: "no device is known to keep it yet.",
  NoHolderAskable: "the devices that keep it said no a moment ago and can't be asked again yet. Try again in a minute.",
  BlockNotFound: "none of the devices asked has it.",
  NotRunning: "NomadFS isn't running.",
};
export function errText(err) {
  const name = String(err).replace(/^Error:\s*/, "");
  return READ_ERRORS[name] || name;
}

export function timeAgo(ms) {
  const s = Math.max(1, Math.round((Date.now() - ms) / 1000));
  if (s < 60) return "just now";
  const m = Math.round(s / 60);
  if (m < 60) return `${m} min ago`;
  const h = Math.round(m / 60);
  if (h < 24) return `${h} h ago`;
  return new Date(ms).toLocaleDateString(undefined, { month: "short", day: "numeric" });
}

export function formatDate(seconds) {
  if (!seconds) return "";
  return new Date(seconds * 1000).toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });
}

export function formatUptime(s) {
  if (s < 60) return `${s} s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m} min`;
  const h = Math.floor(m / 60);
  if (h < 48) return `${h} h ${m % 60} min`;
  return `${Math.floor(h / 24)} days ${h % 24} h`;
}
