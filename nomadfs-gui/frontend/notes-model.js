// What the Notes screen decides without touching the page: how a list is
// filtered and grouped, how times read, and what a note link looks like.
// The notes themselves (naming, saving, conflicts, pins, which notebooks
// exist, how a shared text is titled) are the Zig service's.

/** "just now", "3 min ago", "2 h ago", "yesterday", "Oct 28" (and the year
 *  for another year). `seconds`: Unix time; `now`: milliseconds. */
export function relativeTime(seconds, now = Date.now(), locale) {
  if (!seconds) return "";
  const ms = seconds * 1000;
  const diff = Math.max(0, Math.round((now - ms) / 1000));
  if (diff < 60) return "just now";
  if (diff < 3600) return `${Math.round(diff / 60)} min ago`;
  if (diff < 86400) return `${Math.round(diff / 3600)} h ago`;
  if (diff < 2 * 86400) return "yesterday";
  const date = new Date(ms);
  const sameYear = date.getFullYear() === new Date(now).getFullYear();
  return date.toLocaleDateString(locale, sameYear ? { month: "short", day: "numeric" } : { year: "numeric", month: "short", day: "numeric" });
}

/** A list row's one-line preview of Markdown text: the marks that only
 *  format (#, **, `, list dashes) are left out; task boxes become ☐ and ☑. */
export function plainSnippet(text) {
  return String(text)
    .replace(/(^|\s)#{1,6}\s+/g, "$1")
    .replace(/(^|\s)[-*+]\s+\[ \]\s/g, "$1☐ ")
    .replace(/(^|\s)[-*+]\s+\[[xX]\]\s/g, "$1☑ ")
    .replace(/^[-*+]\s/, "• ")
    .replace(/\*\*|~~|`/g, "")
    .trim();
}

/** A notebook as shown: "Work / Ideas" for "Work/Ideas". */
export function notebookLabel(notebook) {
  return notebook.split("/").join(" / ");
}

/** The notes a filter chip and a search leave. `filter`: "all", "pinned" or
 *  "nb:<notebook>". `query`: matched against titles here; `bodyHits`: paths
 *  the service found the query in (notes_search), or null. Files that aren't
 *  notes are not in this list (see `otherFiles`). */
export function visibleNotes(notes, { filter = "all", query = "", bodyHits = null } = {}) {
  const q = query.trim().toLowerCase();
  return notes.filter((note) => {
    if (!note.editable) return false;
    if (filter === "pinned" && !note.pinned) return false;
    if (filter.startsWith("nb:") && note.notebook !== filter.slice(3)) return false;
    if (!q) return true;
    return note.title.toLowerCase().includes(q) || !!bodyHits?.has(note.path);
  });
}

/** Files in Notes/ the editor doesn't open. */
export function otherFiles(notes) {
  return notes.filter((note) => !note.editable);
}

/** Rows for the list, in the service's order (pinned, then newest), with a
 *  conflict copy right under the note it is a copy of. A copy whose note is
 *  filtered out or gone is a row of its own. */
export function groupNotes(notes) {
  const paths = new Set(notes.map((note) => note.path));
  const copies = new Map();
  for (const note of notes) {
    if (note.conflict_of && paths.has(note.conflict_of)) {
      if (!copies.has(note.conflict_of)) copies.set(note.conflict_of, []);
      copies.get(note.conflict_of).push(note);
    }
  }
  const rows = [];
  for (const note of notes) {
    if (note.conflict_of && paths.has(note.conflict_of)) continue;
    rows.push({ note, copy: false });
    for (const copy of copies.get(note.path) ?? []) rows.push({ note: copy, copy: true });
  }
  return rows;
}

/** The notebooks the service listed, in the order the chips and the move
 *  menu show them. */
export function sortNotebooks(notebooks) {
  return [...notebooks].sort((a, b) => a.localeCompare(b));
}

/** `nomadfs://note/<path>`: the link another device in the swarm opens. */
export function noteLink(path) {
  return `nomadfs://note/${path.split("/").map(encodeURIComponent).join("/")}`;
}

/** The note path in a `nomadfs://note/…` link, or null for any other URL. */
export function parseNoteLink(url) {
  const match = /^nomadfs:\/\/note\/([^?#]+)/i.exec(String(url));
  if (!match) return null;
  try {
    const path = match[1].split("/").map(decodeURIComponent).join("/");
    return path.startsWith("Notes/") && !path.split("/").includes("..") ? path : null;
  } catch {
    return null;
  }
}

/** Why a command failed, for the status line. */
export function reason(error) {
  const text = String(error?.message ?? error);
  const known = [
    ["NotSynced", "still syncing with your other devices"],
    ["NotRunning", "NomadFS isn't running"],
    ["FileTooLarge", "the note is over 8 MiB"],
    ["PathAlreadyExists", "a note with that title exists"],
    ["FileNotFound", "the note is gone"],
    ["NotText", "this file isn't text"],
    ["NotANote", "that isn't a note"],
    ["NotAConflictCopy", "that isn't a copy of this note"],
    ["StorageDisabled", "this device has no block storage"],
  ];
  for (const [key, message] of known) if (text.includes(key)) return message;
  return text;
}
