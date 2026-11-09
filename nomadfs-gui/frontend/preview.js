// ---- Preview: the viewer for a file anywhere in the app ----

import { $, snack, svg, ICONS, decodeBase64 } from "./core.js";
import { formatSize, formatDate, errText } from "./format.js";
import { showMenu, setMenuCover, menuOpen } from "./overlays.js";
import { syncBack, registerUp } from "./back.js";

// ---- Preview ----

const KINDS = {
  image: { ext: ["jpg", "jpeg", "png", "gif", "webp", "bmp", "svg", "avif", "heic"], max: 64 << 20 },
  // Camcorder MPEG-TS (.mts/.m2ts), WMV, MXF and the rest play in the native
  // player (oriel.video), which takes what the system's media stack plays.
  video: { ext: ["mp4", "webm", "mov", "m4v", "mkv", "3gp", "mts", "m2ts", "avi", "wmv", "flv", "mpg", "mpeg", "mxf", "ogv", "vob"], max: 512 << 20 },
  audio: { ext: ["mp3", "m4a", "aac", "ogg", "opus", "wav", "flac"], max: 256 << 20 },
  pdf: { ext: ["pdf"], max: 64 << 20 },
  text: { ext: ["txt", "md", "json", "log", "csv", "xml", "yaml", "yml", "toml", "ini", "conf", "zig", "c", "h", "js", "ts", "py", "rs", "go", "sh", "html", "css"], max: 1 << 20 },
};
const MIME = {
  jpg: "image/jpeg", jpeg: "image/jpeg", png: "image/png", gif: "image/gif", webp: "image/webp", bmp: "image/bmp",
  svg: "image/svg+xml", avif: "image/avif", heic: "image/heic", mp4: "video/mp4", m4v: "video/mp4", webm: "video/webm",
  mov: "video/quicktime", mkv: "video/x-matroska", "3gp": "video/3gpp", mp3: "audio/mpeg", m4a: "audio/mp4",
  aac: "audio/aac", ogg: "audio/ogg", opus: "audio/ogg", wav: "audio/wav", flac: "audio/flac", pdf: "application/pdf",
};
const RANGE = 4 << 20;

function kindOf(name) {
  const ext = name.includes(".") ? name.split(".").pop().toLowerCase() : "";
  for (const [kind, k] of Object.entries(KINDS)) if (k.ext.includes(ext)) return { kind, ext };
  return { kind: null, ext };
}

let pv = null; // { source, files, index, token, url }

function previewMessage(icon, text, extra) {
  const box = document.createElement("div");
  box.className = "preview-msg";
  box.appendChild(svg(ICONS[icon]));
  const p = document.createElement("p");
  p.textContent = text;
  box.appendChild(p);
  if (extra) box.appendChild(extra);
  $("pv-body").replaceChildren(box);
  return box;
}

let previewGeneration = 0;

export function openPreview(source, files, index) {
  pv = { source, files, index, token: ++previewGeneration, url: null };
  $("preview").hidden = false;
  document.body.classList.add("pv-open");
  showPreview();
  syncBack();
}

/** Stops a streaming player so it stops fetching ranges. */
function stopMedia() {
  for (const m of $("pv-body").querySelectorAll("video, audio")) {
    m.pause();
    m.removeAttribute("src");
    m.load();
  }
}

export function closePreview() {
  if (!pv) return;
  stopMedia();
  stopNative();
  pv.token++;
  if (pv.url) URL.revokeObjectURL(pv.url);
  pv = null;
  $("pv-body").replaceChildren();
  $("preview").hidden = true;
  document.body.classList.remove("pv-open");
  syncBack();
}

// The native player: GPU rendering and every format the system plays,
// shown over the whole window. Null where the platform has none.
const nativeVideo = window.oriel.video?.available ? window.oriel.video : null;

/** A read error as the user should see it: a file whose blocks no device
 * has (a photo deleted on the phone before any backup copied it). */
function readFailure(err) {
  return /BlockNotFound/.test(String(err)) ? "This file's data isn't on any device you can reach" : errText(err);
}

async function streamPreview(entry, kind, token) {
  const session = pv;
  let url;
  try {
    // The native player gets an address other apps can open too, so its
    // "Open in another app" works (Android's in-app scheme is WebView-only).
    url = await session.source.mediaUrl(entry, kind === "video" && !!nativeVideo);
  } catch (err) {
    if (pv === session && pv && token === pv.token) previewMessage("file", `Preview failed: ${readFailure(err)}`);
    return;
  }
  if (pv !== session || !pv || token !== pv.token) return;
  if (kind === "video" && nativeVideo) return playNative(entry, url, token);
  inPagePlayer(kind, url, token);
}

// The native player, embedded in the viewer under its bar: { slot, observer }.
// Its fullscreen button covers the screen; Esc or Back come back here.
let pvNative = null;

