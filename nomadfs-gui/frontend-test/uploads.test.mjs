import test from "node:test";
import assert from "node:assert/strict";
import { CHUNK, toBase64, joinPath, splitPath, planUpload, progressText, uploadedText, readDrop, sendUpload } from "../frontend/uploads.js";

const fakeFile = (name, size, lastModified = 1700000000000) => ({
  name,
  size,
  lastModified,
  slice: (a, b) => ({ arrayBuffer: async () => new Uint8Array(Math.max(0, Math.min(b, size) - a)).fill(65).buffer }),
});

test("toBase64 matches Buffer's, across its 32 KiB slices", () => {
  const bytes = new Uint8Array(100000).map((_, i) => i * 7);
  assert.equal(toBase64(bytes), Buffer.from(bytes).toString("base64"));
  assert.equal(toBase64(new Uint8Array(0)), "");
});

test("joinPath and splitPath", () => {
  assert.equal(joinPath("", "a.jpg"), "a.jpg");
  assert.equal(joinPath("Photos", "Trip/a.jpg"), "Photos/Trip/a.jpg");
  assert.equal(joinPath("Photos", "../x/./a"), "Photos/x/a");
  assert.deepEqual(splitPath("a/b/c"), { dir: "a/b", name: "c" });
  assert.deepEqual(splitPath("c"), { dir: "", name: "c" });
});

test("planUpload: files go under the folder they were dropped in, folders parents first", () => {
  const a = fakeFile("a.jpg", 10);
  const b = fakeFile("b.jpg", 5);
  const plan = planUpload("Photos", [{ file: a, rel: "Trip/day 1/a.jpg" }, { file: b, rel: "b.jpg" }], ["Trip/day 1", "Trip", "Trip/empty"]);
  assert.deepEqual(plan.folders, ["Photos/Trip", "Photos/Trip/day 1", "Photos/Trip/empty"]);
  assert.deepEqual(plan.files.map((f) => [f.dir, f.name]), [["Photos/Trip/day 1", "a.jpg"], ["Photos", "b.jpg"]]);
  assert.equal(plan.bytes, 15);
  assert.deepEqual(planUpload("", [{ file: b, rel: "" }]).files.map((f) => [f.dir, f.name]), [["", "b.jpg"]]);
});

test("progressText and uploadedText", () => {
  assert.equal(progressText({ index: 2, total: 12, name: "p.jpg", sent: 45, bytes: 100 }), "Uploading 3 of 12 · p.jpg · 45%");
  assert.equal(progressText({ index: 0, total: 1, name: "p.jpg", sent: 0, bytes: 0 }), "Uploading · p.jpg · 100%");
  assert.equal(uploadedText(3, []), "Added 3 files");
  assert.equal(uploadedText(1, [{ name: "x", error: "Error: NoSpaceLeft" }]), "Added 1 file · 1 file failed (x: Error: NoSpaceLeft)");
  assert.equal(uploadedText(0, [], true), "cancelled");
});

test("readDrop walks dropped folders, batch by batch, and keeps plain files", async () => {
  const file = (name) => ({ isFile: true, isDirectory: false, name, file: (ok) => ok(fakeFile(name, 1)) });
  const dir = (name, children) => ({
    isFile: false, isDirectory: true, name,
    createReader: () => {
      const batches = [children.slice(0, 1), children.slice(1), []];
      return { readEntries: (ok) => ok(batches.shift()) };
    },
  });
  const tree = dir("Trip", [file("a.jpg"), dir("day 1", [file("b.jpg")]), dir("empty", [])]);
  const plain = fakeFile("loose.txt", 3);
  const dt = { items: [
    { kind: "file", webkitGetAsEntry: () => tree },
    { kind: "file", getAsFile: () => plain },
    { kind: "string" },
  ] };
  const { files, dirs } = await readDrop(dt);
  assert.deepEqual(files.map((f) => f.rel).sort(), ["Trip/a.jpg", "Trip/day 1/b.jpg", "loose.txt"]);
  assert.equal(dirs[0], "Trip"); // parents first
  assert.deepEqual([...dirs].sort(), ["Trip", "Trip/day 1", "Trip/empty"]);
  // No items (an old web view): the plain file list.
  const old = await readDrop({ files: [plain] });
  assert.deepEqual(old.files.map((f) => f.rel), ["loose.txt"]);
});

test("sendUpload: folders, then each file in pieces; a failure is counted and the rest go on", async () => {
  const calls = [];
  let next = 1;
  const invoke = async (cmd, args) => {
    calls.push([cmd, args]);
    if (cmd === "swarm_upload_begin") {
      if (args.name === "bad.bin") throw new Error("InvalidName");
      return next++;
    }
    return null;
  };
  const big = fakeFile("big.bin", CHUNK + 10);
  const plan = planUpload("", [{ file: big, rel: "Dir/big.bin" }, { file: fakeFile("bad.bin", 1), rel: "bad.bin" }, { file: fakeFile("e", 0), rel: "e" }], ["Dir"]);
  const progress = [];
  const res = await sendUpload(invoke, plan, { onProgress: (p) => progress.push(p.sent) });
  assert.equal(res.done, 2);
  assert.deepEqual(res.failed.map((f) => f.name), ["bad.bin"]);
  assert.deepEqual(calls[0], ["swarm_mkdir", { dir: "", name: "Dir" }]);
  const chunks = calls.filter(([c]) => c === "swarm_upload_chunk").map(([, a]) => [a.id, a.offset, Buffer.from(a.data, "base64").length]);
  assert.deepEqual(chunks, [[1, 0, CHUNK], [1, CHUNK, 10]]);
  assert.deepEqual(calls.filter(([c]) => c === "swarm_upload_finish").map(([, a]) => a.id), [1, 2]);
  assert.equal(calls.find(([c]) => c === "swarm_upload_begin")[1].mtime_ms, 1700000000000);
  assert.equal(progress.at(-1), CHUNK + 11);
});

test("sendUpload: cancelling between pieces drops the open upload", async () => {
  const calls = [];
  let stop = false;
  const invoke = async (cmd, args) => {
    calls.push(cmd);
    if (cmd === "swarm_upload_chunk") stop = true;
    return cmd === "swarm_upload_begin" ? 7 : null;
  };
  const plan = planUpload("", [{ file: fakeFile("big", CHUNK * 3), rel: "big" }, { file: fakeFile("next", 1), rel: "next" }]);
  const res = await sendUpload(invoke, plan, { cancelled: () => stop });
  assert.equal(res.cancelled, true);
  assert.equal(res.done, 0);
  assert.deepEqual(calls, ["swarm_upload_begin", "swarm_upload_chunk", "swarm_upload_cancel"]);
});
