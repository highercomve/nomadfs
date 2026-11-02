import test from "node:test";
import assert from "node:assert/strict";
import {
  groupNotes, noteLink, notebookLabel, otherFiles, parseNoteLink, plainSnippet, reason,
  relativeTime, sortNotebooks, visibleNotes,
} from "../frontend/notes-model.js";

const note = (path, extra = {}) => {
  const name = path.split("/").pop();
  return { path, title: name.replace(/\.[^.]+$/, ""), notebook: path.split("/").slice(1, -1).join("/"), mtime: 1000, pinned: false, conflict_of: null, editable: !name.endsWith(".png"), ...extra };
};

test("relative times", () => {
  const now = Date.UTC(2026, 10, 2, 12, 0, 0);
  const s = now / 1000;
  assert.equal(relativeTime(s - 5, now), "just now");
  assert.equal(relativeTime(s - 120, now), "2 min ago");
  assert.equal(relativeTime(s - 3 * 3600, now), "3 h ago");
  assert.equal(relativeTime(s - 30 * 3600, now), "yesterday");
  assert.equal(relativeTime(s - 40 * 86400, now, "en-US"), "Sep 23");
  assert.equal(relativeTime(s - 400 * 86400, now, "en-US"), "Sep 28, 2025");
  assert.equal(relativeTime(0, now), "");
  assert.equal(relativeTime(s + 100, now), "just now", "a clock ahead of ours is not the future");
});

test("filters: pinned, notebooks, titles, body hits", () => {
  const notes = [note("Notes/a.md", { pinned: true }), note("Notes/Work/b.md"), note("Notes/Work/Deep/c.md"), note("Notes/pic.png")];
  assert.deepEqual(visibleNotes(notes).map((n) => n.path), ["Notes/a.md", "Notes/Work/b.md", "Notes/Work/Deep/c.md"]);
  assert.deepEqual(visibleNotes(notes, { filter: "pinned" }).map((n) => n.path), ["Notes/a.md"]);
  assert.deepEqual(visibleNotes(notes, { filter: "nb:Work" }).map((n) => n.path), ["Notes/Work/b.md"]);
  assert.deepEqual(visibleNotes(notes, { query: " B " }).map((n) => n.path), ["Notes/Work/b.md"]);
  assert.deepEqual(visibleNotes(notes, { query: "zzz", bodyHits: new Set(["Notes/a.md"]) }).map((n) => n.path), ["Notes/a.md"]);
  assert.deepEqual(otherFiles(notes).map((n) => n.path), ["Notes/pic.png"]);
  assert.deepEqual(sortNotebooks(["Work/Deep", "Home", "Work"]), ["Home", "Work", "Work/Deep"]);
  assert.equal(notebookLabel("Work/Deep"), "Work / Deep");
});

test("a conflict copy is grouped under its note, wherever it sorts", () => {
  const notes = [
    note("Notes/Ideas (conflict from Pixel).md", { conflict_of: "Notes/Ideas.md", mtime: 900 }),
    note("Notes/Other.md", { mtime: 800 }),
    note("Notes/Ideas.md", { mtime: 700 }),
    note("Notes/Lost (conflict from Pixel).md", { conflict_of: null, mtime: 600 }),
  ];
  const rows = groupNotes(notes);
  assert.deepEqual(rows.map((r) => [r.note.path, r.copy]), [
    ["Notes/Other.md", false],
    ["Notes/Ideas.md", false],
    ["Notes/Ideas (conflict from Pixel).md", true],
    ["Notes/Lost (conflict from Pixel).md", false],
  ]);
  // The note filtered out: its copy is a row of its own.
  assert.deepEqual(groupNotes([notes[0]]).map((r) => r.copy), [false]);
});

test("note links round-trip and refuse anything else", () => {
  const path = "Notes/Work/Stand up #1 & more.md";
  const link = noteLink(path);
  assert.equal(link, "nomadfs://note/Notes/Work/Stand%20up%20%231%20%26%20more.md");
  assert.equal(parseNoteLink(link), path);
  assert.equal(parseNoteLink("NOMADFS://note/Notes/a.md"), "Notes/a.md");
  assert.equal(parseNoteLink("nomadfs://note/Other/a.md"), null, "only Notes/");
  assert.equal(parseNoteLink("nomadfs://note/Notes/../secret"), null);
  assert.equal(parseNoteLink("nomadfs://note/Notes/%E0%A4%A"), null, "bad escapes");
  assert.equal(parseNoteLink("https://note/Notes/a.md"), null);
  assert.equal(parseNoteLink("nomadfs://other/Notes/a.md"), null);
});

test("snippets lose their formatting marks", () => {
  assert.equal(plainSnippet("# Standup Yesterday: **relays** and `code`"), "Standup Yesterday: relays and code");
  assert.equal(plainSnippet("- [ ] milk - [x] eggs - bread"), "☐ milk ☑ eggs - bread");
  assert.equal(plainSnippet("- first item"), "• first item");
  assert.equal(plainSnippet("2 - 1 = 1"), "2 - 1 = 1");
});

test("error reasons are readable", () => {
  assert.equal(reason("NotSynced"), "still syncing with your other devices");
  assert.equal(reason(new Error("command failed: NotRunning")), "NomadFS isn't running");
  assert.equal(reason("PathAlreadyExists"), "a note with that title exists");
  assert.equal(reason("NotANote"), "that isn't a note");
  assert.equal(reason("SomethingElse"), "SomethingElse");
});
