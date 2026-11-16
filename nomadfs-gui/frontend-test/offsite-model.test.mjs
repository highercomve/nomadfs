import test from "node:test";
import assert from "node:assert/strict";
import {
  PROVIDERS, presetConfig, providerLabel, scheduleLabel, failureText, errorName, relativeTime, dayText,
  targetView, runFinished, runSummary, wordsDue, checkSummary, checkFailed, splitWords, pickPositions, wrongPositions,
} from "../frontend/offsite-model.js";

const keys = { access_key_id: "AKIDEXAMPLE", secret_access_key: "s3cr3t/Key+" };
const target = (over = {}) => ({
  name: "s3", endpoint: "https://abc12345.r2.cloudflarestorage.com", bucket: "nomadfs-swarm", prefix: "", encrypt: true, words_confirmed: true,
  storage_class: "STANDARD", schedule: "daily", cold: false, uploading: true, not_uploading: "", running: false, requested: false, manual_runs: 0,
  last_upload: 0, snapshot: "", uploaded_blocks: 0, uploaded_bytes: 0, waiting_files: 0, new_key: false, reused_key: false, failure: "",
  deferred_packs: 0, deferred_first: 0, deferred_last: 0, ...over,
});

test("presetConfig: Cloudflare R2 builds the endpoint from the account id, region auto", () => {
  const made = presetConfig({ provider: "r2", account: " ABC12345def ", bucket: "nomadfs-swarm", ...keys });
  assert.equal(made.ok, true);
  assert.deepEqual(made.config, {
    endpoint: "https://abc12345def.r2.cloudflarestorage.com", region: "auto", bucket: "nomadfs-swarm", prefix: "",
    storage_class: "", schedule: "daily", encrypt: true, ...keys,
  });
  // The whole address pasted from the dashboard works too.
  assert.equal(presetConfig({ provider: "r2", account: "https://abc12345def.r2.cloudflarestorage.com/x", bucket: "b", ...keys }).config.endpoint, "https://abc12345def.r2.cloudflarestorage.com");
  const bad = presetConfig({ provider: "r2", account: "my account", bucket: "b", ...keys });
  assert.equal(bad.ok, false);
  assert.equal(bad.field, "account");
});

test("presetConfig: AWS S3 builds the endpoint from the region", () => {
  const made = presetConfig({ provider: "aws", region: "eu-west-1", bucket: "b", prefix: "/home/", schedule: "monthly", ...keys });
  assert.equal(made.config.endpoint, "https://s3.eu-west-1.amazonaws.com");
  assert.equal(made.config.region, "eu-west-1");
  assert.equal(made.config.storage_class, "");
  assert.equal(made.config.prefix, "home");
  assert.equal(made.config.schedule, "monthly");
  assert.equal(presetConfig({ provider: "aws", region: "europe", bucket: "b", ...keys }).field, "region");
  assert.equal(presetConfig({ provider: "aws", region: "", bucket: "b", ...keys }).field, "region");
});

test("presetConfig: Glacier Deep Archive is AWS with the cold class, weekly, and says what it costs", () => {
  const made = presetConfig({ provider: "deep", region: "us-east-2", bucket: "nomadfs-archive", ...keys });
  assert.equal(made.config.endpoint, "https://s3.us-east-2.amazonaws.com");
  assert.equal(made.config.storage_class, "DEEP_ARCHIVE");
  assert.equal(made.config.schedule, "weekly");
  const deep = PROVIDERS.find((p) => p.id === "deep");
  assert.match(deep.help, /\$1 per TB a month/);
  assert.match(deep.help, /12–48 hours/);
});

test("presetConfig: another S3-compatible provider gives its own endpoint, region optional", () => {
  const made = presetConfig({ provider: "other", endpoint: "https://s3.us-west-004.backblazeb2.com/", region: "", bucket: "b", ...keys });
  assert.equal(made.config.endpoint, "https://s3.us-west-004.backblazeb2.com");
  assert.equal(made.config.region, "");
  assert.equal(presetConfig({ provider: "other", endpoint: "s3.example.com", bucket: "b", ...keys }).field, "endpoint");
  assert.equal(presetConfig({ provider: "other", endpoint: "http://127.0.0.1:9000", bucket: "b", ...keys }).ok, true);
});

