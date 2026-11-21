// ---- Uploads into the swarm folder ----
//
// Files the page reads itself (picked with the file input, or dropped,
// folders included) go to the node in pieces: swarm_upload_begin, then
// swarm_upload_chunk for each 4 MiB (base64, under the bridge's 32 MiB
// request limit), then swarm_upload_finish, which adds the file. The pure
// parts (planning, base64, progress text) are tested in Node.

export const CHUNK = 4 * 1024 * 1024;

/** Bytes as base64, in slices: one String.fromCharCode call per 32 KiB. */
export function toBase64(bytes) {
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  return btoa(s);
}

/** "a" + "b/c" -> "a/b/c"; "" + "b" -> "b". */
export function joinPath(dir, rel) {
  const clean = rel.split("/").filter((p) => p && p !== "." && p !== "..").join("/");
  if (!dir) return clean;
  return clean ? `${dir}/${clean}` : dir;
}

/** `a/b/c` -> { dir: "a/b", name: "c" }. */
export function splitPath(path) {
  const i = path.lastIndexOf("/");
  return i < 0 ? { dir: "", name: path } : { dir: path.slice(0, i), name: path.slice(i + 1) };
}

/**
 * What to send, into `baseDir`: `files` as [{ file, rel }] (rel: the path
 * inside what was picked or dropped, "a.jpg" or "Trip/day 1/a.jpg"),
 * `dirs` the folders dropped (rel paths, parents first). Answers the folders
 * to create, parents first, and the files with the folder each goes in.
 */
export function planUpload(baseDir, files, dirs = []) {
  // A folder's files make it exist; creating each dropped folder keeps the
  // empty ones too. Parents first: fewer levels first.
  const folders = [...new Set(dirs.map((d) => joinPath(baseDir, d)).filter((p) => p && p !== baseDir))]
    .sort((a, b) => a.split("/").length - b.split("/").length);
  const out = [];
  let bytes = 0;
  for (const { file, rel } of files) {
    const path = joinPath(baseDir, rel || file.name);
    const { dir, name } = splitPath(path);
    if (!name) continue;
    out.push({ file, dir, name });
    bytes += file.size;
  }
  return { folders, files: out, bytes };
}

/** "Uploading 3 of 12 · photo.jpg · 45%", or waiting for sync before finish. */
export function progressText(p) {
  const of = p.total > 1 ? ` ${p.index + 1} of ${p.total}` : "";
  if (p.waiting) return `Waiting for swarm to sync${of} · ${p.name}`;
  const pct = p.bytes ? Math.floor((p.sent / p.bytes) * 100) : 100;
  return `Uploading${of} · ${p.name} · ${pct}%`;
}

/** The snackbar after an upload: what went in, what didn't. */
export function uploadedText(done, failed, cancelled = false, skipped = 0, skipReason = "", { folders = 0, failedFolders = [], cancelReason = "" } = {}) {
  const n = (k, word = "file") => `${k} ${word}${k === 1 ? "" : "s"}`;
  const parts = [];
  if (done && folders) parts.push(`Added ${n(done, "file")} and ${n(folders, "folder")}`);
  else if (done) parts.push(`Added ${n(done, "file")}`);
  else if (folders) parts.push(`Added ${n(folders, "folder")}`);
  if (failed.length) parts.push(`${n(failed.length, "file")} failed (${failed[0].name}: ${failed[0].error})`);
  if (failedFolders.length) parts.push(`${n(failedFolders.length, "folder")} failed (${failedFolders[0].name}: ${failedFolders[0].error})`);
  if (skipped) parts.push(skipReason ? `${skipped} skipped (${skipReason})` : `${skipped} skipped`);
  if (cancelled) parts.push(cancelReason || "cancelled");
  return parts.length ? parts.join(" · ") : "Nothing to add";
}

const STOPPED_REASONS = {
  storage_full: "Stopped: the store is full",
  not_synced: "Stopped: waiting for the swarm to sync",
  no_space: "Stopped: the disk is full",
  failed: "Stopped: part of the folder couldn't be read",
};

