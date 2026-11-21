import test from "node:test";
import assert from "node:assert/strict";
import { CHUNK, toBase64, joinPath, splitPath, planUpload, progressText, uploadedText, folderAddedText, readDrop, sendUpload } from "../frontend/uploads.js";

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
  assert.equal(progressText({ index: 1, total: 3, name: "p.jpg", sent: 10, bytes: 100, waiting: true }), "Waiting for swarm to sync 2 of 3 · p.jpg");
  assert.equal(progressText({ index: 0, total: 1, name: "p.jpg", sent: 10, bytes: 100, waiting: true }), "Waiting for swarm to sync · p.jpg");
  assert.equal(uploadedText(3, []), "Added 3 files");
  assert.equal(uploadedText(0, [], false, 0, "", { folders: 1 }), "Added 1 folder");
  assert.equal(uploadedText(0, [], false, 0, "", { folders: 2 }), "Added 2 folders");
  assert.equal(uploadedText(3, [], false, 0, "", { folders: 2 }), "Added 3 files and 2 folders");
  assert.equal(uploadedText(1, [], false, 0, "", { folders: 1 }), "Added 1 file and 1 folder");
  assert.equal(uploadedText(1, [{ name: "x", error: "Error: NoSpaceLeft" }]), "Added 1 file · 1 file failed (x: Error: NoSpaceLeft)");
  assert.equal(
    uploadedText(0, [], false, 2, "", {
      failedFolders: [
        { name: "Bad1", error: "Error: NotADirectory" },
        { name: "Bad2", error: "Error: InvalidPath" },
      ],
    }),
    "2 folders failed (Bad1: Error: NotADirectory) · 2 skipped",
  );
  assert.equal(
    uploadedText(1, [{ name: "f.jpg", error: "Error: NoSpaceLeft" }], false, 0, "", {
      failedFolders: [{ name: "Bad", error: "Error: NotADirectory" }],
    }),
    "Added 1 file · 1 file failed (f.jpg: Error: NoSpaceLeft) · 1 folder failed (Bad: Error: NotADirectory)",
  );
  assert.equal(uploadedText(0, [], true), "cancelled");
  assert.equal(uploadedText(0, [], true, 0, "", { cancelReason: "Stopped: NomadFS restarted" }), "Stopped: NomadFS restarted");
  assert.equal(uploadedText(2, [], true, 0, "", { folders: 1, cancelReason: "Stopped: NomadFS restarted" }), "Added 2 files and 1 folder · Stopped: NomadFS restarted");
  assert.equal(uploadedText(2, [], false, 3, "NotReadableError"), "Added 2 files · 3 skipped (NotReadableError)");
  assert.equal(uploadedText(0, [], false, 1), "1 skipped");
  assert.equal(uploadedText(0, []), "Nothing to add");
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
  const { files, dirs, skipped, skipReason } = await readDrop(dt);
  assert.deepEqual(files.map((f) => f.rel).sort(), ["Trip/a.jpg", "Trip/day 1/b.jpg", "loose.txt"]);
  assert.equal(dirs[0], "Trip"); // parents first
  assert.deepEqual([...dirs].sort(), ["Trip", "Trip/day 1", "Trip/empty"]);
  assert.equal(skipped, 0);
  assert.equal(skipReason, "");
  // No items (an old web view): the plain file list.
  const old = await readDrop({ files: [plain] });
  assert.deepEqual(old.files.map((f) => f.rel), ["loose.txt"]);
  assert.equal(old.skipped, 0);
});