test("presetConfig: bucket and keys are required, encryption is on unless turned off", () => {
  const base = { provider: "r2", account: "abc12345", bucket: "b", ...keys };
  assert.equal(presetConfig({ ...base, bucket: " " }).field, "bucket");
  assert.equal(presetConfig({ ...base, bucket: "a/b" }).field, "bucket");
  assert.equal(presetConfig({ ...base, access_key_id: "" }).field, "access_key_id");
  const noSecret = presetConfig({ ...base, secret_access_key: "" });
  assert.equal(noSecret.field, "secret_access_key");
  assert.match(noSecret.message, /private file/);
  assert.equal(presetConfig({ ...base, secret_access_key: "two words" }).field, "secret_access_key");
  assert.equal(presetConfig(base).config.encrypt, true);
  assert.equal(presetConfig({ ...base, encrypt: false }).config.encrypt, false);
  // An unknown provider is the first one, an unknown schedule the preset's.
  assert.equal(presetConfig({ ...base, provider: "nope", schedule: "hourly" }).config.schedule, "daily");
});

test("providerLabel: the provider and the tier, from the endpoint and the class", () => {
  assert.equal(providerLabel(target()), "Cloudflare R2");
  assert.equal(providerLabel({ endpoint: "https://s3.eu-west-1.amazonaws.com", storage_class: "STANDARD" }), "AWS S3");
  assert.equal(providerLabel({ endpoint: "https://s3.eu-west-1.amazonaws.com", storage_class: "DEEP_ARCHIVE" }), "AWS Deep Archive");
  assert.equal(providerLabel({ endpoint: "https://s3.eu-west-1.amazonaws.com", storage_class: "GLACIER" }), "AWS Glacier");
  assert.equal(providerLabel({ endpoint: "https://s3.us-west-004.backblazeb2.com", storage_class: "STANDARD" }), "Backblaze B2");
  assert.equal(providerLabel({ endpoint: "http://nas.local:9000/", storage_class: "STANDARD" }), "nas.local");
  assert.equal(providerLabel({ endpoint: "https://minio.example", storage_class: "GLACIER" }), "minio.example (Glacier)");
  assert.equal(providerLabel({}), "S3-compatible");
  assert.equal(scheduleLabel("weekly"), "Every week");
  assert.equal(scheduleLabel(undefined), "Every day");
});

test("failureText: each error the core names is a sentence saying what to do", () => {
  assert.match(failureText("BucketVersioningEnabled"), /Turn versioning off/);
  assert.match(failureText("InsecureCredentials"), /chmod 600/);
  assert.match(failureText("LeaseHeld"), /Another device is uploading/);
  assert.match(failureText("DeepBackupOff"), /Turn on Deep backup/);
  assert.match(failureText("AccessDenied"), /Check the access key ID/);
  assert.match(failureText("NotFound"), /no backup yet/);
  // What invoke throws: an Error, or its text.
  assert.equal(errorName(new Error("LeaseHeld")), "LeaseHeld");
  assert.equal(errorName("Error: NotRunning"), "NotRunning");
  assert.match(failureText(new Error("NotRunning")), /Start it/);
  // An error with no sentence of its own still says its name, never nothing.
  assert.match(failureText("SomethingNew"), /SomethingNew/);
  assert.equal(failureText(""), "");
  assert.equal(failureText(null), "");
  for (const name of ["BucketVersioningEnabled", "InsecureCredentials", "LeaseHeld", "DeepBackupOff", "InvalidEndpoint", "BackupTargetDuplicate"]) {
    assert.match(failureText(name), /^[A-Z0-9].*\.$/, name);
    assert.doesNotMatch(failureText(name), new RegExp(name), name);
  }
});

test("relativeTime and dayText", () => {
  const now = 1794000000;
  assert.equal(relativeTime(now - 5, now), "just now");
  assert.equal(relativeTime(now - 300, now), "5 min ago");
  assert.equal(relativeTime(now - 3 * 3600, now), "3 h ago");
  assert.equal(relativeTime(now - 86400, now), "1 day ago");
  assert.equal(relativeTime(now - 5 * 86400, now), "5 days ago");
  assert.equal(relativeTime(1700000000, now), "on 14 Nov 2023");
  assert.equal(relativeTime(now + 60, now), "just now");
  assert.equal(dayText(1700000000), "14 Nov 2023");
});

