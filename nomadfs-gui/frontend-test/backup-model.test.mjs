import test from "node:test";
import assert from "node:assert/strict";
import { deepBackupView } from "../frontend/backup-model.js";

test("deepBackupView: no archive target disables the switch with a reason", () => {
  const v = deepBackupView({ deep_backup: false, archive_target: false, running: true });
  assert.equal(v.checked, false);
  assert.equal(v.disabled, true);
  assert.match(v.text, /archive bucket/);
  assert.match(v.text, /Glacier Deep Archive bucket under Offsite backup/);
});

test("deepBackupView: on without an archive target can still be turned off, and says nothing is sent", () => {
  const v = deepBackupView({ deep_backup: true, archive_target: false, running: true });
  assert.equal(v.checked, true);
  assert.equal(v.disabled, false);
  assert.match(v.text, /^No archive bucket set up/);
});

test("deepBackupView: off with an archive target is a plain enabled switch", () => {
  assert.deepEqual(deepBackupView({ deep_backup: false, archive_target: true, running: true }), { checked: false, disabled: false, text: "" });
});

test("deepBackupView: the state line of a deep backup device", () => {
  const base = { deep_backup: true, archive_target: true, running: true, archive_last_upload: 0, archive_waiting: 0, archive_failed: false };
  assert.equal(deepBackupView({ ...base, running: false }).text, "Starts with the node.");
  assert.equal(deepBackupView(base).text, "Uploads on the archive target's schedule.");
  assert.match(deepBackupView({ ...base, archive_failed: true, archive_waiting: 2 }).text, /failed/);
  assert.equal(deepBackupView({ ...base, archive_waiting: 1, archive_last_upload: 1700000000 }).text, "1 file waiting for blocks; they go to the archive on a later run.");
  assert.match(deepBackupView({ ...base, archive_waiting: 3 }).text, /^3 files waiting for blocks/);
  assert.match(deepBackupView({ ...base, archive_last_upload: 1700000000 }).text, /^Sent to the archive on /);
  assert.equal(deepBackupView(base).checked, true);
});

test("deepBackupView: a missing answer is an off, disabled switch", () => {
  const v = deepBackupView(undefined);
  assert.equal(v.checked, false);
  assert.equal(v.disabled, true);
});
