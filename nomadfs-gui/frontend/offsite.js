// ---- Offsite backup (settings): the buckets, the add form, the recovery words ----
//
// Draws what offsite-model.js decides and sends each action to the core's
// backup service through the app's commands. Nothing here decides policy.

import { $, snack, svg, ICONS, copyText } from "./core.js";
import { askDialog } from "./overlays.js";
import { isRunning, ensureConfig } from "./state.js";
import {
  provider, presetConfig, targetView, failureText, runFinished, runSummary, wordsDue, checkSummary, checkFailed,
  splitWords, pickPositions, wrongPositions,
} from "./offsite-model.js";

const { invoke } = window.oriel;

/** What this page is doing with a target: name → "run" | "check" | "words" | "remove". */
const busy = new Map();
/** Uploads started here and not over yet: name → what `offsite_run` answered. */
const runs = new Map();
/** The last thing an action said, kept on the row: name → { kind, text }. */
const results = new Map();
/** Targets whose new words were already shown in this run of the app. */
const wordsShown = new Set();
let last = null;
let pollTimer = 0;

const el = (tag, cls, text) => {
  const node = document.createElement(tag);
  if (cls) node.className = cls;
  if (text !== undefined) node.textContent = text;
  return node;
};

function button(label, cls, enabled, run) {
  const b = el("button", `btn ${cls}`, label);
  b.type = "button";
  b.disabled = !enabled;
  b.addEventListener("click", run);
  return b;
}

function targetRow(target, running) {
  const v = targetView(target, { running, now: Date.now() / 1000, busy: busy.get(target.name) || "" });
  const li = el("li", "offsite-target");
  li.dataset.target = v.name;

  const head = el("div", "offsite-head");
  const icon = el("span", "row-icon");
  icon.appendChild(svg(ICONS.backup));
  const text = el("span", "row-text");
  const name = el("span", "headline", v.name);
  name.title = v.name;
  const where = el("span", "meta", v.where);
  where.title = v.where;
  text.append(name, where);
  head.append(icon, text, el("span", "offsite-pill", v.schedule));
  li.appendChild(head);

  li.appendChild(el("p", "offsite-state", v.state));
  if (v.uploading || busy.get(v.name) === "check") li.appendChild(el("div", "progress"));
  if (v.snapshot) li.appendChild(el("p", "offsite-snapshot", `Snapshot ${v.snapshot}`));

  const notes = el("ul", "offsite-notes");
  const said = results.get(v.name);
  if (said) notes.appendChild(el("li", said.kind, said.text));
  for (const n of v.notes) notes.appendChild(el("li", n.kind, n.text));
  li.appendChild(notes);

  const actions = el("div", "actions");
  actions.append(
    button("Remove", "text danger", v.canRemove, () => removeTarget(v.name, v.where)),
    button("Recovery words", "text", v.canWords, () => askWords(v.name)),
    button(busy.get(v.name) === "check" ? "Checking…" : "Check backup", "text", v.canCheck, () => checkTarget(v.name)),
    button(v.uploading ? "Backing up…" : "Back up now", "outlined", v.canRun, () => backUpNow(v.name)),
  );
  li.appendChild(actions);
  return li;
}

function render(info) {
  last = info;
  const section = $("offsite-section");
  section.hidden = !info.supported;
  if (!info.supported) return;
  const targets = info.targets || [];
  let state = "";
  if (!targets.length) state = "No backup bucket yet. Add one to keep a copy outside your home.";
  else if (info.archive_missing) state = "Deep backup is on, but no bucket here is an archive: add an AWS Glacier Deep Archive bucket, or turn Deep backup off.";
  $("offsite-state").textContent = state;
  $("offsite-list").replaceChildren(...targets.map((t) => targetRow(t, info.running)));
}

/** Uploads started here that ended, and words a first upload just made. */
function settle(info) {
  const targets = info.targets || [];
  for (const [name, started] of runs) {
    const target = targets.find((t) => t.name === name);
    if (target && !runFinished(target, started)) continue;
    runs.delete(name);
    busy.delete(name);
    if (!target) continue; // removed, or the node stopped
    // A failure stays on the row as the target's own last failure.
    results.delete(name);
    const said = runSummary(target);
    snack(said.ok ? `${name}: ${said.text}` : `${name}: the upload failed.`);
  }
  for (const target of targets) {
    if (!wordsDue(target) || wordsShown.has(target.name) || !$("words").hidden) continue;
    wordsShown.add(target.name);
    showWords(target.name, { first: true });
  }
}

export async function loadOffsite() {
  let info;
  try {
    info = await invoke("offsite_status", { config_path: await ensureConfig() });
  } catch {
    return;
  }
  settle(info);
  render(info);
  // An upload started here: look again soon, until it ends.
  clearTimeout(pollTimer);
  if (runs.size) pollTimer = setTimeout(loadOffsite, 1500);
}

