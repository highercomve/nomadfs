// ---- Deep backup: what its switch shows (pure; shares.js renders it) ----

const plural = (n, word) => `${n} ${word}${n === 1 ? "" : "s"}`;

/**
 * The deep backup switch for a `swarm_backup_status` answer: whether it is
 * on, whether it can be changed, and one line of state. Without an archive
 * target it cannot be turned on (it can still be turned off).
 */
export function deepBackupView(st) {
  const on = !!st?.deep_backup;
  if (!st?.archive_target) {
    return {
      checked: on,
      disabled: !on,
      text: on
        ? "No archive bucket set up: nothing is sent to an archive. Add one under Offsite backup below."
        : "Needs an archive bucket: add an AWS Glacier Deep Archive bucket under Offsite backup below.",
    };
  }
  let text = "";
  if (on && !st.running) text = "Starts with the node.";
  else if (on && st.archive_failed) text = "The last upload to the archive failed; it is tried again.";
  else if (on && st.archive_waiting > 0) text = `${plural(st.archive_waiting, "file")} waiting for blocks; they go to the archive on a later run.`;
  else if (on && st.archive_last_upload > 0) text = `Sent to the archive on ${new Date(st.archive_last_upload * 1000).toLocaleDateString()}.`;
  else if (on) text = "Uploads on the archive target's schedule.";
  return { checked: on, disabled: false, text };
}
