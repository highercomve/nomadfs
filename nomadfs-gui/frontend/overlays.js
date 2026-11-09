// Shared overlays: Material list rows, the long-press/context menu, and the
// small ask dialog. Screens import these; overlays import nothing from screens.
import { $, svg, ICONS } from "./core.js";
import { syncBack, registerUp } from "./back.js";

/** A Material list row: leading icon, headline + meta, optional trailing button. */
export function row({ icon, iconClass = "", headline, meta, meta2, monoMeta = false, onClick, action, actions, cols, menu }) {
  if (action && !actions) actions = [action];
  const li = document.createElement("li");
  const lead = document.createElement("span");
  lead.className = `row-icon ${iconClass}`;
  lead.appendChild(svg(ICONS[icon]));
  li.appendChild(lead);
  const text = document.createElement("span");
  text.className = "row-text";
  const h = document.createElement("span");
  h.className = "headline";
  h.textContent = headline;
  h.title = headline;
  text.appendChild(h);
  // `meta` may be several lines (an array), each on its own row.
  const metaLines = (Array.isArray(meta) ? meta : [meta]).map((m) => [m, monoMeta]);
  for (const [line, mono] of [...metaLines, [meta2, true]]) {
    if (!line) continue;
    const m = document.createElement("span");
    m.className = mono ? "meta mono" : "meta";
    m.textContent = line;
    text.appendChild(m);
  }
  li.appendChild(text);
  // Wide layout: Type, Size, Modified, Added by columns (CSS hides them on phones).
  if (cols) {
    li.classList.add("has-cols");
    const colList = [];
    if (cols.type !== undefined) colList.push(["col-type", cols.type]);
    if (cols.size !== undefined) colList.push(["col-size", cols.size]);
    if (cols.date !== undefined) colList.push(["col-date", cols.date]);
    if (cols.by !== undefined) colList.push(["col-by", cols.by]);
    for (const [cls, value] of colList) {
      const c = document.createElement("span");
      c.className = `col ${cls}`;
      c.textContent = value || "";
      li.appendChild(c);
    }
    if (!actions) {
      const pad = document.createElement("span");
      pad.className = "col act-spacer";
      li.appendChild(pad);
    }
  }
  if (actions) {
    const box = document.createElement("span");
    box.className = "row-actions";
    for (const a of actions) {
      const b = document.createElement("button");
      b.className = "icon-btn";
      b.title = a.label;
      b.setAttribute("aria-label", a.label);
      b.appendChild(svg(ICONS[a.icon]));
      b.addEventListener("click", (e) => { e.stopPropagation(); a.run(b); });
      box.appendChild(b);
    }
    li.appendChild(box);
  }
  if (onClick) {
    li.classList.add("clickable");
    li.addEventListener("click", (e) => { if (!li.dataset.menuOpened) onClick(e); delete li.dataset.menuOpened; });
  }
  if (menu?.length) attachMenu(li, menu);
  return li;
}

// ---- The row menu (right-click; a long press on touch screens) ----

let menuEl = null;

/** `items`: { icon, label, run, danger } or "-" (a separator). */
export function attachMenu(li, items) {
  li.addEventListener("contextmenu", (e) => {
    e.preventDefault();
    e.stopPropagation();
    showMenu(e.clientX, e.clientY, items);
  });
  // Touch: a long press opens it, and the click that ends it doesn't open the row.
  let timer = 0;
  let start = null;
  li.addEventListener("pointerdown", (e) => {
    if (e.pointerType !== "touch") return;
    start = { x: e.clientX, y: e.clientY };
    timer = setTimeout(() => {
      li.dataset.menuOpened = "1";
      showMenu(start.x, start.y, items);
    }, 550);
  });
  const cancel = () => clearTimeout(timer);
  li.addEventListener("pointerup", cancel);
  li.addEventListener("pointercancel", cancel);
  li.addEventListener("pointermove", (e) => {
    if (start && Math.hypot(e.clientX - start.x, e.clientY - start.y) > 10) cancel();
  });
}

