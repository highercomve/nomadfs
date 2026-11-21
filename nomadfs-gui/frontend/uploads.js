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

/** "Uploading 3 of 12 · photo.jpg · 45%". */
export function progressText(p) {
  const pct = p.bytes ? Math.floor((p.sent / p.bytes) * 100) : 100;
  const of = p.total > 1 ? ` ${p.index + 1} of ${p.total}` : "";
  return `Uploading${of} · ${p.name} · ${pct}%`;
}

/** The snackbar after an upload: what went in, what didn't. */
export function uploadedText(done, failed, cancelled = false) {
  const n = (k) => `${k} file${k === 1 ? "" : "s"}`;
  const parts = [];
  if (done) parts.push(`Added ${n(done)}`);
  if (failed.length) parts.push(`${n(failed.length)} failed (${failed[0].name}: ${failed[0].error})`);
  if (cancelled) parts.push("cancelled");
  return parts.length ? parts.join(" · ") : "Nothing to add";
}

// ---- Reading a drop (folders included) ----

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
 * The files and folders of a drop: { files: [{ file, rel }], dirs: [rel] }.
 * Folders through webkitGetAsEntry where the web view has it; otherwise
 * the plain files.
 */
export async function readDrop(dt) {
  const files = [];
  const dirs = [];
  const entries = [];
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
    return { files, dirs };
  }
  // A walk with a stack, not recursion; bounded like the core's.
  const stack = entries.map((e) => ({ entry: e, rel: e.name, depth: 0 }));
  while (stack.length) {
    const { entry, rel, depth } = stack.pop();
    if (entry.isFile) {
      try { files.push({ file: await fileOf(entry), rel }); } catch {}
    } else if (entry.isDirectory && depth < 64) {
      dirs.push(rel);
      let children = [];
      try { children = await readAllEntries(entry); } catch {}
      for (const c of children) stack.push({ entry: c, rel: `${rel}/${c.name}`, depth: depth + 1 });
    }
  }
  dirs.sort((a, b) => a.split("/").length - b.split("/").length);
  return { files, dirs };
}

// ---- Sending ----

/**
 * Sends `plan` (planUpload's): the folders, then each file in pieces.
 * `onProgress({ index, total, name, sent, bytes })`; `cancelled()` is asked
 * between pieces. A file that fails is cancelled and counted; the rest go on.
 * Answers { done, failed: [{ name, error }], cancelled }.
 */
export async function sendUpload(invoke, plan, { onProgress = () => {}, cancelled = () => false } = {}) {
  for (const path of plan.folders) {
    const { dir, name } = splitPath(path);
    try { await invoke("swarm_mkdir", { dir, name }); } catch {}
  }
  let done = 0;
  let sent = 0;
  const failed = [];
  const total = plan.files.length;
  for (let index = 0; index < total; index++) {
    if (cancelled()) return { done, failed, cancelled: true };
    const { file, dir, name } = plan.files[index];
    const report = () => onProgress({ index, total, name, sent, bytes: plan.bytes });
    report();
    let id = null;
    const start = sent;
    try {
      id = await invoke("swarm_upload_begin", { dir, name, size: file.size, mtime_ms: file.lastModified || null });
      for (let offset = 0; offset < file.size; offset += CHUNK) {
        if (cancelled()) {
          await invoke("swarm_upload_cancel", { id });
          return { done, failed, cancelled: true };
        }
        const piece = new Uint8Array(await file.slice(offset, offset + CHUNK).arrayBuffer());
        await invoke("swarm_upload_chunk", { id, offset, data: toBase64(piece) });
        sent += piece.length;
        report();
      }
      await invoke("swarm_upload_finish", { id });
      done++;
    } catch (err) {
      sent = start + file.size; // counted as gone by, for the percentage
      failed.push({ name, error: String(err) });
      if (id !== null) { try { await invoke("swarm_upload_cancel", { id }); } catch {} }
    }
  }
  return { done, failed, cancelled: false };
}
