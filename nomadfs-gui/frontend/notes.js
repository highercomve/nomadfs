// The Notes screen: list, editor, autosave, conflicts, sharing, links.
//
// Everything a note *is* (names, saving, conflicts, pins, migration) is the
// Zig service's (src/fs/notes.zig, reached through the note_* commands).
// This presents it: it keeps the list and the one open note, decides when to
// ask the service to save, and shows the answers. The parts:
//   notes-ui.js      element helpers, the question dialog, the banner
//   notes-list.js    the list, filters, search, and the actions on a note
//   notes-editor.js  the open note: text, autosave, conflicts, title, preview
//   notes-merge.js   a conflict copy beside its note
// They share one state object and reach each other through `ctx.api`.

import { createEditor } from "./notes-editor.js";
import { createList } from "./notes-list.js";
import { createMerge } from "./notes-merge.js";
import { createUi } from "./notes-ui.js";
import { parseNoteLink, reason } from "./notes-model.js";

const INBOX_KEY = "note-inbox";

/** What the parts share. `phase`: "none" | "loading" | "ready" | "unavailable" | "code". */
function initialState() {
  return {
    // The list.
    notes: [],
    notebooks: [], // those that hold a note, from the service
    filter: "all", // "all", "pinned" or "nb:<notebook>"
    query: "",
    bodyHits: null, // paths whose text matches `query` (notes_search)
    listError: "",
    listSeq: 0,
    pendingLink: null,
    // The open note.
    phase: "none",
    current: null, // the service's view of the note, as last seen
    base: "", // CID (hex) of the text the editor started from or last saved
    loadedText: "",
    dirty: false,
    conflict: null, // { theirs } while a save waits for a choice
    myDraft: null, // text set aside by "See their version"
    saving: null,
    saveState: "",
    previewOn: false,
    openToken: 0,
    mergeOpen: false,
    canShare: false,
    timers: { draft: 0, commit: 0, atMost: 0, retry: 0, hint: 0, search: 0, refresh: 0 },
  };
}

/** deps: invoke, snack(msg, ms, onClick), icons, svg, showMenu(x, y, items),
 *  copyText(text, done), syncBack(), isRunning(), startNode(), deviceName(),
 *  openDetails(name, src), openInFiles(dir), showNotesView(). */
