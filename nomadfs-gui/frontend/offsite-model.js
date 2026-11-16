// ---- Offsite backup: what the settings card shows (pure; offsite.js renders it) ----
//
// The provider presets of the "Add a backup bucket" form, the sentence for
// each error the core names, what a target's row says, and the "type three
// of the words back" check. No DOM and no clock of its own: tests run it in Node.

const plural = (n, word) => `${n} ${word}${n === 1 ? "" : "s"}`;

/** The providers the form offers; `fields` are the inputs each one needs
 *  besides the bucket and the two keys. */
export const PROVIDERS = [
  { id: "r2", label: "Cloudflare R2", fields: ["account"], schedule: "daily", help: "" },
  { id: "aws", label: "AWS S3", fields: ["region"], schedule: "daily", help: "" },
  {
    id: "deep",
    label: "AWS Glacier Deep Archive",
    fields: ["region"],
    schedule: "weekly",
    help: "About $1 per TB a month. Restores take 12–48 hours, so keep a second, faster bucket for everyday restores. Needs Deep backup on this device.",
  },
  { id: "other", label: "Other S3-compatible", fields: ["endpoint", "region"], schedule: "daily", help: "" },
];

export const provider = (id) => PROVIDERS.find((p) => p.id === id) || PROVIDERS[0];

const trimmed = (v) => String(v ?? "").trim();

/**
 * The form as the settings `offsite_add` takes, or the first thing wrong
 * with it: `{ ok: true, config }` or `{ ok: false, field, message }`.
 * `form`: { provider, account, region, endpoint, bucket, prefix,
 * access_key_id, secret_access_key, encrypt, schedule }.
 */