/** Plays in the native player over the viewer's body (the bar stays the
 * page's: name, previous and next, the ⋮ menu). Falls back to the page's
 * player if the native one fails. */
async function playNative(entry, url, token) {
  const session = pv;
  stopNative();
  const slot = document.createElement("div");
  slot.className = "pv-native";
  $("pv-body").replaceChildren(slot);
  const rect = () => slot.getBoundingClientRect();
  const observer = new ResizeObserver(() => { if (pvNative?.slot === slot) nativeVideo.setRect(rect()).catch(() => {}); });
  pvNative = { slot, observer, entry, url, token };
  try {
    await nativeVideo.play({ url, title: entry.name, rect: rect() });
    if (pv !== session || !pv || token !== pv.token) return;
    observer.observe(slot);
    syncVideoCover();
  } catch (err) {
    if (pvNative?.slot === slot) pvNative = null;
    if (pv === session && pv && token === pv.token) inPagePlayer("video", url, token);
  }
}

/** Closes the embedded player, if one plays (the viewer moved on or closed). */
function stopNative() {
  if (!pvNative) return;
  pvNative.observer.disconnect();
  pvNative = null;
  nativeVideo?.close().catch(() => {});
}

/** Native views draw above the page: while a menu or dialog shows over the
 * viewer, the player hides (and keeps its place). */
function syncVideoCover() {
  if (!pvNative) return;
  const covered = menuOpen() || !$("details").hidden || !$("ask").hidden;
  if (covered === pvNative.covered) return;
  pvNative.covered = covered;
  nativeVideo.setVisible(!covered).catch(() => {});
}


function inPagePlayer(kind, url, token) {
  const session = pv;
  const el = document.createElement(kind);
  el.controls = true;
  el.autoplay = true;
  el.preload = "auto";
  el.src = url;
  el.addEventListener("error", () => {
    if (pv !== session || !pv || token !== pv.token) return;
    previewMessage(kind === "video" ? "video" : "file",
      `This ${kind === "video" ? "video" : "audio file"} can't play here (its format may not be supported). Download it to open it in another app.`);
  });
  $("pv-body").replaceChildren(el);
}

async function showPreview() {
  const session = pv;
  stopMedia();
  stopNative();
  const token = pv.token = ++previewGeneration;
  if (pv.url) { URL.revokeObjectURL(pv.url); pv.url = null; }
  const entry = pv.files[pv.index];
  $("pv-name").textContent = entry.name;
  $("pv-meta").textContent = `${formatSize(entry.size)} · ${formatDate(entry.mtime)} · ${pv.index + 1} of ${pv.files.length}`;
  $("pv-prev").disabled = pv.index === 0;
  $("pv-next").disabled = pv.index === pv.files.length - 1;

  const { kind, ext } = kindOf(entry.name);
  if (!kind) return previewMessage("file", "No preview for this kind of file.");
  // Video and audio stream: the player asks for byte ranges as it plays
  // and seeks, so it starts at once and size doesn't matter.
  if (kind === "video" || kind === "audio") return streamPreview(entry, kind, token);

  const limit = KINDS[kind].max;
  if (kind !== "text" && entry.size > limit) {
    return previewMessage(kind === "image" ? "image" : "file", `Too large to preview here (${formatSize(entry.size)}). Download it or open it from the mount.`);
  }

  const total = kind === "text" ? Math.min(entry.size, limit) : entry.size;
  const bar = document.createElement("div");
  bar.className = "progress determinate";
  const msg = previewMessage(kind === "image" ? "image" : "file", `Loading ${formatSize(total)}…`, bar);
  const bytes = kind !== "text" && entry.size > 0 ? new Uint8Array(entry.size) : null;
  const parts = [];
  let offset = 0;
  try {
    while (offset < total) {
      const len = Math.min(RANGE, total - offset);
      const b64 = await session.source.read(entry, offset, len);
      if (pv !== session || !pv || token !== pv.token) return; // closed or moved on
      const chunk = decodeBase64(b64);
      if (chunk.length === 0) break;
      if (bytes) bytes.set(chunk, offset);
      else parts.push(chunk);
      offset += chunk.length;
      bar.style.setProperty("--p", `${Math.round((offset / Math.max(total, 1)) * 100)}%`);
      msg.querySelector("p").textContent = `Loading ${formatSize(offset)} of ${formatSize(total)}…`;
    }
  } catch (err) {
    if (pv === session && pv && token === pv.token) previewMessage("file", `Preview failed: ${readFailure(err)}`);
    return;
  }

  const body = $("pv-body");
  if (kind === "text") {
    const pre = document.createElement("pre");
    pre.textContent = new TextDecoder().decode(concat(parts));
    if (entry.size > total) pre.textContent += `\n\n… (first ${formatSize(total)} of ${formatSize(entry.size)})`;
    body.replaceChildren(pre);
    return;
  }
  pv.url = URL.createObjectURL(new Blob(bytes ? [bytes.subarray(0, offset)] : parts, { type: MIME[ext] || "application/octet-stream" }));
  let el;
  if (kind === "image") { el = document.createElement("img"); el.alt = entry.name; }
  else { el = document.createElement("iframe"); el.sandbox = ""; el.title = entry.name; } // (pdf: video and audio stream instead)
  el.src = pv.url;
  el.addEventListener("error", () => {
    if (pv !== session || !pv || token !== pv.token) return;
    previewMessage("file",
      `This file uses a format this device can't play here. Download it, or open it from the mount with your usual player.`);
  });
  body.replaceChildren(el);
}