test("targetView: a healthy target says where it goes, when it last uploaded and its snapshot", () => {
  const now = 1794000000;
  const v = targetView(target({ last_upload: now - 600, uploaded_blocks: 12, snapshot: "snapshots/20261116T120000Z-ab12", prefix: "home" }), { running: true, now });
  assert.equal(v.name, "s3");
  assert.equal(v.where, "Cloudflare R2 · nomadfs-swarm/home");
  assert.equal(v.schedule, "Every day");
  assert.equal(v.state, "Last upload 10 min ago, 12 new blocks.");
  assert.equal(v.snapshot, "20261116T120000Z-ab12");
  assert.deepEqual(v.notes, []);
  assert.deepEqual([v.canRun, v.canCheck, v.canWords, v.canRemove, v.uploading], [true, true, true, true, false]);
  assert.equal(targetView(target({ last_upload: now - 600 }), { running: true, now }).state, "Last upload 10 min ago, nothing new to send.");
});

test("targetView: before any upload, with and without the node", () => {
  assert.equal(targetView(target(), { running: true, now: 1 }).state, "No upload since the node started.");
  const stopped = targetView(target(), { running: false, now: 1 });
  assert.equal(stopped.state, "Uploads start with the node.");
  assert.equal(stopped.canRun, false);
  assert.equal(stopped.canCheck, true);
});

test("targetView: why a target isn't uploading", () => {
  const warm = targetView(target({ uploading: false, not_uploading: "not uploading: this device is not a swarm backup" }), { running: true, now: 1 });
  assert.equal(warm.notes[0].kind, "warn");
  assert.match(warm.notes[0].text, /not a swarm backup/);
  assert.match(warm.notes[0].text, /Back up now/);
  assert.equal(warm.canRun, true); // a warm target uploads by hand without the role
  const cold = targetView(target({ name: "archive", cold: true, storage_class: "DEEP_ARCHIVE", uploading: false, not_uploading: "not uploading: an archive target needs deep backup on this device" }), { running: true, now: 1 });
  assert.match(cold.notes[0].text, /needs Deep backup/);
  assert.equal(cold.canRun, false);
});

test("targetView: waiting files, deferred packs and the last failure", () => {
  const v = targetView(target({
    failure: "LeaseHeld", waiting_files: 3, deferred_packs: 2, deferred_first: 1700000000, deferred_last: 1700000000 + 40 * 86400, last_upload: 5,
  }), { running: true, now: 10 });
  assert.deepEqual(v.notes.map((n) => n.kind), ["error", "warn", "info"]);
  assert.match(v.notes[0].text, /Another device is uploading/);
  assert.match(v.notes[1].text, /^3 files waiting for blocks/);
  assert.equal(v.notes[2].text, "2 packs of deleted files waiting for the minimum storage time: removed between 14 Nov 2023 and 24 Dec 2023.");
  const one = targetView(target({ waiting_files: 1, deferred_packs: 1, deferred_first: 1700000000, deferred_last: 1700000000 }), { running: true, now: 10 });
  assert.match(one.notes[0].text, /^1 file waiting/);
  assert.match(one.notes[1].text, /^1 pack of deleted files .* removed on 14 Nov 2023\.$/);
});

test("targetView: recovery words not confirmed, a shared key, and no encryption", () => {
  const unconfirmed = targetView(target({ words_confirmed: false }), { running: true, now: 1 });
  assert.equal(unconfirmed.notes.length, 1);
  assert.match(unconfirmed.notes[0].text, /^Recovery words not confirmed/);
  assert.equal(unconfirmed.notes[0].kind, "warn");
  const shared = targetView(target({ words_confirmed: false, reused_key: true }), { running: true, now: 1 });
  assert.match(shared.notes[1].text, /same recovery words/);
  const clear = targetView(target({ encrypt: false, words_confirmed: false }), { running: true, now: 1 });
  assert.equal(clear.notes.length, 1);
  assert.match(clear.notes[0].text, /^Not encrypted/);
  assert.equal(clear.canWords, false);
});