export function presetConfig(form) {
  const p = provider(form?.provider);
  const bad = (field, message) => ({ ok: false, field, message });
  const account = trimmed(form.account);
  const region = trimmed(form.region);
  let endpoint = trimmed(form.endpoint);
  let regionOut = region;
  if (p.id === "r2") {
    // The id alone, or the whole address pasted from the dashboard.
    const id = account.replace(/^https?:\/\//, "").replace(/\.r2\.cloudflarestorage\.com.*$/, "");
    if (!/^[a-z0-9]{8,64}$/i.test(id)) return bad("account", "Enter your Cloudflare account ID: the letters and digits in the R2 dashboard address.");
    endpoint = `https://${id.toLowerCase()}.r2.cloudflarestorage.com`;
    regionOut = "auto";
  } else if (p.id === "aws" || p.id === "deep") {
    if (!/^[a-z]{2}(-[a-z]+)+-\d+$/.test(region)) return bad("region", "Enter the bucket's AWS region, like eu-west-1.");
    endpoint = `https://s3.${region}.amazonaws.com`;
  } else {
    if (!/^https?:\/\/[^\s/.][^\s]*$/.test(endpoint)) return bad("endpoint", "Enter the full endpoint address, starting with https://.");
    endpoint = endpoint.replace(/\/+$/, "");
    if (/\s/.test(region)) return bad("region", "A region has no spaces. Leave it empty if your provider has none.");
  }
  const bucket = trimmed(form.bucket);
  if (!bucket) return bad("bucket", "Enter the bucket's name.");
  if (/[\s/"\\]/.test(bucket)) return bad("bucket", "A bucket name has no spaces or slashes.");
  const prefix = trimmed(form.prefix).replace(/^\/+/, "").replace(/\/+$/, "");
  if (/["\\]/.test(prefix)) return bad("prefix", "A folder name can't have quotes or backslashes.");
  const keyId = trimmed(form.access_key_id);
  const secret = trimmed(form.secret_access_key);
  if (!keyId || /[\s"\\]/.test(keyId)) return bad("access_key_id", "Enter the access key ID your provider gave you.");
  if (!secret || /[\s"\\]/.test(secret)) return bad("secret_access_key", "Enter the secret access key. It is saved in a private file on this device, never in the settings file.");
  const schedule = ["daily", "weekly", "monthly"].includes(form.schedule) ? form.schedule : p.schedule;
  return {
    ok: true,
    config: {
      endpoint,
      region: regionOut,
      bucket,
      prefix,
      storage_class: p.id === "deep" ? "DEEP_ARCHIVE" : "",
      schedule,
      encrypt: form.encrypt !== false,
      access_key_id: keyId,
      secret_access_key: secret,
    },
  };
}

/** "Cloudflare R2", "AWS Deep Archive"...: where a target goes, from its
 *  endpoint and storage class. */
export function providerLabel(target) {
  const host = String(target?.endpoint || "").replace(/^https?:\/\//, "").replace(/[/:].*$/, "");
  const cls = target?.storage_class || "STANDARD";
  const tier = { DEEP_ARCHIVE: "Deep Archive", GLACIER: "Glacier", GLACIER_IR: "Glacier Instant Retrieval", STANDARD_IA: "Infrequent Access" }[cls];
  if (host.endsWith(".r2.cloudflarestorage.com")) return "Cloudflare R2";
  if (host.endsWith(".amazonaws.com")) return tier ? `AWS ${tier}` : "AWS S3";
  if (host.endsWith(".backblazeb2.com")) return "Backblaze B2";
  if (host.endsWith(".digitaloceanspaces.com")) return "DigitalOcean Spaces";
  if (host.endsWith(".wasabisys.com")) return "Wasabi";
  const name = host || "S3-compatible";
  return tier ? `${name} (${tier})` : name;
}

const SCHEDULES = { daily: "Every day", weekly: "Every week", monthly: "Every month" };
export const scheduleLabel = (s) => SCHEDULES[s] || "Every day";

/** What went wrong, and what to do about it, for an error the core names. */
const FAILURES = {
  BucketVersioningEnabled: "The bucket has versioning on, so deleted backup data would never really go. Turn versioning off in your provider's console, or use a bucket without it.",
  InsecureCredentials: "Other accounts on this computer can read the file with this bucket's keys. Make it private (chmod 600), or remove the bucket here and add it again.",
  InvalidCredentials: "The file with this bucket's keys is damaged. Remove the bucket here and add it again with its keys.",
  FileNotFound: "The file with this bucket's keys is missing. Remove the bucket here and add it again with its keys.",
  AccessDenied: "The provider refused the keys. Check the access key ID and the secret, and that the key may read, write and delete in this bucket.",
  LeaseHeld: "Another device is uploading to this bucket right now. Try again when it has finished: only one device writes at a time.",
  LeaseLost: "Another device took over the upload. This one stops and tries again on its next look.",
  DeepBackupOff: "An archive bucket takes the whole swarm backup. Turn on Deep backup above, then back up again.",
  NotRunning: "The node isn't running. Start it, then try again.",
  BackupNotConfigured: "The node doesn't know this bucket yet. Stop and start the node, then try again.",
  UnknownBackupTarget: "The node doesn't know this bucket yet. Stop and start the node, then try again.",
  NotFound: "This bucket holds no backup yet. The first upload creates it, and the recovery words with it.",
  RecoveryPhraseRequired: "This device has no key for this backup yet. It gets one on the next upload from a device that already has it.",
  EncryptionModeMismatch: "The bucket already holds a backup made with the other encryption setting. Remove the bucket here and add it again with the setting it was made with.",
  KeyIdMismatch: "The key this device holds doesn't open this backup. The bucket was set up again by another device: remove it here and add it again.",
  UnsupportedBackupVersion: "The bucket holds a backup from another version of NomadFS. Update this device, or use an empty bucket.",
  Cancelled: "The upload was stopped. It continues on the node's next look.",
  NetworkFailure: "The provider couldn't be reached. Check the internet connection and the endpoint address.",
  TlsFailure: "A secure connection to the provider failed. Check the endpoint address and this computer's clock.",
  Throttled: "The provider asked to slow down. It is tried again on the node's next look.",
  ServiceUnavailable: "The provider is having trouble right now. It is tried again on the node's next look.",
  InvalidEndpoint: "The endpoint isn't a full address. It starts with https://, like https://s3.eu-west-1.amazonaws.com.",
  InvalidBucket: "The bucket name is empty or has a character a bucket can't have.",
  InvalidRegion: "The region has a character a region can't have.",
  InvalidPrefix: "The folder inside the bucket can't start with a slash or have quotes.",
  InvalidAccessKey: "The access key ID is empty or has a space in it.",
  InvalidSecretKey: "The secret access key is empty or has a space in it.",
  InvalidStorageClass: "This storage class isn't one NomadFS knows.",
  InvalidSchedule: "The schedule is daily, weekly or monthly.",
  BackupTargetExists: "A backup bucket of that name is already set up.",
  BackupTargetDuplicate: "This bucket and folder are already set up here. Use another bucket, or a folder inside it.",
  TooManyBackupTargets: "8 backup buckets are already set up. Remove one first.",
  ConfigInvalid: "The settings file can't be read. Check it for a line added by hand.",
  PackMissing: "A part of the backup is missing from the bucket. Back up again; if it stays, the bucket lost data.",
  PackTruncated: "A part of the backup in the bucket is shorter than it should be. Back up again; if it stays, the bucket lost data.",
  BlockNotFound: "A snapshot names a block the backup doesn't hold. Back up again so it is uploaded.",
  Unsupported: "Offsite backup runs on computers, not on phones.",
};

export const errorName = (err) => String(err?.message ?? err ?? "").replace(/^Error:\s*/, "").trim();

/** One sentence for an error (its name, or what `invoke` threw). */
export function failureText(err) {
  const name = errorName(err);
  if (!name) return "";
  return FAILURES[name] || `It failed (${name}). It is tried again on the node's next look.`;
}

/** "just now", "5 min ago", "3 h ago", "2 days ago", then the date. Both in seconds. */
export function relativeTime(then, now) {
  const s = Math.max(0, now - then);
  if (s < 60) return "just now";
  const m = Math.round(s / 60);
  if (m < 60) return `${m} min ago`;
  const h = Math.round(m / 60);
  if (h < 24) return `${h} h ago`;
  const d = Math.round(h / 24);
  if (d < 14) return plural(d, "day") + " ago";
  return `on ${dayText(then)}`;
}

/** "14 Nov 2026" for a Unix time (UTC, as the core dates packs). */
export function dayText(seconds) {
  const d = new Date(seconds * 1000);
  const month = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][d.getUTCMonth()];
  return `${d.getUTCDate()} ${month} ${d.getUTCFullYear()}`;
}

/** The gate's line ("not uploading: this device is not a swarm backup") as a sentence. */
function gateText(target) {
  const why = String(target.not_uploading || "").replace(/^not uploading:\s*/, "");
  if (!why) return "";
  if (/deep backup/.test(why)) return "Not uploading: an archive bucket needs Deep backup on this device. Turn it on above.";
  if (/swarm backup/.test(why)) return "Not uploading on its own: this device is not a swarm backup. Turn on \"Back up the swarm here\" above, or use Back up now.";
  return `Not uploading: ${why}.`;
}

/**
 * One target's row for an `offsite_status` answer.
 * `ctx`: { running (the node runs), now (Unix seconds), busy ("run" |
 * "check" | "words" | "remove" | "" : what this page is doing with it) }.
 * Returns the headline, the "where and when" line, the state line, the
 * notes under it (`kind`: "warn" | "error" | "info") and which buttons work.
 */
export function targetView(target, ctx = {}) {
  const now = ctx.now ?? 0;
  const busy = ctx.busy || "";
  const uploading = !!target.running || !!target.requested || busy === "run";
  const where = [providerLabel(target), target.prefix ? `${target.bucket}/${target.prefix}` : target.bucket].filter(Boolean).join(" · ");
  const notes = [];

  let state;
  if (uploading) state = target.running ? "Uploading now…" : "Starting the upload…";
  else if (target.last_upload > 0) {
    const size = target.uploaded_blocks > 0 ? `, ${plural(target.uploaded_blocks, "new block")}` : ", nothing new to send";
    state = `Last upload ${relativeTime(target.last_upload, now)}${size}.`;
  } else if (!ctx.running) state = "Uploads start with the node.";
  else state = "No upload since the node started.";

  if (target.failure && !uploading) notes.push({ kind: "error", text: failureText(target.failure) });
  const gate = gateText(target);
  if (gate) notes.push({ kind: "warn", text: gate });
  if (target.waiting_files > 0) notes.push({ kind: "warn", text: `${plural(target.waiting_files, "file")} waiting for blocks: not in this snapshot yet. They go up once this device has all of each file.` });
  if (target.deferred_packs > 0) {
    const first = dayText(target.deferred_first);
    const last = dayText(target.deferred_last);
    const when = first === last ? `on ${first}` : `between ${first} and ${last}`;
    notes.push({ kind: "info", text: `${plural(target.deferred_packs, "pack")} of deleted files waiting for the minimum storage time: removed ${when}.` });
  }
  if (!target.encrypt) notes.push({ kind: "warn", text: "Not encrypted: the provider can read every file in this bucket." });
  else if (!target.words_confirmed) notes.push({ kind: "warn", text: "Recovery words not confirmed. Open Recovery words, write them down and confirm: without them the backup is lost with your devices." });
  if (target.reused_key && target.encrypt && !target.words_confirmed) notes.push({ kind: "info", text: "Opens with the same recovery words as your other backup bucket." });

  const idle = !busy && !uploading;
  return {
    name: target.name,
    where,
    schedule: scheduleLabel(target.schedule),
    snapshot: target.snapshot ? target.snapshot.replace(/^snapshots\//, "") : "",
    state,
    uploading,
    notes,
    canRun: idle && !!ctx.running && !/deep backup/.test(target.not_uploading || ""),
    canCheck: idle,
    canWords: idle && !!target.encrypt,
    canRemove: idle,
  };
}

/** The upload `offsite_run` started (`{ name, manual_runs }`) is over. */
export function runFinished(target, started) {
  return !!target && target.manual_runs > started.manual_runs;
}

/** What to say when that upload ended. */
export function runSummary(target) {
  if (target.failure) return { ok: false, text: failureText(target.failure) };
  const sent = target.uploaded_blocks > 0 ? `${plural(target.uploaded_blocks, "new block")} uploaded` : "Nothing new to upload";
  const waiting = target.waiting_files > 0 ? `; ${plural(target.waiting_files, "file")} waiting for blocks` : "";
  return { ok: true, text: `${sent}${waiting}.` };
}

/** The first upload made this target's key: its words are shown once, now. */
export function wordsDue(target) {
  return !!target && !!target.encrypt && !!target.new_key && !target.reused_key && !target.words_confirmed;
}

/** What "Check backup" found. */
export function checkSummary(check) {
  return `The bucket has ${plural(check.packs, "pack")}, ${check.packs === 1 ? "complete" : "each complete"}, and the index holds every block the snapshots name (${check.blocks}). Nothing was downloaded.`;
}

/** The check itself ran and found the backup damaged (not: it couldn't run). */
export function checkFailed(err) {
  return ["PackMissing", "PackTruncated", "BlockNotFound", "AuthenticationFailed", "InvalidIndex", "InvalidSnapshot"].includes(errorName(err));
}

// ---- The recovery words ----

/** The words of a phrase, in order. */
export const splitWords = (phrase) => String(phrase || "").trim().split(/\s+/).filter(Boolean);

/** `count` different positions (1-based, ascending) among `total` words;
 *  `random` is Math.random or a test's own. */
export function pickPositions(total = 24, count = 3, random = Math.random) {
  const left = Array.from({ length: total }, (_, i) => i + 1);
  const picked = [];
  while (picked.length < Math.min(count, total)) {
    const i = Math.min(left.length - 1, Math.floor(random() * left.length));
    picked.push(left.splice(i, 1)[0]);
  }
  return picked.sort((a, b) => a - b);
}

/** The positions answered wrong (empty: all right). Case and spaces around
 *  an answer don't count. */
export function wrongPositions(words, positions, answers) {
  return positions.filter((pos, i) => String(answers[i] ?? "").trim().toLowerCase() !== String(words[pos - 1] ?? "").toLowerCase());
}
