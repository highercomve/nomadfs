// The list of notes: filters, search, the row menu, and the actions on a
// note that don't need the editor (pin, move, delete, new).

import { groupNotes, notebookLabel, otherFiles, plainSnippet, reason, relativeTime, sortNotebooks, visibleNotes } from "./notes-model.js";
import { draftKey } from "./notes-ui.js";

const SEARCH_AFTER_MS = 250;

export function createList(ctx) {
  const { deps, ui, s, api } = ctx;
  const { invoke, snack, icons, svg, showMenu } = deps;
  const { $, el, button, iconButton, here, openMenu, menuAt, parentDir, ask } = ui;
  const reasonOf = reason;
  const titleInput = $("notes-title");

  // ---- The list ----

  async function refresh() {
    const seq = ++s.listSeq;
    if (!deps.isRunning()) {
      s.notes = [];
      s.listError = "";
      renderList();
      return;
    }
    let result;
    try {
      result = await invoke("notes_list", null);
    } catch (error) {
      if (seq !== s.listSeq) return;
      s.listError = `Couldn't list your notes: ${reasonOf(error)}`;
      renderList();
      return;
    }
    if (seq !== s.listSeq) return;
    s.listError = "";
    s.notes = result.notes;
    s.notebooks = result.notebooks;
    if (s.filter.startsWith("nb:") && !s.notes.some((note) => note.editable && note.notebook === s.filter.slice(3))) s.filter = "all";
    renderList();
    api.reconcileOpen();
    api.flushInbox();
    if (s.pendingLink) { const path = s.pendingLink; s.pendingLink = null; openByPath(path); }
  }

  function scheduleRefresh() {
    clearTimeout(s.timers.refresh);
    s.timers.refresh = setTimeout(refresh, 300);
  }

  function renderFilters() {
    const chips = [["all", "All"], ["pinned", "Pinned"], ...sortNotebooks(s.notebooks).map((nb) => [`nb:${nb}`, notebookLabel(nb)])];
    $("notes-filters").replaceChildren(...chips.map(([id, label]) => el("button", {
      type: "button", class: `note-chip${s.filter === id ? " active" : ""}`, role: "tab", "aria-selected": String(s.filter === id), text: label,
      onclick: () => { s.filter = id; renderList(); },
    })));
  }

  function emptyState() {
    const box = $("notes-empty-state");
    const action = $("notes-empty-action");
    let text = "";
    let label = "";
    let run = null;
    if (!deps.isRunning()) { text = "Start NomadFS to see your notes."; label = "Start"; run = () => deps.startNode(); }
    else if (s.listError) { text = s.listError; label = "Retry"; run = refresh; }
    else if (!s.notes.some((note) => note.editable)) { text = "No notes yet. Notes you write here appear on all your devices."; label = "New note"; run = newNote; }
    else if (!visibleNotes(s.notes, { filter: s.filter, query: s.query, bodyHits: s.bodyHits }).length) text = s.query ? `No notes match “${s.query}”.` : "No notes here.";
    box.hidden = !text;
    $("notes-empty-text").textContent = text;
    action.hidden = !run;
    action.textContent = label;
    action.onclick = run;
  }

  function renderList() {
    const active = document.activeElement;
    const focused = active?.closest?.("#notes-items") ? active.dataset.path : null;
    renderFilters();
    emptyState();
    const rows = groupNotes(visibleNotes(s.notes, { filter: s.filter, query: s.query, bodyHits: s.bodyHits }));
    $("notes-items").replaceChildren(...rows.map(({ note, copy }) => noteRow(note, copy)));
    if (focused) $("notes-items").querySelector(`[data-path="${CSS.escape(focused)}"]`)?.focus();
    const others = otherFiles(s.notes);
    $("notes-others-head").hidden = others.length === 0;
    $("notes-others").hidden = others.length === 0;
    $("notes-others").replaceChildren(...others.map((file) => el("li", {},
      el("button", { type: "button", class: "note-row note-file", onclick: () => deps.openInFiles(parentDir(file.path)), title: "Open in Files" },
        el("span", { class: "note-row-title", text: file.title }),
        el("span", { class: "note-row-snippet muted", text: "Not a note · opens in Files" })))));
  }

  function noteRow(note, copy) {
    const selected = s.current?.path === note.path;
    const title = el("span", { class: "note-row-title" });
    if (note.pinned) { const pin = svg(icons.pin); pin.classList.add("note-pin"); title.append(pin); }
    title.append(document.createTextNode(note.title));
    if (note.conflict_of) title.append(el("span", { class: "note-chip small warn", text: "Conflict" }));
    let snippet;
    if (note.snippet === null) snippet = el("span", { class: "note-row-snippet muted", text: "Not on this device yet" });
    else snippet = el("span", { class: "note-row-snippet", text: plainSnippet(note.snippet) || "No text" });
    const who = note.author && note.author !== here() ? ` · ${note.author}` : "";
    const when = el("span", { class: "note-row-time", text: `${relativeTime(note.mtime)}${who}` });
    const open = el("button", {
      type: "button", class: "note-row", role: "option", "aria-selected": String(selected), "data-path": note.path,
      onclick: () => api.openNote(note),
      oncontextmenu: (event) => { event.preventDefault(); openMenu(event.clientX, event.clientY, rowMenu(note)); },
    }, title, snippet, when);
    const more = iconButton("more", "Note actions", (event) => {
      const rect = event.currentTarget.getBoundingClientRect();
      openMenu(rect.left, rect.bottom, rowMenu(note));
    });
    more.classList.add("note-row-more");
    return el("li", { class: `note-item${selected ? " selected" : ""}${copy ? " copy" : ""}` }, open, more);
  }

  function rowMenu(note) {
    const items = [];
    if (note.conflict_of) items.push({ icon: "edit", label: "Merge into note", run: () => api.openMerge(note) }, "-");
    items.push(
      { icon: "pin", label: note.pinned ? "Unpin" : "Pin", run: () => togglePin(note) },
      { icon: "folder", label: "Move to notebook…", run: () => moveMenu(note) },
      { icon: "edit", label: "Rename", run: async () => { await api.openNote(note); titleInput.focus(); titleInput.select(); } },
    );
    if (s.canShare) items.push({ icon: "share", label: "Share", run: () => api.shareNote(note) });
    items.push("-", { icon: "trash", label: "Delete", danger: true, run: () => deleteNote(note) });
    return items;
  }

  // ---- Actions ----

  async function newNote() {
    if (!deps.isRunning()) { snack("Start NomadFS first"); return; }
    await api.leaveNote();
    const notebook = s.filter.startsWith("nb:") ? s.filter.slice(3) : "";
    try {
      const note = await invoke("note_create", { notebook, title: "Untitled", text: "" });
      api.resetEditor();
      await refresh();
      await api.openNote(s.notes.find((item) => item.path === note.path) ?? note);
      titleInput.focus();
      titleInput.select();
    } catch (error) { snack(`Couldn't create a note: ${reasonOf(error)}`); }
  }

  async function togglePin(note) {
    try {
      await invoke("note_pin", { path: note.path, pinned: !note.pinned });
      if (s.current?.path === note.path) s.current = { ...s.current, pinned: !note.pinned };
      await refresh();
    } catch (error) { snack(`Couldn't ${note.pinned ? "unpin" : "pin"}: ${reasonOf(error)}`); }
  }

  function moveMenu(note) {
    const items = [];
    if (note.notebook) items.push({ icon: "folder", label: "No notebook", run: () => moveTo(note, "") });
    for (const nb of sortNotebooks(s.notebooks)) if (nb !== note.notebook) items.push({ icon: "folder", label: notebookLabel(nb), run: () => moveTo(note, nb) });
    if (items.length) items.push("-"); // no divider above a lone item
    items.push({ icon: "folder", label: "New notebook…", run: async () => {
      const name = await ask({ title: "New notebook", label: "Notebook name", ok: "Move" });
      if (name) moveTo(note, name);
    } });
    showMenu(menuAt.x, menuAt.y, items);
  }

  async function moveTo(note, notebook) {
    const isCurrent = s.current?.path === note.path;
    if (isCurrent) await api.saveNow();
    try {
      const moved = await invoke("note_move", { path: note.path, notebook });
      if (isCurrent) { api.adopt(moved); api.renderStatus(); }
      s.filter = s.filter.startsWith("nb:") && !moved.notebook ? "all" : s.filter;
      snack(moved.notebook ? `Moved to ${notebookLabel(moved.notebook)}` : "Moved out of its notebook");
      await refresh();
    } catch (error) {
      snack(String(error).includes("PathAlreadyExists") ? "A note with that title is already there" : `Couldn't move it: ${reasonOf(error)}`);
    }
  }

  async function deleteNote(note) {
    const isCurrent = s.current?.path === note.path;
    if (isCurrent) { s.dirty = false; s.conflict = null; api.clearTimers(); if (s.saving) await s.saving; }
    let removed;
    try { removed = await invoke("note_delete", { path: note.path }); } catch (error) { snack(`Couldn't delete: ${reasonOf(error)}`); return; }
    localStorage.removeItem(draftKey(note.path));
    if (isCurrent) { api.resetEditor(); api.hideEditorPane(); }
    await refresh();
    snack("Note deleted · tap to undo", 10000, async () => {
      try {
        const restored = await invoke("note_restore", removed);
        snack(`Restored “${restored.title}”`);
        await refresh();
      } catch (error) { snack(`Couldn't restore it: ${reasonOf(error)}`); }
    });
  }

  // ---- Search ----

  function onSearch() {
    s.query = $("notes-search").value;
    clearTimeout(s.timers.search);
    s.bodyHits = null;
    renderList();
    if (!s.query.trim() || !deps.isRunning()) return;
    const asked = s.query;
    s.timers.search = setTimeout(async () => {
      try {
        const hits = await invoke("notes_search", { query: asked });
        if (asked !== s.query) return;
        s.bodyHits = new Set(hits.map((hit) => hit.path));
        renderList();
      } catch { /* titles only */ }
    }, SEARCH_AFTER_MS);
  }

  async function openByPath(path) {
    deps.showNotesView();
    if (!deps.isRunning()) { s.pendingLink = path; return; }
    let note = s.notes.find((item) => item.path === path);
    if (!note) { await refresh(); note = s.notes.find((item) => item.path === path); }
    if (note) await api.openNote(note);
    else snack("That note isn't in this swarm yet");
  }

  // ---- Wiring ----

  $("notes-new").addEventListener("click", newNote);
  $("notes-more").append(svg(icons.more));
  $("notes-more").addEventListener("click", (event) => {
    const rect = event.currentTarget.getBoundingClientRect();
    openMenu(rect.right - 200, rect.bottom, [
      { icon: "open_in", label: "Open by code…", run: api.openByCode },
      { icon: "copy", label: "Refresh", run: refresh },
    ]);
  });
  $("notes-search").addEventListener("input", onSearch);

  Object.assign(api, { refresh, scheduleRefresh, renderList, togglePin, moveMenu, deleteNote, newNote, onSearch, openByPath });
}
