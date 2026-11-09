// Actions every file's row menu offers, shared by Browse and the Swarm folder:
// open in another app, download, and the copyable links.
import { snack, copyText, mimeFor } from "./core.js";
import { errText } from "./format.js";
import { openDetails } from "./about.js";

/** The menu items every file has: open elsewhere, download, details, and copyable links. */
export function fileMenu(source, e, details) {
  return [
    { icon: "open_in", label: "Open in another app", run: () => openInApp(source, e) },
    { icon: "download", label: "Download", run: () => source.download(e) },
    { icon: "info", label: "Details", run: () => openDetails(e.name, details) },
    { icon: "link", label: "Copy link on this device", run: () => copyLink(source, e) },
    { icon: "link", label: "Copy link on local network", run: () => copyLink(source, e, "lan") },
    { icon: "link", label: "Copy Tailscale link", run: () => copyLink(source, e, "tailscale") },
  ];
}

/** Streams it to the app the system picks for its type (VLC for a video). */
export async function openInApp(source, e) {
  try {
    const url = await source.mediaUrl(e, true);
    await window.oriel.openExternal(url, { type: mimeFor(e.name) });
  } catch (err) {
    snack(`Couldn't open it: ${errText(err)}`);
  }
}

export async function copyLink(source, e, network = "") {
  try {
    const url = await source.mediaUrl(e, true, network);
    const where = network === "lan" ? "on the local network" : network === "tailscale" ? "over Tailscale" : "on this device";
    copyText(url, `Link copied for ${where}`);
  } catch (err) {
    const unavailable = String(err).includes("NoLanAddress") ? "No local network address is available" :
      String(err).includes("NoTailscaleAddress") ? "No Tailscale address is available" : `No link: ${err}`;
    snack(unavailable);
  }
}