test("targetView: an upload under way, and what this page is doing, hold the buttons", () => {
  const up = targetView(target({ running: true, failure: "LeaseHeld" }), { running: true, now: 1 });
  assert.equal(up.state, "Uploading now…");
  assert.equal(up.uploading, true);
  assert.deepEqual(up.notes, []); // the old failure is being retried
  assert.deepEqual([up.canRun, up.canCheck, up.canWords, up.canRemove], [false, false, false, false]);
  assert.equal(targetView(target({ requested: true }), { running: true, now: 1 }).state, "Starting the upload…");
  assert.equal(targetView(target(), { running: true, now: 1, busy: "run" }).state, "Starting the upload…");
  const checking = targetView(target(), { running: true, now: 1, busy: "check" });
  assert.equal(checking.uploading, false);
  assert.deepEqual([checking.canRun, checking.canCheck, checking.canRemove], [false, false, false]);
});

test("runFinished, runSummary and wordsDue: the end of a run started here", () => {
  const started = { name: "s3", manual_runs: 2 };
  assert.equal(runFinished(target({ manual_runs: 2 }), started), false);
  assert.equal(runFinished(target({ manual_runs: 3 }), started), true);
  assert.equal(runFinished(undefined, started), false);
  assert.deepEqual(runSummary(target({ uploaded_blocks: 1 })), { ok: true, text: "1 new block uploaded." });
  assert.deepEqual(runSummary(target({ uploaded_blocks: 0, waiting_files: 2 })), { ok: true, text: "Nothing new to upload; 2 files waiting for blocks." });
  const failed = runSummary(target({ failure: "BucketVersioningEnabled" }));
  assert.equal(failed.ok, false);
  assert.match(failed.text, /versioning/);
  // The first upload made the key: its words are due, once.
  assert.equal(wordsDue(target({ new_key: true, words_confirmed: false })), true);
  assert.equal(wordsDue(target({ new_key: true, words_confirmed: true })), false);
  assert.equal(wordsDue(target({ new_key: true, reused_key: true, words_confirmed: false })), false);
  assert.equal(wordsDue(target({ new_key: true, encrypt: false, words_confirmed: false })), false);
  assert.equal(wordsDue(target({ new_key: false, words_confirmed: false })), false);
  assert.equal(checkSummary({ packs: 4, blocks: 9 }), "The bucket has 4 packs, each complete, and the index holds every block the snapshots name (9). Nothing was downloaded.");
  assert.match(checkSummary({ packs: 1, blocks: 2 }), /^The bucket has 1 pack, complete,/);
  // A damaged backup is a finding; an unreachable provider is not.
  assert.equal(checkFailed(new Error("PackTruncated")), true);
  assert.equal(checkFailed("NetworkFailure"), false);
});

test("pickPositions: three different positions in order, whatever the dice say", () => {
  const dice = (values) => { let i = 0; return () => values[i++ % values.length]; };
  assert.deepEqual(pickPositions(24, 3, dice([0, 0, 0])), [1, 2, 3]);
  assert.deepEqual(pickPositions(24, 3, dice([0.999, 0.999, 0.999])), [22, 23, 24]);
  assert.deepEqual(pickPositions(24, 3, dice([0.5, 0, 0.99])), [1, 13, 24]);
  assert.deepEqual(pickPositions(24, 3, () => 1), [22, 23, 24]); // a generator that returns 1 stays in range
  for (let n = 0; n < 200; n++) {
    const p = pickPositions();
    assert.equal(p.length, 3);
    assert.equal(new Set(p).size, 3);
    assert.ok(p[0] >= 1 && p[2] <= 24 && p[0] < p[1] && p[1] < p[2]);
  }
  assert.deepEqual(pickPositions(2, 3, () => 0), [1, 2]);
});

test("splitWords and wrongPositions: the words typed back", () => {
  const words = splitWords("  abandon ability able\nabout above absent  ");
  assert.deepEqual(words, ["abandon", "ability", "able", "about", "above", "absent"]);
  assert.deepEqual(splitWords(""), []);
  assert.deepEqual(wrongPositions(words, [1, 4, 6], ["abandon", "about", "absent"]), []);
  assert.deepEqual(wrongPositions(words, [1, 4, 6], [" Abandon ", "ABOUT", "absent"]), []);
  assert.deepEqual(wrongPositions(words, [1, 4, 6], ["abandon", "above", ""]), [4, 6]);
  assert.deepEqual(wrongPositions(words, [1, 4, 6], []), [1, 4, 6]);
  // A position past the end never passes on an empty answer.
  assert.deepEqual(wrongPositions(words, [7], ["x"]), [7]);
});
