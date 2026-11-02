// The open note: opening, the text and its autosave, a note that changed
// under the editor, the title, the preview. What the note *is* (saving,
// conflicts, names) is the Zig service's; this decides when to ask it.

import { renderMarkdown, toggleTask } from "./markdown.js";
import { noteLink, parseNoteLink, reason, relativeTime } from "./notes-model.js";
import { draftKey } from "./notes-ui.js";

const DRAFT_AFTER_MS = 500; // typing stops: keep the text in localStorage
const COMMIT_AFTER_MS = 2000; // typing stops: save to the swarm
const COMMIT_AT_MOST_MS = 30000; // continuous typing: save at least this often
const RETRY_AFTER_MS = 5000; // a failed save is tried again
const SYNC_HINT_MS = 10000; // the swarm folder syncs every 10 s

export function createEditor(ctx) {
  const { deps, ui, s, api } = ctx;
  const { invoke, snack, icons, svg, copyText } = deps;
  const { $, el, button, here, openMenu, parentDir, showBanner, hideBanner, strong, actions } = ui;
  const reasonOf = reason;
  const view = $("notes-view");
  const titleInput = $("notes-title");
  const body = $("notes-body");
  const preview = $("notes-preview");

  const isOpen = () => s.phase !== "none" || s.mergeOpen;
  const editing = () => isOpen() && ui.narrow.matches;

  // ---- Status line ----

  function renderStatus() {
    if (s.phase === "code") { $("notes-status").textContent = "Opened by code · read only"; return; }
    if (!s.current) { $("notes-status").textContent = ""; return; }
    const author = s.current.author && s.current.author !== here() ? ` on ${s.current.author}` : "";
    const edited = s.current.mtime ? `Edited ${relativeTime(s.current.mtime)}${author}` : "";
    $("notes-status").textContent = [edited, s.saveState].filter(Boolean).join(" · ");
  }

  function setSaveState(text) {
    s.saveState = text;
    renderStatus();
  }

  // ---- Opening and leaving a note ----

  function showEditorPane() {
    $("notes-placeholder").hidden = true;
    $("notes-merge").hidden = true;
    $("notes-editor").hidden = false;
    view.classList.add("note-editing");
    deps.syncBack();
  }

  function hideEditorPane() {
    $("notes-editor").hidden = true;
    $("notes-merge").hidden = true;
    $("notes-placeholder").hidden = false;
    view.classList.remove("note-editing");
    deps.syncBack();
  }

  function resetEditor() {
    clearTimers();
    s.phase = "none";
    s.mergeOpen = false;
    s.current = null;
    s.base = "";
    s.loadedText = "";
    s.dirty = false;
    s.conflict = null;
    s.myDraft = null;
    s.saveState = "";
    setPreview(false);
    body.value = "";
    body.readOnly = false;
    body.disabled = false;
    titleInput.value = "";
    titleInput.readOnly = false;
    hideTitleError();
    hideBanner();
    renderStatus();
  }

  async function openNote(note) {
    if (!note.editable) return deps.openInFiles(parentDir(note.path));
    if (s.current?.path === note.path && (s.phase === "ready" || s.phase === "loading")) { showEditorPane(); return; }
    await leaveNote();
    resetEditor();
    const token = ++s.openToken;
    s.phase = "loading";
    s.current = note;
    titleInput.value = note.title;
    body.value = "";
    body.disabled = true;
    s.saveState = "Opening…";
    showEditorPane();
    renderStatus();
    api.renderList();
    await loadText(token, note);
  }

  /** Reads the note's text into the editor. `how`: a snackbar to show. */
  async function loadText(token, note, how = "", reload = false) {
    let loaded;
    try {
      loaded = await invoke("note_read", { path: note.path });
    } catch (error) {
      if (token !== s.openToken) return;
      s.phase = "unavailable";
      body.disabled = true;
      s.saveState = "";
      renderStatus();
      const notText = String(error).includes("NotText");
      showBanner("error", notText ? "This file isn't valid text, so it can't be edited here. " : "Can't open: the devices that have this note are offline. ",
        actions(notText ? button("Open in Files", () => deps.openInFiles(parentDir(note.path))) : button("Retry", () => retryOpen(token, note))));
      return;
    }
    if (token !== s.openToken) return;
    // Typed while it was being read: the text on screen is newer.
    if (reload && (s.dirty || body.value !== s.loadedText)) return;
    s.base = loaded.cid;
    s.loadedText = loaded.text;
    const draft = localStorage.getItem(draftKey(note.path));
    body.disabled = false;
    hideBanner();
    if (draft !== null && draft !== loaded.text) {
      body.value = draft;
      s.dirty = true;
      s.saveState = "Draft restored · not saved yet";
      scheduleSave();
    } else {
      localStorage.removeItem(draftKey(note.path));
      body.value = loaded.text;
      s.dirty = false;
      s.saveState = "Saved";
    }
    s.phase = "ready";
    s.current = note;
    if (note.conflict_of) conflictCopyBanner(note);
    autosize();
    if (s.previewOn) renderPreview();
    renderStatus();
    if (how) snack(how);
  }

  function retryOpen(token, note) {
    if (token !== s.openToken) return;
    s.phase = "loading";
    hideBanner();
    s.saveState = "Opening…";
    renderStatus();
    loadText(token, note);
  }

  function conflictCopyBanner(copy) {
    const original = s.notes.find((note) => note.path === copy.conflict_of);
    showBanner("warn", "This is a conflict copy of ", strong(original ? original.title : "another note"), ". ",
      actions(button("Merge into note", () => api.openMerge(copy))));
  }

  /** Saves what is pending and closes the open note. */
  async function leaveNote() {
    if (!isOpen()) return;
    if (s.dirty) await saveNow();
    const blank = s.phase === "ready" && !s.dirty && !s.conflict && s.loadedText.trim() === "" && /^Untitled( \d+)?$/.test(s.current?.title ?? "") && !s.current?.pinned;
    const path = s.current?.path;
    if (blank) {
      // A note that was started and never written: not left behind.
      try { await invoke("note_delete", { path }); } catch {}
      localStorage.removeItem(draftKey(path));
      api.scheduleRefresh();
    }
  }

  async function closeEditor() {
    await leaveNote();
    resetEditor();
    hideEditorPane();
    api.renderList();
  }

  // ---- The text: typing, drafts, saving ----

  function clearTimers() {
    for (const key of ["draft", "commit", "atMost", "retry", "hint"]) { clearTimeout(s.timers[key]); s.timers[key] = 0; }
  }

  function autosize() {
    body.style.height = "auto";
    body.style.height = `${Math.max(body.scrollHeight, 240)}px`;
  }

  function onInput() {
    if (s.phase !== "ready") return;
    s.dirty = true;
    setSaveState(s.conflict ? "Not saved: changed on another device" : "Unsaved changes");
    autosize();
    if (s.conflict) return;
    scheduleSave();
  }

  function scheduleSave() {
    clearTimeout(s.timers.draft);
    clearTimeout(s.timers.commit);
    const path = s.current.path;
    s.timers.draft = setTimeout(() => { try { localStorage.setItem(draftKey(path), body.value); } catch {} }, DRAFT_AFTER_MS);
    s.timers.commit = setTimeout(saveNow, COMMIT_AFTER_MS);
    if (!s.timers.atMost) s.timers.atMost = setTimeout(saveNow, COMMIT_AT_MOST_MS);
  }

  async function saveNow() {
    for (const key of ["commit", "atMost", "retry"]) { clearTimeout(s.timers[key]); s.timers[key] = 0; }
    if (s.saving) await s.saving;
    if (!s.dirty || s.phase !== "ready" || s.conflict) return;
    s.saving = doSave();
    try { await s.saving; } finally { s.saving = null; }
  }

  async function doSave() {
    const token = s.openToken;
    const text = body.value;
    const path = s.current.path;
    try { localStorage.setItem(draftKey(path), text); } catch {}
    setSaveState("Saving…");
    let result;
    try {
      result = await invoke("note_save", { path, text, base: s.base });
    } catch (error) {
      if (token !== s.openToken) return;
      setSaveState(`Not saved: ${reasonOf(error)}`);
      s.timers.retry = setTimeout(saveNow, RETRY_AFTER_MS);
      return;
    }
    if (token !== s.openToken) return;
    if (result.changed) { enterConflict(result.note); return; }
    adopt(result.note);
    s.loadedText = text;
    if (body.value === text) {
      s.dirty = false;
      localStorage.removeItem(draftKey(path));
      localStorage.removeItem(draftKey(s.current.path));
      setSaveState("Saved on this device · syncing");
      clearTimeout(s.timers.hint);
      s.timers.hint = setTimeout(() => { if (!s.dirty && !s.conflict && s.phase === "ready") setSaveState("Saved"); }, SYNC_HINT_MS);
    } else {
      scheduleSave(); // typed while saving
    }
    api.scheduleRefresh();
  }

  /** The service's answer replaces what the editor knew of the note (its
   *  path changes when saving renames a legacy note). */
  function adopt(note) {
    if (!note) return;
    const moved = s.current && s.current.path !== note.path;
    if (moved && s.dirty === false) localStorage.removeItem(draftKey(s.current.path));
    s.current = note;
    s.base = note.cid;
    if (document.activeElement !== titleInput) titleInput.value = note.title;
  }

  // ---- Conflicts: the note changed under the editor ----

  function enterConflict(theirs) {
    s.conflict = { theirs };
    setSaveState("Not saved: changed on another device");
    if (!theirs) {
      showBanner("error", "This note was deleted or renamed on another device while you were editing. ",
        actions(button("Keep my text as a new note", keepAsNew), button("Discard my text", discardMine)));
      return;
    }
    showBanner("warn", "This note changed on ", strong(theirs.author || "another device"), " while you were editing. ",
      actions(
        button("See their version", seeTheirs),
        button("Keep both", keepBoth),
        el("button", { type: "button", class: "btn text danger", onclick: replaceWithMine, title: "Their version is replaced. It stays reachable only through the folder's history.", text: "Replace with mine" }),
      ));
  }

  async function seeTheirs() {
    const { theirs } = s.conflict;
    s.myDraft = body.value;
    if (!(await showTheirs(theirs))) { s.myDraft = null; return; }
    showBanner("warn", "Showing ", strong(theirs.author || "their"), " version. ",
      actions(button("Restore my draft", restoreDraft)));
  }

  /** Loads the other device's version into the editor. */
  async function showTheirs(theirs) {
    let loaded;
    try { loaded = await invoke("note_read", { path: theirs.path }); } catch (error) { snack(`Couldn't open their version: ${reasonOf(error)}`); return false; }
    s.current = theirs;
    s.base = loaded.cid;
    s.loadedText = loaded.text;
    body.value = loaded.text;
    s.dirty = false;
    s.conflict = null;
    localStorage.removeItem(draftKey(theirs.path));
    titleInput.value = theirs.title;
    autosize();
    setSaveState("Saved");
    hideBanner();
    if (s.previewOn) renderPreview();
    return true;
  }

  function restoreDraft() {
    body.value = s.myDraft;
    s.myDraft = null;
    hideBanner();
    autosize();
    onInput();
  }

  async function keepBoth() {
    const mine = body.value;
    const { theirs } = s.conflict;
    try {
      const copy = await invoke("note_keep_both", { path: theirs.path, text: mine });
      snack(`Yours is saved as “${copy.title}”`);
    } catch (error) { snack(`Couldn't keep both: ${reasonOf(error)}`); return; }
    await showTheirs(theirs);
    api.scheduleRefresh();
  }

  async function replaceWithMine() {
    const { theirs } = s.conflict;
    const text = body.value;
    try {
      const result = await invoke("note_save", { path: theirs.path, text, base: theirs.cid });
      if (result.changed) { enterConflict(result.note); return; }
      s.conflict = null;
      adopt(result.note);
      s.loadedText = text;
      s.dirty = false;
      localStorage.removeItem(draftKey(result.note.path));
      hideBanner();
      setSaveState("Saved on this device · syncing");
      api.scheduleRefresh();
    } catch (error) { snack(`Couldn't replace it: ${reasonOf(error)}`); }
  }

  async function keepAsNew() {
    try {
      const copy = await invoke("note_create", { notebook: s.current.notebook, title: s.current.title, text: body.value });
      snack(`Saved as “${copy.title}”`);
      localStorage.removeItem(draftKey(s.current.path));
      s.dirty = false;
      s.conflict = null;
      await api.refresh();
      const fresh = s.notes.find((note) => note.path === copy.path);
      resetEditor();
      if (fresh) await openNote(fresh);
    } catch (error) { snack(`Couldn't save it: ${reasonOf(error)}`); }
  }

  async function discardMine() {
    localStorage.removeItem(draftKey(s.current.path));
    s.dirty = false;
    s.conflict = null;
    resetEditor();
    hideEditorPane();
    api.scheduleRefresh();
  }

  /** The list changed (a sync, a rename): follow or reload the open note. */
  function reconcileOpen() {
    if (!s.current || s.phase === "code" || s.phase === "none") return;
    let found = s.notes.find((note) => note.path === s.current.path);
    if (!found) {
      // Renamed or moved elsewhere (or by the legacy rename of a save): the same text.
      found = s.notes.find((note) => note.cid === s.base && note.editable);
      if (!found && !s.dirty && !s.saving && !s.conflict && s.phase === "ready") {
        showBanner("error", "This note was deleted on another device. ", actions(button("Close", closeEditor)));
        return;
      }
      if (found) { adopt(found); api.renderList(); }
      return;
    }
    if (found.cid !== s.base && !s.dirty && !s.saving && !s.conflict && s.phase === "ready") {
      const who = found.author && found.author !== here() ? found.author : "";
      s.current = found;
      loadText(s.openToken, found, who ? `Updated from ${who}` : "", true);
      return;
    }
    if (!s.saving) { s.current = { ...found }; if (document.activeElement !== titleInput) titleInput.value = found.title; }
    renderStatus();
  }

  // ---- Title (renames the file) ----

  const hideTitleError = () => { $("notes-title-error").hidden = true; };
  function showTitleError(text) {
    $("notes-title-error").textContent = text;
    $("notes-title-error").hidden = false;
  }

  async function commitTitle() {
    if (s.phase !== "ready" || !s.current) return;
    const wanted = titleInput.value.trim();
    if (!wanted || wanted === s.current.title || s.conflict) { titleInput.value = s.current.title; hideTitleError(); return; }
    await saveNow();
    if (s.conflict) { titleInput.value = s.current.title; return; }
    let result;
    try {
      result = await invoke("note_rename", { path: s.current.path, title: wanted, base: s.base });
    } catch (error) {
      if (String(error).includes("PathAlreadyExists")) showTitleError("A note with this title exists.");
      else showTitleError(`Couldn't rename: ${reasonOf(error)}`);
      return;
    }
    hideTitleError();
    if (result.changed) {
      titleInput.value = s.current.title;
      snack("This note changed on another device. Try renaming again.");
      api.scheduleRefresh();
      return;
    }
    const old = s.current.path;
    adopt(result.note);
    titleInput.value = result.note.title;
    if (s.dirty) { try { localStorage.setItem(draftKey(result.note.path), body.value); localStorage.removeItem(draftKey(old)); } catch {} }
    renderStatus();
    api.scheduleRefresh();
  }

  async function shareNote(note) {
    let text = body.value;
    if (s.current?.path !== note.path) {
      try { text = (await invoke("note_read", { path: note.path })).text; } catch (error) { snack(`Couldn't read it: ${reasonOf(error)}`); return; }
    }
    try { await window.oriel.share.send({ title: note.title, text }); } catch { snack("Sharing isn't available here"); }
  }

  function editorMenu() {
    if (!s.current) return [];
    const items = [
      { icon: "copy", label: "Copy text", run: () => copyText(body.value, "Text copied") },
      { icon: "download", label: "Export…", run: exportNote },
      { icon: "link", label: "Copy link", run: () => copyText(noteLink(s.current.path), "Link copied") },
      "-",
      { icon: "pin", label: s.current.pinned ? "Unpin" : "Pin", run: () => api.togglePin(s.current) },
      { icon: "folder", label: "Move to notebook…", run: () => api.moveMenu(s.current) },
      { icon: "info", label: "Details", run: () => deps.openDetails(s.current.title, { cid: s.current.cid, author_id: s.current.author_id }) },
      "-",
      { icon: "trash", label: "Delete", danger: true, run: () => api.deleteNote(s.current) },
    ];
    return items;
  }

  async function exportNote() {
    try {
      const saved = await invoke("note_export", { text: body.value });
      if (saved) snack("Exported");
    } catch (error) { snack(`Couldn't export: ${reasonOf(error)}`); }
  }

  function setPreview(on) {
    s.previewOn = on;
    preview.hidden = !on;
    body.hidden = on;
    $("notes-preview-toggle").textContent = on ? "Edit" : "Preview";
    if (on) renderPreview();
  }

  function renderPreview() {
    preview.replaceChildren(renderMarkdown(body.value, {
      onToggleTask: (line, checked) => { body.value = toggleTask(body.value, line, checked); onInput(); },
      onLink: (href) => {
        const path = parseNoteLink(href);
        if (path) api.openByPath(path);
        else if (/^(https?:\/\/|mailto:)/i.test(href)) window.oriel.openExternal(href).catch(() => {});
      },
    }));
  }

  // ---- Wiring ----

  $("notes-menu").append(svg(icons.more));
  $("notes-menu").addEventListener("click", (event) => {
    const rect = event.currentTarget.getBoundingClientRect();
    openMenu(rect.right - 200, rect.bottom, editorMenu());
  });
  $("notes-back").addEventListener("click", closeEditor);
  $("notes-preview-toggle").addEventListener("click", () => setPreview(!s.previewOn));
  $("notes-share").addEventListener("click", () => s.current && shareNote(s.current));
  body.addEventListener("input", onInput);
  body.addEventListener("blur", () => { if (s.dirty) saveNow(); });
  titleInput.addEventListener("input", hideTitleError);
  titleInput.addEventListener("blur", commitTitle);
  titleInput.addEventListener("keydown", (event) => {
    if (event.key === "Enter") { event.preventDefault(); commitTitle().then(() => body.focus()); }
    if (event.key === "Escape") { titleInput.value = s.current?.title ?? ""; body.focus(); }
  });

  Object.assign(api, {
    renderStatus, showEditorPane, hideEditorPane, resetEditor, openNote, leaveNote, closeEditor,
    clearTimers, autosize, saveNow, adopt, reconcileOpen, shareNote, setPreview, editing,
  });
}