const redraw = () => { if (last) render(last); };

async function backUpNow(name) {
  if (!isRunning()) return snack(failureText("NotRunning"));
  busy.set(name, "run");
  results.delete(name);
  redraw();
  try {
    runs.set(name, await invoke("offsite_run", { config_path: await ensureConfig(), name }));
  } catch (err) {
    busy.delete(name);
    results.set(name, { kind: "error", text: failureText(err) });
  }
  loadOffsite();
}

async function checkTarget(name) {
  busy.set(name, "check");
  results.set(name, { kind: "info", text: "Checking the bucket by listing it. Nothing is downloaded." });
  redraw();
  try {
    const check = await invoke("offsite_check", { config_path: await ensureConfig(), name });
    results.set(name, { kind: "ok", text: checkSummary(check) });
  } catch (err) {
    results.set(name, { kind: "error", text: `${checkFailed(err) ? "The check found a problem." : "Couldn't check the backup."} ${failureText(err)}` });
  }
  busy.delete(name);
  redraw();
}

async function removeTarget(name, where) {
  const ok = await askDialog({
    title: `Remove ${name}?`,
    text: `This device stops backing up to ${where} and forgets its keys.\n\nThe bucket and everything in it stay as they are: nothing is deleted there. To delete the backup itself, empty the bucket in your provider's console.`,
    confirm: "Remove",
    danger: true,
  });
  if (!ok) return;
  busy.set(name, "remove");
  redraw();
  try {
    const done = await invoke("offsite_remove", { config_path: await ensureConfig(), name });
    results.delete(name);
    runs.delete(name);
    snack(done.applied === "live" ? `Removed ${name}. Its bucket is untouched.` : `Removed ${name}. It applies after the node restarts.`);
  } catch (err) {
    results.set(name, { kind: "error", text: `Couldn't remove it. ${failureText(err)}` });
  }
  busy.delete(name);
  loadOffsite();
}

// ---- The recovery words ----

let wordsState = null; // { name, words, positions, first, confirmed }

async function askWords(name) {
  const ok = await askDialog({
    title: "Show the recovery words?",
    text: "Anyone who sees these 24 words can open your backup. Make sure nobody is looking at your screen.",
    confirm: "Show",
  });
  if (!ok) return;
  showWords(name, { first: false });
}

async function showWords(name, { first }) {
  busy.set(name, "words");
  redraw();
  let phrase;
  try {
    phrase = await invoke("offsite_words", { config_path: await ensureConfig(), name });
  } catch (err) {
    busy.delete(name);
    results.set(name, { kind: "error", text: `Couldn't read the recovery words. ${failureText(err)}` });
    return redraw();
  }
  busy.delete(name);
  redraw();
  const words = splitWords(phrase);
  const confirmed = !!last?.targets?.find((t) => t.name === name)?.words_confirmed;
  wordsState = { name, words, positions: pickPositions(words.length, 3), first, confirmed, step: "show" };
  $("words-title").textContent = first ? `Save the recovery words for ${name}` : `Recovery words for ${name}`;
  const grid = $("words-grid");
  grid.replaceChildren(...words.map((w, i) => {
    const li = el("li");
    li.append(el("span", "n", String(i + 1)), el("span", "w", w));
    return li;
  }));
  wordsStep("show");
  $("words").hidden = false;
  $("words-next").focus();
}

function wordsStep(step) {
  const st = wordsState;
  st.step = step;
  $("words-show").hidden = step !== "show";
  $("words-check").hidden = step !== "check";
  $("words-copy").hidden = step !== "show";
  $("words-error").hidden = true;
  if (step === "show") {
    $("words-later").textContent = st.confirmed ? "Close" : "Not now";
    $("words-next").textContent = "I wrote them down";
    $("words-next").hidden = st.confirmed;
    return;
  }
  const [a, b, c] = st.positions;
  $("words-ask").textContent = `Type words ${a}, ${b} and ${c} from your paper, to make sure it reads right.`;
  $("words-inputs").replaceChildren(...st.positions.map((pos) => {
    const label = el("label", "field");
    const input = el("input");
    input.placeholder = " ";
    input.autocomplete = "off";
    input.spellcheck = false;
    input.autocapitalize = "none";
    input.dataset.position = String(pos);
    label.append(input, el("span", "field-label", `Word ${pos}`));
    return label;
  }));
  $("words-later").textContent = "Back";
  $("words-next").textContent = "Confirm";
  $("words-next").hidden = false;
  $("words-inputs").querySelector("input")?.focus();
}

/** Closes the dialog and drops every copy of the words this page holds. */
function closeWords() {
  $("words").hidden = true;
  $("words-grid").replaceChildren();
  $("words-inputs").replaceChildren();
  wordsState = null;
}