test("readDrop counts unreadable files, unreadable folders, and too-deep folders (depth >= 32) with first reason", async () => {
  const okFile = (name) => ({ isFile: true, isDirectory: false, name, file: (ok) => ok(fakeFile(name, 1)) });
  const badFile = (name, err) => ({ isFile: true, isDirectory: false, name, file: (_ok, fail) => fail(err) });
  const badDir = (name, err) => ({
    isFile: false, isDirectory: true, name,
    createReader: () => ({ readEntries: (_ok, fail) => fail(err) }),
  });
  const dir = (name, children) => ({
    isFile: false, isDirectory: true, name,
    createReader: () => {
      let done = false;
      return {
        readEntries: (ok) => {
          const batch = done ? [] : children;
          done = true;
          ok(batch);
        },
      };
    },
  });
  // Root is depth 0, d0..d30 are depth 1..31 (allowed), leaf is depth 32 (skipped).
  let deep = dir("leaf", [okFile("lost.txt")]);
  for (let i = 30; i >= 0; i--) deep = dir(`d${i}`, [deep]);
  // Stack is LIFO, so put the first error last to be popped first.
  const root = dir("Root", [deep, badDir("Secret", "PermissionDenied"), okFile("good.jpg"), badFile("locked.jpg", "NotReadableError")]);
  const res = await readDrop({ items: [{ kind: "file", webkitGetAsEntry: () => root }] });
  assert.deepEqual(res.files.map((f) => f.rel), ["Root/good.jpg"]);
  assert.equal(res.dirs.includes("Root/Secret"), false);
  assert.equal(res.dirs.some((d) => d.endsWith("/d30")), true);
  assert.equal(res.dirs.some((d) => d.endsWith("/leaf")), false);
  assert.equal(res.skipped, 3);
  assert.equal(res.skipReason, "NotReadableError");

  // Depth 32 alone reports "too deeply nested" as skipReason.
  let onlyDeep = dir("leaf", [okFile("lost.txt")]);
  for (let i = 30; i >= 0; i--) onlyDeep = dir(`d${i}`, [onlyDeep]);
  const resDeep = await readDrop({ items: [{ kind: "file", webkitGetAsEntry: () => dir("Root", [onlyDeep]) }] });
  assert.equal(resDeep.skipped, 1);
  assert.equal(resDeep.skipReason, "too deeply nested");
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
  assert.equal(res.folders, 1);
  assert.deepEqual(res.failed.map((f) => f.name), ["bad.bin"]);
  assert.deepEqual(res.failedFolders, []);
  assert.equal(res.skipped, 0);
  assert.deepEqual(calls[0], ["swarm_mkdir", { dir: "", name: "Dir" }]);
  const chunks = calls.filter(([c]) => c === "swarm_upload_chunk").map(([, a]) => [a.id, a.offset, Buffer.from(a.data, "base64").length]);
  assert.deepEqual(chunks, [[1, 0, CHUNK], [1, CHUNK, 10]]);
  assert.deepEqual(calls.filter(([c]) => c === "swarm_upload_finish").map(([, a]) => a.id), [1, 2]);
  assert.equal(calls.find(([c]) => c === "swarm_upload_begin")[1].mtime_ms, 1700000000000);
  assert.equal(progress.at(-1), CHUNK + 11);
});

