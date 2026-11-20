// Selecting several things to act on them at once (the Swarm folder's rows,
// the Photos grid's tiles): what is selected, the bar that says how many and
// offers Delete and Cancel, the long press that starts it on touch screens,
// and the delete itself. Screens import this; it imports nothing.

/** What is selected, by key (a swarm path). `onChange` runs after every change. */
export class Selection {
  constructor(onChange = () => {}) {
    this.onChange = onChange;
    this.active = false;
    this.items = new Map(); // key -> the value given with it
    this.anchor = null; // the key last toggled: where a shift-click range starts
  }

  get size() { return this.items.size; }
  has(key) { return this.items.has(key); }
  keys() { return [...this.items.keys()]; }
  values() { return [...this.items.values()]; }

  enter() {
    if (this.active) return;
    this.active = true;
    this.onChange();
  }

  /** Leaves select mode: nothing stays selected. */
  leave() {
    if (!this.active && !this.items.size) return;
    this.active = false;
    this.items.clear();
    this.anchor = null;
    this.onChange();
  }

  /** Selects or unselects one (and starts select mode). Returns whether it is selected now. */
  toggle(key, value = true) {
    const on = !this.items.has(key);
    if (on) this.items.set(key, value);
    else this.items.delete(key);
    this.active = true;
    this.anchor = key;
    this.onChange();
    return on;
  }

  /** Selects (or unselects) several: `entries` is [[key, value], ...]. */
  setMany(entries, on = true) {
    for (const [key, value] of entries) {
      if (on) this.items.set(key, value);
      else this.items.delete(key);
    }
    this.active = true;
    this.onChange();
  }

  /** True when every one of `keys` is selected (and there is at least one). */
  hasAll(keys) {
    let n = 0;
    for (const k of keys) {
      if (!this.items.has(k)) return false;
      n++;
    }
    return n > 0;
  }

  /** Forgets what is no longer there (`present`: a Set of keys). */
  retain(present) {
    let dropped = false;
    for (const k of this.items.keys()) {
      if (!present.has(k)) { this.items.delete(k); dropped = true; }
    }
    if (this.anchor !== null && !present.has(this.anchor)) this.anchor = null;
    if (dropped) this.onChange();
  }
}

/** The keys from `a` to `b` in `ordered`, both included, whichever comes
 *  first. Only `b` when `a` isn't there (no anchor yet). */
export function rangeBetween(ordered, a, b) {
  const j = ordered.indexOf(b);
  if (j < 0) return [];
  const i = ordered.indexOf(a);
  if (i < 0) return [b];
  return ordered.slice(Math.min(i, j), Math.max(i, j) + 1);
}

export function chunk(list, size) {
  const out = [];
  for (let i = 0; i < list.length; i += size) out.push(list.slice(i, i + size));
  return out;
}

/** The question before a delete: { title, text }. `noun` is [one, many];
 *  `folders` is how many of them are folders. */
export function deleteCopy(count, { noun = ["item", "items"], folders = 0 } = {}) {
  const gone = count === 1 ? "It disappears from every device." : "They disappear from every device.";
  const inside = folders === 0 ? "" :
    folders === 1 ? "The folder is deleted with everything in it. " :
    "Folders are deleted with everything in them. ";
  return { title: `Delete ${count} ${count === 1 ? noun[0] : noun[1]}?`, text: `${inside}${gone}` };
}

/** Deletes swarm paths a batch at a time. Resolves { deleted, error }: how
 *  many went, and what stopped it (null when all the batches ran). */
export async function deleteMany(invoke, paths, { size = 500, onProgress = null } = {}) {
  let deleted = 0;
  let sent = 0;
  for (const part of chunk(paths, size)) {
    onProgress?.(sent, paths.length);
    try {
      deleted += Number(await invoke("swarm_delete_many", { paths: part })) || 0;
    } catch (err) {
      return { deleted, error: err };
    }
    sent += part.length;
  }
  return { deleted, error: null };
}

/** What the snackbar says after deleteMany. */
export function deletedText({ deleted, error }) {
  if (!error) return `Deleted ${deleted}`;
  return deleted ? `Deleted ${deleted}, then it failed: ${error}` : `Delete failed: ${error}`;
}

// ---- The page side: the bar and the long press ----

/** The bar shown while selecting: [All] "N selected" [Cancel] [Delete].
 *  `onAll` is optional (no "All" button without it). Returns
 *  { el, update({ count, all, busy }) }; `busy` is a text shown instead of
 *  the count while the delete runs. */
export function selectionBar({ label, onAll = null, onDelete, onCancel }) {
  const el = document.createElement("div");
  el.className = "select-bar";
  el.hidden = true;
  el.setAttribute("role", "toolbar");
  el.setAttribute("aria-label", label);

  const button = (cls, text, run) => {
    const b = document.createElement("button");
    b.type = "button";
    b.className = cls;
    b.textContent = text;
    b.addEventListener("click", run);
    return b;
  };

  const all = onAll ? button("btn text select-all", "All", onAll) : null;
  if (all) {
    all.setAttribute("aria-label", "Select all");
    all.setAttribute("aria-pressed", "false");
  }
  const count = document.createElement("span");
  count.className = "select-count";
  count.setAttribute("role", "status");
  count.setAttribute("aria-live", "polite");
  const cancel = button("btn text", "Cancel", onCancel);
  const del = button("btn filled danger", "Delete", onDelete);
  if (all) el.appendChild(all);
  el.appendChild(count);
  el.appendChild(cancel);
  el.appendChild(del);

  return {
    el,
    update({ count: n = 0, all: allOn = false, busy = "" }) {
      count.textContent = busy || `${n} selected`;
      del.disabled = !!busy || n === 0;
      cancel.disabled = !!busy;
      if (all) {
        all.disabled = !!busy;
        all.textContent = allOn ? "None" : "All";
        all.setAttribute("aria-label", allOn ? "Select none" : "Select all");
        all.setAttribute("aria-pressed", allOn ? "true" : "false");
      }
    },
  };
}

/**
 * A long press on a touch screen, for everything inside `root`: `pick(event)`
 * gives what was pressed (null: nothing to press there) and `fire(picked)`
 * runs once the finger has stayed put. The tap that ends the press is not a
 * click: `wasLongPress()` is true for it, once. `onRelease` runs when the
 * finger lifts after a press that fired.
 */
export function longPress(root, pick, fire, { ms = 500, onRelease = null } = {}) {
  let timer = 0;
  let start = null;
  let fired = false;
  const cancel = () => { clearTimeout(timer); timer = 0; start = null; };
  root.addEventListener("pointerdown", (e) => {
    cancel();
    fired = false;
    if (e.pointerType !== "touch") return;
    const picked = pick(e);
    if (picked === null || picked === undefined) return;
    start = { x: e.clientX, y: e.clientY };
    timer = setTimeout(() => { timer = 0; fired = true; fire(picked); }, ms);
  });
  root.addEventListener("pointermove", (e) => {
    if (start && Math.hypot(e.clientX - start.x, e.clientY - start.y) > 10) cancel();
  });
  root.addEventListener("pointerup", () => { cancel(); if (fired) onRelease?.(); });
  root.addEventListener("pointercancel", cancel);
  return {
    wasLongPress() {
      const was = fired;
      fired = false;
      return was;
    },
  };
}