async function submitWords() {
  const st = wordsState;
  if (!st) return;
  if (st.step === "show") return wordsStep("check");
  const answers = [...$("words-inputs").querySelectorAll("input")].map((i) => i.value);
  const wrong = wrongPositions(st.words, st.positions, answers);
  if (wrong.length) {
    const err = $("words-error");
    err.textContent = `${wrong.length === 1 ? `Word ${wrong[0]} doesn't` : `Words ${wrong.join(", ").replace(/, (\d+)$/, " and $1")} don't`} match. Check your paper against the list, then try again.`;
    err.hidden = false;
    return;
  }
  const name = st.name;
  try {
    await invoke("offsite_words_confirm", { config_path: await ensureConfig(), name });
  } catch (err) {
    const box = $("words-error");
    box.textContent = `The words are right, but saving that failed. ${failureText(err)}`;
    box.hidden = false;
    return;
  }
  closeWords();
  snack(`Recovery words for ${name} confirmed. Keep the paper safe.`);
  loadOffsite();
}

// ---- The add form ----

const FIELDS = { account: "offsite-account", endpoint: "offsite-endpoint", region: "offsite-region", bucket: "offsite-bucket", prefix: "offsite-prefix", access_key_id: "offsite-key-id", secret_access_key: "offsite-secret" };

function showProvider() {
  const p = provider($("offsite-provider").value);
  for (const field of ["account", "endpoint", "region"]) {
    $("offsite-form").querySelector(`[data-field="${field}"]`).hidden = !p.fields.includes(field);
  }
  $("offsite-provider-help").textContent = p.help;
  $("offsite-schedule").value = p.schedule;
  formError(null);
}

function formError(problem) {
  for (const label of $("offsite-form").querySelectorAll(".field")) label.classList.toggle("invalid", !!problem && label.dataset.field === problem.field);
  const box = $("offsite-form-error");
  box.hidden = !problem;
  box.textContent = problem ? problem.message : "";
  if (problem?.field && FIELDS[problem.field]) $(FIELDS[problem.field]).focus();
}

function openForm(open) {
  $("offsite-form").hidden = !open;
  $("offsite-add-row").hidden = open;
  if (!open) {
    // Nothing typed stays behind, least of all the secret.
    for (const id of Object.values(FIELDS)) $(id).value = "";
    $("offsite-encrypt").checked = true;
    $("offsite-encrypt-warning").hidden = true;
    return;
  }
  showProvider();
  $(FIELDS[provider($("offsite-provider").value).fields[0]]).focus();
}

async function submitForm(e) {
  e.preventDefault();
  const form = { provider: $("offsite-provider").value, encrypt: $("offsite-encrypt").checked, schedule: $("offsite-schedule").value };
  for (const [field, id] of Object.entries(FIELDS)) form[field] = $(id).value;
  const made = presetConfig(form);
  if (!made.ok) return formError(made);
  formError(null);
  const save = $("offsite-save");
  save.disabled = true;
  try {
    const added = await invoke("offsite_add", { config_path: await ensureConfig(), ...made.config });
    openForm(false);
    snack(added.applied === "live"
      ? `Added ${added.name}. The first upload makes its recovery words.`
      : `Added ${added.name}. It applies after the node restarts.`, 6000);
  } catch (err) {
    formError({ field: "", message: `Couldn't add the bucket. ${failureText(err)}` });
  }
  save.disabled = false;
  loadOffsite();
}

/** Wiring attaches once, from app.js. */
export function installOffsite() {
  $("offsite-add").addEventListener("click", () => openForm(true));
  $("offsite-cancel").addEventListener("click", () => openForm(false));
  $("offsite-provider").addEventListener("change", showProvider);
  $("offsite-encrypt").addEventListener("change", (e) => { $("offsite-encrypt-warning").hidden = e.target.checked; });
  $("offsite-form").addEventListener("submit", submitForm);

  $("words-form").addEventListener("submit", (e) => { e.preventDefault(); submitWords(); });
  $("words-later").addEventListener("click", () => {
    if (wordsState?.step === "check") return wordsStep("show");
    const pending = wordsState && !wordsState.confirmed;
    closeWords();
    if (pending) snack("The recovery words still need confirming: open Recovery words when you have paper at hand.", 6000);
  });
  $("words-copy").addEventListener("click", () => {
    if (wordsState) copyText(wordsState.words.join(" "), "Recovery words copied. Paste them somewhere offline, then clear the clipboard.");
  });
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && wordsState) $("words-later").click();
  });

  // Progress while Settings is open.
  setInterval(() => { if (document.body.dataset.view === "settings" && !document.hidden && !runs.size) loadOffsite(); }, 5000);
  loadOffsite();
}