/** The snackbar after `swarm_add_folder`: counts, and why it stopped if it did. */
export function folderAddedText(a) {
  const n = (k, w) => `${k} ${w}${k === 1 ? "" : "s"}`;
  const skipped = a.skipped ? ` · ${n(a.skipped, "item")} skipped` : "";
  const base = `Added ${n(a.files, "file")} in ${n(a.folders, "folder")}${skipped}`;
  const reason = (a.stopped_by && a.stopped_by !== "none")
    ? (STOPPED_REASONS[a.stopped_by] || `Stopped: ${a.stopped_by}`)
    : (a.cancelled ? "Stopped" : "");
  if (!reason) return base;
  return a.files || a.folders || a.skipped ? `${reason} · ${base}` : reason;
}

// ---- Reading a drop (folders included) ----

const MAX_DROP_DEPTH = 32; // matches core manifest.max_depth

function readAllEntries(dirEntry) {
  const reader = dirEntry.createReader();
  const all = [];
  return new Promise((resolve, reject) => {
    const next = () => reader.readEntries((batch) => {
      if (!batch.length) return resolve(all);
      all.push(...batch);
      next();
    }, reject);
    next();
  });
}

const fileOf = (entry) => new Promise((resolve, reject) => entry.file(resolve, reject));

/**
 * The files and folders of a drop: { files: [{ file, rel }], dirs: [rel], skipped, skipReason }.
 * Folders through webkitGetAsEntry where the web view has it; otherwise
 * the plain files.
 */
export async function readDrop(dt) {
  const files = [];
  const dirs = [];
  const entries = [];
  let skipped = 0;
  let skipReason = "";
  const noteSkip = (err) => {
    skipped++;
    if (!skipReason) skipReason = String(err);
  };
  // Everything is taken from the items now, before the first await: they
  // are emptied once the drop event's turn ends.
  const items = dt.items || [];
  for (let i = 0; i < items.length; i++) {
    const item = items[i];
    if (item.kind !== "file") continue;
    const entry = item.webkitGetAsEntry ? item.webkitGetAsEntry() : null;
    const plain = item.getAsFile ? item.getAsFile() : null;
    if (entry && entry.isDirectory) entries.push(entry);
    else if (plain) files.push({ file: plain, rel: plain.name });
    else if (entry) entries.push(entry);
  }
  if (!entries.length && !files.length) {
    for (const f of dt.files || []) files.push({ file: f, rel: f.name });
    return { files, dirs, skipped, skipReason };
  }
  // A walk with a stack, not recursion; bounded like the core's.
  const stack = entries.map((e) => ({ entry: e, rel: e.name, depth: 0 }));
  while (stack.length) {
    const { entry, rel, depth } = stack.pop();
    if (entry.isFile) {
      try { files.push({ file: await fileOf(entry), rel }); } catch (err) { noteSkip(err); }
    } else if (entry.isDirectory) {
      if (depth >= MAX_DROP_DEPTH) {
        noteSkip("too deeply nested");
        continue;
      }
      let children = [];
      try {
        children = await readAllEntries(entry);
      } catch (err) {
        noteSkip(err);
        continue;
      }
      dirs.push(rel);
      for (const c of children) stack.push({ entry: c, rel: `${rel}/${c.name}`, depth: depth + 1 });
    }
  }
  dirs.sort((a, b) => a.split("/").length - b.split("/").length);
  return { files, dirs, skipped, skipReason };
}

// ---- Sending ----

const SYNC_RETRY_MS = 3000;
const SYNC_RETRY_MAX = 20;
const defaultWait = (ms) => new Promise((r) => setTimeout(r, ms));
const CANCELLED = Symbol("cancelled");

/**
 * Runs `fn`, retrying up to SYNC_RETRY_MAX times when the swarm hasn't synced yet.
 * Calls `onWait()` before each sleep; returns CANCELLED if `cancelled()` fires.
 */
async function retryNotSynced(fn, { cancelled, onWait, wait }) {
  for (let tries = 0; ; tries++) {
    if (cancelled()) return CANCELLED;
    try {
      return await fn();
    } catch (err) {
      if (!String(err).includes("NotSynced") || tries >= SYNC_RETRY_MAX) throw err;
      if (cancelled()) return CANCELLED;
      onWait();
      await wait(SYNC_RETRY_MS);
    }
  }
}

/**
 * Sends `plan` (planUpload's): the folders, then each file in pieces.
 * `onProgress({ index, total, name, sent, bytes, waiting })`; `cancelled()` is asked
 * between pieces. A file or folder that fails is counted; the rest go on.
 * Answers { done, folders, failed: [{ name, error }], failedFolders: [{ name, error }], skipped, cancelled, restarted? }.
 */
