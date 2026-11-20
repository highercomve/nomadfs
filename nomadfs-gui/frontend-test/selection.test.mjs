import test from "node:test";
import assert from "node:assert/strict";
import { Selection, rangeBetween, chunk, deleteCopy, deleteMany, deletedText } from "../frontend/selection.js";

test("Selection: toggle starts select mode, leave forgets everything", () => {
  let changes = 0;
  const sel = new Selection(() => changes++);
  assert.equal(sel.active, false);
  assert.equal(sel.toggle("a", { dir: true }), true);
  assert.equal(sel.active, true);
  assert.equal(sel.anchor, "a");
  assert.equal(sel.toggle("b"), true);
  assert.equal(sel.toggle("a"), false);
  assert.deepEqual(sel.keys(), ["b"]);
  assert.equal(sel.size, 1);
  assert.equal(changes, 3);
  sel.leave();
  assert.equal(sel.active, false);
  assert.equal(sel.size, 0);
  assert.equal(sel.anchor, null);
  assert.equal(changes, 4);
  sel.leave(); // already out: no change to draw
  assert.equal(changes, 4);
});

test("Selection: enter selects nothing; values keep what was given", () => {
  const sel = new Selection();
  sel.enter();
  assert.equal(sel.active, true);
  assert.equal(sel.size, 0);
  sel.setMany([["x", { dir: true }], ["y", { dir: false }]]);
  assert.deepEqual(sel.values(), [{ dir: true }, { dir: false }]);
  sel.setMany([["x", null]], false);
  assert.deepEqual(sel.keys(), ["y"]);
});

test("Selection: hasAll needs every key, and at least one", () => {
  const sel = new Selection();
  sel.setMany([["a", 1], ["b", 1]]);
  assert.equal(sel.hasAll(["a", "b"]), true);
  assert.equal(sel.hasAll(["a", "c"]), false);
  assert.equal(sel.hasAll([]), false);
});

test("Selection: retain drops what is gone, and the anchor with it", () => {
  let changes = 0;
  const sel = new Selection(() => changes++);
  sel.toggle("a");
  sel.toggle("b");
  changes = 0;
  sel.retain(new Set(["a", "b", "c"]));
  assert.equal(changes, 0);
  sel.retain(new Set(["a"]));
  assert.deepEqual(sel.keys(), ["a"]);
  assert.equal(sel.anchor, null);
  assert.equal(sel.active, true);
  assert.equal(changes, 1);
});

test("rangeBetween: both ends, either direction, no anchor", () => {
  const keys = ["a", "b", "c", "d", "e"];
  assert.deepEqual(rangeBetween(keys, "b", "d"), ["b", "c", "d"]);
  assert.deepEqual(rangeBetween(keys, "d", "b"), ["b", "c", "d"]);
  assert.deepEqual(rangeBetween(keys, "c", "c"), ["c"]);
  assert.deepEqual(rangeBetween(keys, null, "c"), ["c"]);
  assert.deepEqual(rangeBetween(keys, "gone", "c"), ["c"]);
  assert.deepEqual(rangeBetween(keys, "a", "gone"), []);
});

test("chunk: batches of a size, the rest last", () => {
  assert.deepEqual(chunk([], 3), []);
  assert.deepEqual(chunk([1, 2, 3], 3), [[1, 2, 3]]);
  assert.deepEqual(chunk([1, 2, 3, 4, 5, 6, 7], 3), [[1, 2, 3], [4, 5, 6], [7]]);
});

test("deleteCopy: counts, folders and the photos' wording", () => {
  assert.deepEqual(deleteCopy(12), { title: "Delete 12 items?", text: "They disappear from every device." });
  assert.deepEqual(deleteCopy(1), { title: "Delete 1 item?", text: "It disappears from every device." });
  assert.deepEqual(deleteCopy(3, { folders: 1 }), {
    title: "Delete 3 items?",
    text: "The folder is deleted with everything in it. They disappear from every device.",
  });
  assert.deepEqual(deleteCopy(3, { folders: 2 }), {
    title: "Delete 3 items?",
    text: "Folders are deleted with everything in them. They disappear from every device.",
  });
  assert.deepEqual(deleteCopy(37, { noun: ["photo or video", "photos and videos"] }), {
    title: "Delete 37 photos and videos?",
    text: "They disappear from every device.",
  });
  assert.equal(deleteCopy(1, { noun: ["photo or video", "photos and videos"] }).title, "Delete 1 photo or video?");
});

test("deleteMany: one call per batch, the counts add up", async () => {
  const calls = [];
  const progress = [];
  const invoke = async (cmd, args) => { calls.push([cmd, args.paths.length]); return args.paths.length - 1; };
  const paths = Array.from({ length: 1200 }, (_, i) => `p/${i}`);
  const res = await deleteMany(invoke, paths, { size: 500, onProgress: (sent, total) => progress.push([sent, total]) });
  assert.deepEqual(calls, [["swarm_delete_many", 500], ["swarm_delete_many", 500], ["swarm_delete_many", 200]]);
  assert.deepEqual(progress, [[0, 1200], [500, 1200], [1000, 1200]]);
  assert.deepEqual(res, { deleted: 1197, error: null });
  assert.equal(deletedText(res), "Deleted 1197");
});

test("deleteMany: stops at the batch that fails and says how far it got", async () => {
  let n = 0;
  const invoke = async (_cmd, args) => { if (++n === 2) throw "NodeStopped"; return args.paths.length; };
  const res = await deleteMany(invoke, ["a", "b", "c", "d", "e"], { size: 2 });
  assert.equal(n, 2);
  assert.deepEqual(res, { deleted: 2, error: "NodeStopped" });
  assert.equal(deletedText(res), "Deleted 2, then it failed: NodeStopped");
  assert.equal(deletedText({ deleted: 0, error: "NodeStopped" }), "Delete failed: NodeStopped");
});