test("sendUpload: failing mkdir is recorded as folder failure and its folder's files are counted as skipped", async () => {
  const calls = [];
  let next = 1;
  const invoke = async (cmd, args) => {
    calls.push([cmd, args]);
    if (cmd === "swarm_mkdir" && args.name === "Bad") throw new Error("NotADirectory");
    if (cmd === "swarm_upload_begin") return next++;
    return null;
  };
  const plan = planUpload(
    "",
    [
      { file: fakeFile("a.txt", 10), rel: "Bad/a.txt" },
      { file: fakeFile("b.txt", 10), rel: "Bad/Sub/b.txt" },
      { file: fakeFile("c.txt", 5), rel: "BadSibling/c.txt" },
      { file: fakeFile("d.txt", 5), rel: "Good/d.txt" },
    ],
    ["Bad", "Bad/Sub", "BadSibling", "Good"],
  );
  const res = await sendUpload(invoke, plan);
  assert.equal(res.done, 2);
  assert.equal(res.folders, 2);
  assert.equal(res.skipped, 3);
  assert.equal(res.cancelled, false);
  assert.deepEqual(res.failed, []);
  assert.deepEqual(res.failedFolders, [{ name: "Bad", error: "Error: NotADirectory" }]);
  const mkdirs = calls.filter(([c]) => c === "swarm_mkdir").map(([, a]) => (a.dir ? `${a.dir}/${a.name}` : a.name));
  assert.deepEqual(mkdirs, ["Bad", "BadSibling", "Good"]);
  const begins = calls.filter(([c]) => c === "swarm_upload_begin").map(([, a]) => `${a.dir}/${a.name}`);
  assert.deepEqual(begins, ["BadSibling/c.txt", "Good/d.txt"]);
  assert.equal(
    uploadedText(res.done, res.failed, res.cancelled, res.skipped, "", { folders: res.folders, failedFolders: res.failedFolders }),
    "Added 2 files and 2 folders · 1 folder failed (Bad: Error: NotADirectory) · 3 skipped",
  );
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

test("sendUpload: checks cancelled before mkdir and right before finish", async () => {
  // Cancel before second mkdir.
  const mkdirCalls = [];
  let stop = false;
  const invokeMkdir = async (cmd, args) => {
    mkdirCalls.push([cmd, args.name]);
    stop = true;
    return null;
  };
  const dirPlan = planUpload("", [{ file: fakeFile("a", 1), rel: "A/a" }], ["A", "B"]);
  const res1 = await sendUpload(invokeMkdir, dirPlan, { cancelled: () => stop });
  assert.equal(res1.cancelled, true);
  assert.equal(res1.folders, 1);
  assert.deepEqual(mkdirCalls, [["swarm_mkdir", "A"]]);

  // Cancel during the final (only) chunk: must cancel instead of calling finish.
  const finishCalls = [];
  stop = false;
  const invokeFinish = async (cmd) => {
    finishCalls.push(cmd);
    if (cmd === "swarm_upload_chunk") stop = true;
    return cmd === "swarm_upload_begin" ? 9 : null;
  };
  const filePlan = planUpload("", [{ file: fakeFile("small", 10), rel: "small" }]);
  const res2 = await sendUpload(invokeFinish, filePlan, { cancelled: () => stop });
  assert.equal(res2.cancelled, true);
  assert.equal(res2.done, 0);
  assert.deepEqual(finishCalls, ["swarm_upload_begin", "swarm_upload_chunk", "swarm_upload_cancel"]);
});

test("sendUpload: retries swarm_upload_finish on NotSynced up to 20 times", async () => {
  // Succeeds on 3rd attempt (after 2 NotSynced retries).
  let attempts = 0;
  const waits = [];
  const waitingEvents = [];
  const calls = [];
  const invokeOk = async (cmd) => {
    calls.push(cmd);
    if (cmd === "swarm_upload_begin") return 1;
    if (cmd === "swarm_upload_finish" && ++attempts <= 2) throw new Error("NotSynced");
    return null;
  };
  const plan = planUpload("", [{ file: fakeFile("a.jpg", 10), rel: "a.jpg" }]);
  const resOk = await sendUpload(invokeOk, plan, {
    wait: async (ms) => { waits.push(ms); },
    onProgress: (p) => { if (p.waiting) waitingEvents.push(p); },
  });
  assert.equal(resOk.done, 1);
  assert.deepEqual(resOk.failed, []);
  assert.deepEqual(waits, [3000, 3000]);
  assert.equal(waitingEvents.length, 2);
  assert.equal(calls.includes("swarm_upload_cancel"), false);

  // Exhausts all 20 retries -> fails and cancels the staged upload.
  let failAttempts = 0;
  const failWaits = [];
  const failCalls = [];
  const invokeFail = async (cmd) => {
    failCalls.push(cmd);
    if (cmd === "swarm_upload_begin") return 2;
    if (cmd === "swarm_upload_finish") { failAttempts++; throw new Error("NotSynced"); }
    return null;
  };
  const resFail = await sendUpload(invokeFail, plan, { wait: async (ms) => { failWaits.push(ms); } });
  assert.equal(resFail.done, 0);
  assert.equal(failAttempts, 21);
  assert.equal(failWaits.length, 20);
  assert.deepEqual(resFail.failed, [{ name: "a.jpg", error: "Error: NotSynced" }]);
  assert.equal(failCalls.at(-1), "swarm_upload_cancel");

  // Cancelling while waiting between NotSynced retries stops cleanly.
  let stop = false;
  const cancelCalls = [];
  const invokeCancel = async (cmd) => {
    cancelCalls.push(cmd);
    if (cmd === "swarm_upload_begin") return 3;
    if (cmd === "swarm_upload_finish") throw new Error("NotSynced");
    return null;
  };
  const resCancel = await sendUpload(invokeCancel, plan, {
    cancelled: () => stop,
    wait: async () => { stop = true; },
  });
  assert.equal(resCancel.cancelled, true);
  assert.equal(resCancel.done, 0);
  assert.deepEqual(cancelCalls, ["swarm_upload_begin", "swarm_upload_chunk", "swarm_upload_finish", "swarm_upload_cancel"]);
});

test("sendUpload: retries swarm_mkdir and swarm_upload_begin on NotSynced (J5)", async () => {
  // mkdir succeeds on 3rd attempt, begin succeeds on 2nd attempt.
  let mkdirTries = 0;
  let beginTries = 0;
  const waits = [];
  const waitingNames = [];
  const invoke = async (cmd) => {
    if (cmd === "swarm_mkdir" && ++mkdirTries <= 2) throw new Error("NotSynced");
    if (cmd === "swarm_upload_begin") {
      if (++beginTries <= 1) throw new Error("NotSynced");
      return 1;
    }
    return null;
  };
  const plan = planUpload("", [{ file: fakeFile("a.jpg", 5), rel: "Trip/a.jpg" }], ["Trip"]);
  const res = await sendUpload(invoke, plan, {
    wait: async (ms) => { waits.push(ms); },
    onProgress: (p) => { if (p.waiting) waitingNames.push(p.name); },
  });
  assert.equal(res.done, 1);
  assert.equal(res.folders, 1);
  assert.deepEqual(res.failed, []);
  assert.deepEqual(res.failedFolders, []);
  assert.deepEqual(waits, [3000, 3000, 3000]);
  assert.deepEqual(waitingNames, ["Trip", "Trip", "a.jpg"]);

  // Cancelling while waiting on swarm_mkdir stops cleanly.
  let stop = false;
  const resMkdirCancel = await sendUpload(
    async (cmd) => { if (cmd === "swarm_mkdir") throw new Error("NotSynced"); return null; },
    plan,
    { cancelled: () => stop, wait: async () => { stop = true; } },
  );
  assert.equal(resMkdirCancel.cancelled, true);
  assert.equal(resMkdirCancel.folders, 0);

  // Exhausting retries on swarm_upload_begin records failed file and does not call cancel.
  let beginFailTries = 0;
  const calls = [];
  const resBeginFail = await sendUpload(
    async (cmd) => {
      calls.push(cmd);
      if (cmd === "swarm_upload_begin") { beginFailTries++; throw new Error("NotSynced"); }
      return null;
    },
    planUpload("", [{ file: fakeFile("b.jpg", 5), rel: "b.jpg" }]),
    { wait: async () => {} },
  );
  assert.equal(beginFailTries, 21);
  assert.equal(resBeginFail.done, 0);
  assert.deepEqual(resBeginFail.failed, [{ name: "b.jpg", error: "Error: NotSynced" }]);
  assert.equal(calls.includes("swarm_upload_cancel"), false);

  // Cancelling while waiting on swarm_upload_begin stops cleanly without cancel.
  let stopBegin = false;
  const beginCancelCalls = [];
  const resBeginCancel = await sendUpload(
    async (cmd) => {
      beginCancelCalls.push(cmd);
      if (cmd === "swarm_upload_begin") throw new Error("NotSynced");
      return null;
    },
    planUpload("", [{ file: fakeFile("c.jpg", 5), rel: "c.jpg" }]),
    { cancelled: () => stopBegin, wait: async () => { stopBegin = true; } },
  );
  assert.equal(resBeginCancel.cancelled, true);
  assert.deepEqual(beginCancelCalls, ["swarm_upload_begin"]);
});

test("sendUpload: empty-folder-only drop reports created folders and preserves spaces (J5, U7)", async () => {
  const calls = [];
  const invoke = async (cmd, args) => {
    calls.push([cmd, args]);
    return cmd === "swarm_upload_begin" ? 1 : null;
  };
  const emptyPlan = planUpload("", [], [" Empty ", " Empty /Sub"]);
  const emptyRes = await sendUpload(invoke, emptyPlan);
  assert.equal(emptyRes.done, 0);
  assert.equal(emptyRes.folders, 2);
  assert.deepEqual(calls, [
    ["swarm_mkdir", { dir: "", name: " Empty " }],
    ["swarm_mkdir", { dir: " Empty ", name: "Sub" }],
  ]);
  assert.equal(
    uploadedText(emptyRes.done, emptyRes.failed, emptyRes.cancelled, emptyRes.skipped, "", {
      folders: emptyRes.folders,
      failedFolders: emptyRes.failedFolders,
    }),
    "Added 2 folders",
  );

  // Dropped folder with leading/trailing spaces passes exact name to both mkdir and upload_begin.
  calls.length = 0;
  const spacedPlan = planUpload("", [{ file: fakeFile("photo.jpg", 4), rel: " Trip /photo.jpg" }], [" Trip "]);
  const spacedRes = await sendUpload(invoke, spacedPlan);
  assert.equal(spacedRes.done, 1);
  assert.equal(spacedRes.folders, 1);
  assert.deepEqual(calls[0], ["swarm_mkdir", { dir: "", name: " Trip " }]);
  assert.equal(calls[1][0], "swarm_upload_begin");
  assert.equal(calls[1][1].dir, " Trip ");
  assert.equal(calls[1][1].name, "photo.jpg");
});

test("H7: mixed drop reports successful files and folders together and counts skipped subfolders", async () => {
  const invoke = async (cmd, args) => {
    if (cmd === "swarm_mkdir" && args.name === "Bad") throw new Error("NotADirectory");
    if (cmd === "swarm_upload_begin") return 1;
    return null;
  };
  const plan = planUpload(
    "",
    [{ file: fakeFile("ok.txt", 3), rel: "Good/ok.txt" }],
    ["Good", "Bad", "Bad/EmptyChild"],
  );
  const res = await sendUpload(invoke, plan);
  assert.equal(res.done, 1);
  assert.equal(res.folders, 1);
  assert.equal(res.skipped, 1);
  assert.deepEqual(res.failed, []);
  assert.deepEqual(res.failedFolders, [{ name: "Bad", error: "Error: NotADirectory" }]);
  assert.equal(
    uploadedText(res.done, res.failed, res.cancelled, res.skipped, "", {
      folders: res.folders,
      failedFolders: res.failedFolders,
    }),
    "Added 1 file and 1 folder · 1 folder failed (Bad: Error: NotADirectory) · 1 skipped",
  );
});

test("H8: folderAddedText explains stopped_by reason with partial counts", () => {
  assert.equal(
    folderAddedText({ files: 5, folders: 2, skipped: 0, cancelled: false, stopped_by: "none" }),
    "Added 5 files in 2 folders",
  );
  assert.equal(
    folderAddedText({ files: 1, folders: 1, skipped: 2, cancelled: false }),
    "Added 1 file in 1 folder · 2 items skipped",
  );
  assert.equal(
    folderAddedText({ files: 0, folders: 0, skipped: 0, cancelled: true, stopped_by: "none" }),
    "Stopped",
  );
  assert.equal(
    folderAddedText({ files: 3, folders: 1, skipped: 0, cancelled: true, stopped_by: "none" }),
    "Stopped · Added 3 files in 1 folder",
  );
  assert.equal(
    folderAddedText({ files: 3000, folders: 12, skipped: 0, cancelled: false, stopped_by: "storage_full" }),
    "Stopped: the store is full · Added 3000 files in 12 folders",
  );
  assert.equal(
    folderAddedText({ files: 0, folders: 0, skipped: 0, cancelled: false, stopped_by: "storage_full" }),
    "Stopped: the store is full",
  );
  assert.equal(
    folderAddedText({ files: 0, folders: 0, skipped: 0, cancelled: false, stopped_by: "not_synced" }),
    "Stopped: waiting for the swarm to sync",
  );
  assert.equal(
    folderAddedText({ files: 2, folders: 1, skipped: 0, cancelled: false, stopped_by: "not_synced" }),
    "Stopped: waiting for the swarm to sync · Added 2 files in 1 folder",
  );
  assert.equal(
    folderAddedText({ files: 10, folders: 2, skipped: 1, cancelled: false, stopped_by: "no_space" }),
    "Stopped: the disk is full · Added 10 files in 2 folders · 1 item skipped",
  );
  assert.equal(
    folderAddedText({ files: 0, folders: 0, skipped: 0, cancelled: false, stopped_by: "no_space" }),
    "Stopped: the disk is full",
  );
});

test("H6: sendUpload stops cleanly when cancelled flips during an in-flight failure or before chunk send", async () => {
  // In-flight mkdir fails because node stopped -> cancelled, not recorded as folder failure.
  let stop = false;
  const resMkdir = await sendUpload(
    async () => { stop = true; throw new Error("NotRunning"); },
    planUpload("", [{ file: fakeFile("a.txt", 4), rel: "Dir/a.txt" }], ["Dir"]),
    { cancelled: () => stop },
  );
  assert.equal(resMkdir.cancelled, true);
  assert.deepEqual(resMkdir.failedFolders, []);
  assert.deepEqual(resMkdir.failed, []);

  // Cancelled while reading a chunk from disk -> cancels open upload without sending chunk.
  stop = false;
  const calls = [];
  const slowFile = {
    name: "a.bin",
    size: 8,
    lastModified: 1700000000000,
    slice: () => ({ arrayBuffer: async () => { stop = true; return new Uint8Array(8).buffer; } }),
  };
  const resChunk = await sendUpload(
    async (cmd) => { calls.push(cmd); return cmd === "swarm_upload_begin" ? 42 : null; },
    planUpload("", [{ file: slowFile, rel: "a.bin" }]),
    { cancelled: () => stop },
  );
  assert.equal(resChunk.cancelled, true);
  assert.deepEqual(calls, ["swarm_upload_begin", "swarm_upload_cancel"]);
});

test("sendUpload: a given session tags mkdir and begin, none leaves them untagged", async () => {
  const run = async (opts) => {
    const calls = [];
    const invoke = async (cmd, args) => { calls.push([cmd, args]); return cmd === "swarm_upload_begin" ? 1 : null; };
    await sendUpload(invoke, planUpload("", [{ file: fakeFile("a", 1), rel: "D/a" }], ["D"]), opts);
    return calls;
  };
  const tagged = await run({ session: 0 });
  assert.equal(tagged.find(([c]) => c === "swarm_mkdir")[1].session, 0);
  assert.equal(tagged.find(([c]) => c === "swarm_upload_begin")[1].session, 0);
  const plain = await run({});
  assert.equal("session" in plain.find(([c]) => c === "swarm_mkdir")[1], false);
  assert.equal("session" in plain.find(([c]) => c === "swarm_upload_begin")[1], false);
});

test("sendUpload: a session refused as NotRunning stops the batch once, as a restart", async () => {
  const calls = [];
  const invoke = async (cmd) => {
    calls.push(cmd);
    if (cmd === "swarm_upload_begin") throw new Error("error.NotRunning");
    return null;
  };
  const files = [{ file: fakeFile("a", 1), rel: "a" }, { file: fakeFile("b", 1), rel: "b" }];
  const res = await sendUpload(invoke, planUpload("", files), { session: 3 });
  assert.equal(res.cancelled, true);
  assert.equal(res.restarted, true);
  assert.equal(res.failed.length, 0);
  assert.deepEqual(calls, ["swarm_upload_begin"]); // b is never tried
  // Without a session, NotRunning is an ordinary failure per file.
  const plain = await sendUpload(invoke, planUpload("", files), {});
  assert.equal(plain.cancelled, false);
  assert.equal(plain.failed.length, 2);
});

test("sendUpload: an upload lost mid-file to a restart stops the batch as a restart", async () => {
  const invoke = async (cmd) => {
    if (cmd === "swarm_upload_begin") return 9;
    if (cmd === "swarm_upload_chunk") throw new Error("error.UploadNotFound");
    return null;
  };
  const files = [{ file: fakeFile("a", 3), rel: "a" }, { file: fakeFile("b", 1), rel: "b" }];
  const res = await sendUpload(invoke, planUpload("", files), { session: 2 });
  assert.equal(res.restarted, true);
  assert.equal(res.failed.length, 0);
});