export async function sendUpload(invoke, plan, { onProgress = () => {}, cancelled = () => false, wait = defaultWait, session = null } = {}) {
  // Given, the backend refuses the batch once the node it began on restarted.
  const tag = session == null ? {} : { session };
  // Refused for an old session: the node restarted (a key rotation on another
  // device, say), so the rest of the batch would be refused too. Stop once.
  // An upload begun this batch and then not found was dropped by the same restart.
  const restarted = (err, id = null) => session != null &&
    (String(err).includes("NotRunning") || (id !== null && String(err).includes("UploadNotFound")));
  const failed = [];
  const failedFolders = [];
  const failedDirs = new Set();
  const inFailedDir = (p) => {
    if (!p) return false;
    for (const bad of failedDirs) {
      if (p === bad || p.startsWith(`${bad}/`)) return true;
    }
    return false;
  };
  let folders = 0;
  let skipped = 0;
  for (const path of plan.folders) {
    if (cancelled()) return { done: 0, folders, failed, failedFolders, skipped, cancelled: true };
    if (inFailedDir(path)) {
      skipped++;
      continue;
    }
    const { dir, name } = splitPath(path);
    try {
      const r = await retryNotSynced(
        () => invoke("swarm_mkdir", { dir, name, ...tag }),
        {
          cancelled,
          wait,
          onWait: () => onProgress({ index: 0, total: 0, name, sent: 0, bytes: plan.bytes, waiting: true }),
        },
      );
      if (r === CANCELLED) return { done: 0, folders, failed, failedFolders, skipped, cancelled: true };
      folders++;
    } catch (err) {
      if (restarted(err)) return { done: 0, folders, failed, failedFolders, skipped, cancelled: true, restarted: true };
      if (cancelled()) return { done: 0, folders, failed, failedFolders, skipped, cancelled: true };
      failedDirs.add(path);
      failedFolders.push({ name, error: String(err) });
    }
  }
  let done = 0;
  let sent = 0;
  const total = plan.files.length;
  for (let index = 0; index < total; index++) {
    if (cancelled()) return { done, folders, failed, failedFolders, skipped, cancelled: true };
    const { file, dir, name } = plan.files[index];
    if (inFailedDir(dir)) {
      sent += file.size;
      skipped++;
      continue;
    }
    const report = (waiting = false) => onProgress({ index, total, name, sent, bytes: plan.bytes, waiting });
    report();
    let id = null;
    const start = sent;
    try {
      const beginRes = await retryNotSynced(
        () => invoke("swarm_upload_begin", { dir, name, size: file.size, mtime_ms: file.lastModified || null, ...tag }),
        { cancelled, wait, onWait: () => report(true) },
      );
      if (beginRes === CANCELLED) return { done, folders, failed, failedFolders, skipped, cancelled: true };
      id = beginRes;
      for (let offset = 0; offset < file.size; offset += CHUNK) {
        if (cancelled()) {
          try { await invoke("swarm_upload_cancel", { id }); } catch {}
          return { done, folders, failed, failedFolders, skipped, cancelled: true };
        }
        const piece = new Uint8Array(await file.slice(offset, offset + CHUNK).arrayBuffer());
        if (cancelled()) {
          try { await invoke("swarm_upload_cancel", { id }); } catch {}
          return { done, folders, failed, failedFolders, skipped, cancelled: true };
        }
        await invoke("swarm_upload_chunk", { id, offset, data: toBase64(piece) });
        sent += piece.length;
        report();
      }
      // Retry finish when the swarm has not finished syncing yet (part stays staged).
      const finishRes = await retryNotSynced(
        () => invoke("swarm_upload_finish", { id }),
        { cancelled, wait, onWait: () => report(true) },
      );
      if (finishRes === CANCELLED) {
        try { await invoke("swarm_upload_cancel", { id }); } catch {}
        return { done, folders, failed, failedFolders, skipped, cancelled: true };
      }
      done++;
    } catch (err) {
      if (id !== null) { try { await invoke("swarm_upload_cancel", { id }); } catch {} }
      if (restarted(err, id)) return { done, folders, failed, failedFolders, skipped, cancelled: true, restarted: true };
      if (cancelled()) return { done, folders, failed, failedFolders, skipped, cancelled: true };
      sent = start + file.size; // counted as gone by, for the percentage
      failed.push({ name, error: String(err) });
    }
  }
  return { done, folders, failed, failedFolders, skipped, cancelled: false };
}