function concat(parts) {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) { out.set(p, at); at += p.length; }
  return out;
}

/** All the viewer's wiring attaches once, from app.js; the open preview is
 *  Back's next target (after the menu). */
export function installPreview() {
  registerUp({
    depth: () => (pv ? 1 : 0),
    up: closePreview,
  });
  setMenuCover(syncVideoCover);
  // Closed under the viewer (its Activity went away): offer to play it again.
  window.oriel.listen?.("video:closed", () => {
  if (!pvNative || !pv || pvNative.token !== pv.token) return;
  const { entry, url, token, observer } = pvNative;
  observer.disconnect();
  pvNative = null;
  const again = document.createElement("button");
  again.className = "btn filled";
  again.textContent = "Play";
  again.addEventListener("click", () => playNative(entry, url, token));
  previewMessage("video", "The video player closed.", again);
  });
  for (const id of ["details", "ask"]) new MutationObserver(syncVideoCover).observe($(id), { attributes: true, attributeFilter: ["hidden"] });
  window.oriel.listen?.("video:error", ({ message }) => {
  if (pv) snack(`This video can't play: ${message || "unsupported format"}. Download it to open it in another app.`, 6000);
  });
  $("pv-close").addEventListener("click", closePreview);
  $("preview").addEventListener("click", (e) => { if (e.target === $("preview")) closePreview(); });
  $("pv-prev").addEventListener("click", () => { if (pv && pv.index > 0) { pv.index--; showPreview(); } });
  $("pv-next").addEventListener("click", () => { if (pv && pv.index < pv.files.length - 1) { pv.index++; showPreview(); } });
  // The open file's menu: what its row's right-click offers. An edit
  // (rename, move, delete) closes the viewer: the file it shows changed.
  $("pv-menu").addEventListener("click", () => {
  if (!pv) return;
  const r = $("pv-menu").getBoundingClientRect();
  const items = pv.source.menu(pv.files[pv.index]).map((it) => it === "-" || !it.changes ? it : { ...it, run: () => { closePreview(); it.run(); } });
  showMenu(r.right - 220, r.bottom + 4, items);
  });

  // Swipe left or right on a touch screen for the next or previous file. The
  // photo follows the finger; a short or mostly vertical drag springs back.
  // Video and audio keep their controls, text its scrolling.
  {
  const body = $("pv-body");
  let swipe = null;
  const springBack = (img) => {
    if (!img) return;
    img.style.transition = "transform 0.2s ease";
    img.style.transform = "";
    img.addEventListener("transitionend", () => { img.style.transition = ""; }, { once: true });
  };
  body.addEventListener("pointerdown", (e) => {
    if (!pv || e.pointerType === "mouse" || e.target.closest("video, audio, pre")) return;
    swipe = { id: e.pointerId, x: e.clientX, y: e.clientY, t: performance.now() };
  });
  body.addEventListener("pointermove", (e) => {
    if (!swipe || e.pointerId !== swipe.id) return;
    const dx = e.clientX - swipe.x;
    const img = body.querySelector("img");
    if (img && Math.abs(dx) > Math.abs(e.clientY - swipe.y)) img.style.transform = `translateX(${dx}px)`;
  });
  body.addEventListener("pointerup", (e) => {
    if (!swipe || e.pointerId !== swipe.id) return;
    const dx = e.clientX - swipe.x;
    const dy = e.clientY - swipe.y;
    const quick = performance.now() - swipe.t < 600;
    swipe = null;
    const sideways = Math.abs(dx) > 60 && Math.abs(dx) > 1.5 * Math.abs(dy);
    if (sideways && (quick || Math.abs(dx) > body.clientWidth / 3)) {
      const button = dx < 0 ? $("pv-next") : $("pv-prev");
      if (!button.disabled) return button.click();
    }
    springBack(body.querySelector("img"));
  });
  body.addEventListener("pointercancel", () => {
    swipe = null;
    springBack(body.querySelector("img"));
  });
  }
  document.addEventListener("keydown", (e) => {
  if (!pv) return;
  if (e.key === "Escape") closePreview();
  else if (e.key === "ArrowLeft") $("pv-prev").click();
  else if (e.key === "ArrowRight") $("pv-next").click();
  });
}