export function showMenu(x, y, items) {
  closeMenu(false); // replaced by the new one: same history step
  menuEl = document.createElement("div");
  menuEl.className = "row-menu";
  menuEl.setAttribute("role", "menu");
  for (const it of items) {
    if (it === "-") {
      menuEl.appendChild(Object.assign(document.createElement("hr"), { className: "row-menu-sep" }));
      continue;
    }
    const b = document.createElement("button");
    b.type = "button";
    b.className = `row-menu-item${it.danger ? " danger" : ""}`;
    b.setAttribute("role", "menuitem");
    b.appendChild(svg(ICONS[it.icon]));
    b.appendChild(document.createTextNode(it.label));
    // One history step for the whole tap: the menu closes and the item may open a level.
    b.addEventListener("click", (e) => { e.stopPropagation(); closeMenu(false); it.run(); syncBack(); });
    menuEl.appendChild(b);
  }
  document.body.appendChild(menuEl);
  coverNative();
  // Inside the window, near the pointer.
  const r = menuEl.getBoundingClientRect();
  menuEl.style.left = `${Math.max(8, Math.min(x, innerWidth - r.width - 8))}px`;
  menuEl.style.top = `${Math.max(8, Math.min(y, innerHeight - r.height - 8))}px`;
  menuEl.querySelector("button")?.focus();
  syncBack(); // Back closes the menu first
}

export function closeMenu(sync = true) {
  if (!menuEl) return;
  menuEl.remove();
  menuEl = null;
  coverNative();
  if (sync) syncBack();
}

/** The viewer draws native views above the page; while a menu or dialog shows
 *  over it the player hides. preview.js sets this hook. */
let menuCover = null;
export function setMenuCover(fn) { menuCover = fn; }
/** True while a row menu is open (the native player consults it to cover). */
export function menuOpen() { return !!menuEl; }
function coverNative() { menuCover?.(); }


/** A small dialog: ask for a name, or confirm. Resolves null on cancel. */
let askQueue = Promise.resolve();

export function askDialog({ title, text = "", value = null, confirm = "OK", danger = false }) {
  const run = () => new Promise((resolve) => {
    const dlg = $("ask");
    $("ask-title").textContent = title;
    $("ask-text").textContent = text;
    $("ask-text").hidden = !text;
    const field = $("ask-field");
    field.hidden = value === null;
    $("ask-input").value = value ?? "";
    const ok = $("ask-ok");
    ok.textContent = confirm;
    ok.classList.toggle("danger", danger);
    dlg.hidden = false;
    if (value !== null) {
      const input = $("ask-input");
      input.focus();
      const dot = input.value.lastIndexOf(".");
      input.setSelectionRange(0, dot > 0 ? dot : input.value.length);
    } else ok.focus();
    const done = (result) => {
      dlg.hidden = true;
      $("ask-form").onsubmit = null;
      $("ask-cancel").onclick = null;
      resolve(result);
    };
    $("ask-form").onsubmit = (e) => { e.preventDefault(); done(value === null ? true : $("ask-input").value.trim()); };
    $("ask-cancel").onclick = () => done(null);
  });
  return (askQueue = askQueue.then(run, run));
}

/** All the document-level menu wiring (taps, Escape, the WebView's context
 *  menu) attaches once, from app.js; the menu is also the first Back target. */
export function installOverlays() {
  // A tap outside closes the menu; the history catches up after the tap's own
  // click (which may open a level), as one step.
  let menuSyncPending = false;
  document.addEventListener("pointerdown", (e) => { if (menuEl && !menuEl.contains(e.target)) { closeMenu(false); menuSyncPending = true; } }, true);
  document.addEventListener("click", () => { if (menuSyncPending) { menuSyncPending = false; syncBack(); } });
  document.addEventListener("keydown", (e) => { if (e.key === "Escape" && menuEl) { closeMenu(); e.stopPropagation(); } }, true);
  addEventListener("scroll", closeMenu, true);
  addEventListener("resize", closeMenu);
  // The WebView's own menu (Back, Reload...) means nothing here; text fields keep theirs.
  document.addEventListener("contextmenu", (e) => {
    if (!e.target.closest("input, textarea, [contenteditable]") && !getSelection()?.toString()) e.preventDefault();
  });

  registerUp({
    depth: () => (menuEl ? 1 : 0),
    up: () => closeMenu(false),
  });
}
