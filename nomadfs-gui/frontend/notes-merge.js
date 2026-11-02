// Merge: a conflict copy next to its note. The two texts are shown here;
// settling it (use the copy, append it, delete it) is one call to the service.

import { reason, relativeTime } from "./notes-model.js";

export function createMerge(ctx) {
  const { deps, ui, s, api } = ctx;
  const { invoke, snack } = deps;
  const { $, el, button, here, actions } = ui;
  const reasonOf = reason;
  const view = $("notes-view");

  // ---- Merge: a conflict copy next to its note ----

  async function openMerge(copy) {
    const original = s.notes.find((note) => note.path === copy.conflict_of);
    if (!original) { snack("The note this is a copy of is gone"); return; }
    await api.leaveNote();
    api.resetEditor();
    ++s.openToken;
    let a;
    let b;
    try {
      [a, b] = await Promise.all([invoke("note_read", { path: original.path }), invoke("note_read", { path: copy.path })]);
    } catch (error) { snack(`Couldn't open both versions: ${reasonOf(error)}`); return; }
    s.phase = "none";
    const pane = $("notes-merge");
    const side = (heading, meta, text) => el("section", { class: "merge-side" },
      el("h3", { text: heading }), el("p", { class: "meta", text: meta }), el("pre", { class: "merge-text", text }));
    const meta = (note) => `Edited ${relativeTime(note.mtime)}${note.author ? ` on ${note.author}` : ""}`;
    const finish = async (action) => {
      try {
        const result = await invoke("note_resolve_copy", { path: original.path, base: a.cid, copy: copy.path, copy_cid: b.cid, action });
        if (result.changed) { snack("The note changed again. Open the merge again."); await api.refresh(); return; }
        await api.refresh();
        const fresh = s.notes.find((note) => note.path === original.path);
        if (fresh) await api.openNote(fresh); else api.hideEditorPane();
        if (action === "discard") snack("Copy deleted · tap to undo", 10000, async () => { try { await invoke("note_restore", result.removed); await api.refresh(); } catch (error) { snack(`Couldn't restore it: ${reasonOf(error)}`); } });
        else if (!result.removed) snack("Merged, but the copy could not be deleted");
      } catch (error) { snack(`Couldn't merge: ${reasonOf(error)}`); }
    };
    pane.replaceChildren(
      el("h2", { text: `Merge “${copy.title}” into “${original.title}”` }),
      el("div", { class: "merge-sides" }, side("The note", meta(original), a.text), side("This copy", meta(copy), b.text)),
      el("div", { class: "merge-actions" },
        button("Use this one", () => finish("use_copy"), "btn filled"),
        button("Append to the note", () => finish("append"), "btn outlined"),
        el("button", { type: "button", class: "btn text danger", onclick: () => finish("discard"), text: "Delete this copy" }),
        el("span", { class: "grow" }),
        button("Cancel", api.closeEditor),
      ),
    );
    $("notes-placeholder").hidden = true;
    $("notes-editor").hidden = true;
    pane.hidden = false;
    s.mergeOpen = true;
    view.classList.add("note-editing");
    deps.syncBack();
  }

  Object.assign(api, { openMerge });
}