export function initNotes(deps) {
  const { invoke, snack } = deps;
  const ui = createUi(deps);
  const { $, button, ask, showBanner, actions } = ui;
  const ctx = { deps, ui, s: initialState(), api: {} };
  const { s, api } = ctx;
  const reasonOf = reason;
  const titleInput = $("notes-title");
  const body = $("notes-body");

  createEditor(ctx);
  createList(ctx);
  createMerge(ctx);

  // ---- Open by code ----

  async function openByCode() {
    const code = await ask({ title: "Open by code", text: "A note, or any text file in the swarm, by its 64-character code (CID).", label: "Code (CID)", ok: "Open", paste: true });
    if (!code) return;
    if (!/^[0-9a-fA-F]{64}$/.test(code)) { snack("A code is 64 hex characters"); return; }
    const cid = code.toLowerCase();
    const known = s.notes.find((note) => note.cid === cid && note.editable);
    if (known) { await api.openNote(known); return; }
    await api.leaveNote();
    api.resetEditor();
    const token = ++s.openToken;
    s.phase = "code";
    titleInput.value = `${cid.slice(0, 8)}…${cid.slice(-6)}`;
    titleInput.readOnly = true;
    body.readOnly = true;
    body.value = "";
    api.showEditorPane();
    api.renderStatus();
    try {
      const text = await invoke("get_text", { cid });
      if (token !== s.openToken) return;
      body.value = text;
      api.autosize();
      showBanner("warn", "Opened by code: read only. ", actions(button("Save as a note", async () => {
        try {
          const note = await invoke("note_from_share", { text });
          await api.refresh();
          await api.openNote(s.notes.find((item) => item.path === note.path) ?? note);
        } catch (error) { snack(`Couldn't save it: ${reasonOf(error)}`); }
      })));
    } catch (error) {
      if (token !== s.openToken) return;
      showBanner("error", `Couldn't open this code: ${reasonOf(error)}. The devices that have it may be offline.`);
    }
  }

  // ---- Sharing in, and links ----

  const readInbox = () => { try { return JSON.parse(localStorage.getItem(INBOX_KEY) || "[]"); } catch { return []; } };
  const writeInbox = (items) => { try { localStorage.setItem(INBOX_KEY, JSON.stringify(items)); } catch {} };
  let flushing = false;

  /** Writes queued shares as notes; what can't be written yet (the node is
   *  not running) stays queued. */
  async function flushInbox() {
    if (flushing || !deps.isRunning()) return;
    flushing = true;
    try {
      let items = readInbox();
      while (items.length) {
        const item = items[0];
        try {
          const note = await invoke("note_from_share", { text: item.text || "", url: item.url || "", subject: item.subject || "", name: item.name || "" });
          items = readInbox().slice(1);
          writeInbox(items);
          snack("Saved to Notes", 8000, async () => { deps.showNotesView(); await api.refresh(); const fresh = s.notes.find((n) => n.path === note.path); if (fresh) api.openNote(fresh); });
          api.scheduleRefresh();
        } catch (error) {
          if (/NotRunning|NotSynced/.test(String(error))) return; // later
          items = readInbox().slice(1); // can't ever be written: drop it
          writeInbox(items);
          snack(`Couldn't save a shared note: ${reasonOf(error)}`);
        }
      }
    } finally { flushing = false; }
  }

  async function onShare(share) {
    const queued = [];
    if (share.text || share.url) queued.push({ text: share.text || "", url: share.url || "", subject: share.subject || "" });
    for (const file of share.files || []) {
      if (!/^text\//.test(file.mime || "") && !/\.(md|markdown|txt)$/i.test(file.name || "")) continue;
      try { queued.push({ text: await (await window.oriel.share.file(file)).text(), name: file.name }); } catch { snack(`Couldn't read ${file.name}`); }
    }
    if (!queued.length) return;
    writeInbox([...readInbox(), ...queued]);
    if (!deps.isRunning()) snack("Saved to Notes when NomadFS is running");
    flushInbox();
  }

  Object.assign(api, { openByCode, flushInbox });

  // ---- Wiring ----

  document.addEventListener("visibilitychange", () => {
    if (document.hidden) { if (s.dirty) api.saveNow(); } else if (document.body.dataset.view === "notes") api.scheduleRefresh();
  });
  addEventListener("pagehide", () => { if (s.dirty) api.saveNow(); });

  document.addEventListener("keydown", (event) => {
    if (document.body.dataset.view !== "notes" || $("notes-dialog").open) return;
    const mod = event.ctrlKey || event.metaKey;
    const key = event.key.toLowerCase();
    if (mod && key === "n") { event.preventDefault(); api.newNote(); }
    else if (mod && (key === "f" || key === "k")) { event.preventDefault(); $("notes-search").focus(); $("notes-search").select(); }
    else if (mod && key === "s") { event.preventDefault(); api.saveNow(); }
    else if (mod && key === "e") { event.preventDefault(); if (s.phase === "ready") api.setPreview(!s.previewOn); }
    else if (mod && event.shiftKey && key === "p") { event.preventDefault(); if (s.current) api.togglePin(s.current); }
    else if (event.key === "Escape") {
      if (document.activeElement === $("notes-search") && $("notes-search").value) { $("notes-search").value = ""; api.onSearch(); }
      else if (api.editing()) api.closeEditor();
    } else if ((event.key === "ArrowDown" || event.key === "ArrowUp") && !mod) {
      const active = document.activeElement;
      const inList = active?.classList?.contains("note-row") || active === $("notes-search");
      if (!inList) return;
      const rows = [...$("notes-items").querySelectorAll(".note-row")];
      if (!rows.length) return;
      event.preventDefault();
      const at = rows.indexOf(active);
      const next = event.key === "ArrowDown" ? (at < 0 ? 0 : Math.min(at + 1, rows.length - 1)) : at <= 0 ? -1 : at - 1;
      if (next < 0) $("notes-search").focus(); else rows[next].focus();
    }
  });

  window.oriel.listen("notes://changed", api.scheduleRefresh);
  window.oriel.listen("share:received", onShare);
  window.oriel.listen("deep-link", ({ url }) => { const path = parseNoteLink(url); if (path) api.openByPath(path); });
  window.oriel.share.capabilities().then((caps) => {
    s.canShare = !!(caps?.send?.supported && caps.send.text);
    $("notes-share").hidden = !s.canShare;
  }).catch(() => { s.canShare = false; });
  ui.narrow.addEventListener("change", () => deps.syncBack());

  api.renderList();
  api.renderStatus();
  api.refresh(); // also writes any share queued before the app was closed

  return {
    /** The Notes view was opened. */
    show() { api.refresh(); },
    /** The view was left: what is typed goes to the swarm. */
    hide() { if (s.dirty) api.saveNow(); },
    refresh: api.refresh,
    /** An editor is open full screen (phone layout): Back closes it. */
    editing: api.editing,
    closeEditor: api.closeEditor,
  };
}
