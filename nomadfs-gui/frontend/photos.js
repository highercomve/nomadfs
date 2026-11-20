// ---- Photos: virtualised grid timeline with day grouping and year scrubber ----

import { $, svg, ICONS, snack } from "./core.js";
import { errText } from "./format.js";
import { askDialog } from "./overlays.js";
import { syncBack, registerUp } from "./back.js";
import { Selection, selectionBar, longPress, deleteCopy, deleteMany, deletedText } from "./selection.js";
import { fileMenu } from "./file-actions.js";
import { startDownload } from "./downloads.js";
import { openPreview } from "./preview.js";
import { groupByDay, layout, rowAt, yearMarks } from "./photos-model.js";
import { createThumbLoader, loadImage } from "./thumb-loader.js";

// Thumbnails load in the background, a few at a time: the app sends at
// most 6 thumbnail asks to other devices at once (cluster/block_manager).
const thumbs = createThumbLoader({ load: (_key, url, attempt) => loadImage(url, attempt), concurrency: 6 });
document.addEventListener("preview:closed", () => thumbs.kickAll());

const { invoke } = window.oriel || {};

const PAGE_SIZE = 300;
const MAX_PAGES = 40;
const TILE_TARGET = 120;
const GAP = 4;
const HEADER_H = 40;

let currentFolder = "";
let currentIndex = null;
let currentGeneration = 0;
let thumbBase = "";
let sections = [];
let rows = [];

// Page cache: Map<pageIndex, { items: object[] | null, promise: Promise | null }>
const pageCache = new Map();

// DOM node pooling for tiles
const tilePool = [];

function createTileNode() {
  const tile = document.createElement("div");
  tile.className = "photo-tile";

  const img = document.createElement("img");
  img.loading = "lazy";
  img.decoding = "async";
  img.alt = "";

  const placeholder = document.createElement("div");
  placeholder.className = "photo-placeholder";
  placeholder.hidden = true;

  const badge = document.createElement("div");
  badge.className = "photo-badge";
  badge.hidden = true;
  badge.appendChild(svg("M8 5v14l11-7z")); // Play glyph

  // The tick shown on a selected tile (CSS shows it only while selecting).
  const check = document.createElement("div");
  check.className = "photo-check";
  check.appendChild(svg(ICONS.check));

  tile.appendChild(img);
  tile.appendChild(placeholder);
  tile.appendChild(badge);
  tile.appendChild(check);

  return { el: tile, img, placeholder, badge, path: null };
}

function acquireTile() {
  return tilePool.pop() || createTileNode();
}

function releaseTile(tileObj) {
  if (tileObj.key) thumbs.drop(tileObj.key);
  tileObj.key = null;
  tileObj.path = null;
  markTile(tileObj);
  tileObj.el.onclick = null;
  tileObj.img.onload = null;
  tileObj.img.onerror = null;
  tileObj.img.removeAttribute("src");
  tileObj.placeholder.replaceChildren();
  tileObj.placeholder.hidden = true;
  tileObj.badge.hidden = true;
  tilePool.push(tileObj);
}

// Mounted rows: Map<rowIndex, { el: HTMLElement, type: string, tiles?: any[] }>
const mountedRows = new Map();

export function getCachedItem(index) {
  const pIdx = Math.floor(index / PAGE_SIZE);
  const page = pageCache.get(pIdx);
  if (page && page.items) {
    return page.items[index - pIdx * PAGE_SIZE] || null;
  }
  return null;
}

export async function getItemAsync(index) {
  const cached = getCachedItem(index);
  if (cached) return cached;
  const pIdx = Math.floor(index / PAGE_SIZE);
  const items = await fetchPage(pIdx, currentGeneration, currentFolder);
  return (items && items[index - pIdx * PAGE_SIZE]) || null;
}

const photosSource = {
  // The last piece read: the photo is on this device now, so this device
  // can make its thumbnail: its tile asks again at once.
  read: (e, offset, len) => invoke("swarm_read_range", { cid: e.cid, author_id: e.author || e.author_id, offset, len }).then((b64) => {
    if (offset + len >= e.size) thumbs.kick(`${e.author || e.author_id}/${e.cid}`);
    return b64;
  }),
  mediaUrl: (e, external = false, network = "") => invoke("media_url", { kind: "swarm", id: e.author || e.author_id, cid: e.cid, size: e.size, name: e.name, external, network }),
  download: (e) => startDownload("swarm_download", { cid: e.cid, author_id: e.author || e.author_id, name: e.name, size: e.size }),
  menu: (it) => photosMenu(it),
  load: (i) => getItemAsync(i),
};

function photosMenu(it) {
  return fileMenu(photosSource, it, { cid: it.cid, author_id: it.author || it.author_id });
}

function openPreviewAt(itemIndex) {
  if (!currentIndex || currentIndex.total === 0) return;
  const files = {
    length: currentIndex.total,
    at: (i) => getCachedItem(i),
  };
  openPreview(photosSource, files, itemIndex);
}

async function fetchPage(pIdx, gen, folder) {
  if (pageCache.has(pIdx)) {
    const entry = pageCache.get(pIdx);
    // Move to most-recently used
    pageCache.delete(pIdx);
    pageCache.set(pIdx, entry);
    if (entry.items) return entry.items;
    if (entry.promise) return entry.promise;
  }

  if (pageCache.size >= MAX_PAGES) {
    const oldestKey = pageCache.keys().next().value;
    pageCache.delete(oldestKey);
  }

  const start = pIdx * PAGE_SIZE;
  const count = Math.min(PAGE_SIZE, (currentIndex?.total || 0) - start);
  if (count <= 0) return [];

  const promise = (async () => {
    try {
      const res = await invoke("photos_page", {
        generation: gen,
        folder,
        start,
        count,
      });
      if (currentGeneration !== gen || currentFolder !== folder) return [];
      pageCache.set(pIdx, { items: res.items, promise: null });
      updateVisibleTilesForPage(pIdx, res.items);
      return res.items;
    } catch (err) {
      pageCache.delete(pIdx);
      if (String(err).includes("Stale")) {
        loadPhotos({ folder: currentFolder, keepScroll: true });
      }
      throw err;
    }
  })();

  pageCache.set(pIdx, { items: null, promise });
  return promise;
}

function updateTile(tileObj, item) {
  // Rows come and go as the grid scrolls: a tile is selected by its path.
  tileObj.path = item ? item.path : null;
  markTile(tileObj);
  if (!item) {
    tileObj.img.hidden = true;
    tileObj.img.removeAttribute("src");
    tileObj.placeholder.hidden = false;
    tileObj.placeholder.textContent = "";
    tileObj.badge.hidden = true;
    return;
  }

  tileObj.badge.hidden = item.kind !== "video";

  // No thumb_base: this node serves no thumbnails (yet).
  const needsPlaceholder = !thumbBase || item.thumb === "none" || item.kind === "heic";
  if (needsPlaceholder) {
    tileObj.img.hidden = true;
    tileObj.img.removeAttribute("src");
    tileObj.placeholder.hidden = false;
    const label = item.kind === "heic" ? "HEIC" : item.kind === "raw" ? "RAW" : "";
    if (label) {
      tileObj.placeholder.textContent = label;
    } else {
      tileObj.placeholder.replaceChildren(svg(ICONS.image));
    }
    return;
  }

  const thumbUrl = `${thumbBase}${item.author}/${item.cid}/t.jpg`;
  const key = `${item.author}/${item.cid}`;

  // The placeholder shows until the picture has loaded; the loader asks in
  // the background, and again later while the tile stays on screen.
  tileObj.placeholder.hidden = false;
  tileObj.placeholder.replaceChildren(svg(ICONS.image));
  tileObj.img.hidden = false;
  tileObj.img.classList.remove("ready");
  tileObj.img.alt = "";
  tileObj.img.onload = null;
  tileObj.img.removeAttribute("src");
  if (tileObj.key && tileObj.key !== key) thumbs.drop(tileObj.key);
  tileObj.key = key;
  thumbs.want(key, thumbUrl, (src) => {
    if (tileObj.key !== key) return; // the tile shows another photo now
    tileObj.img.onload = () => {
      tileObj.img.classList.add("ready");
      tileObj.placeholder.hidden = true;
    };
    tileObj.img.src = src;
  }, tilePriority(tileObj.el));
}

/** Nearest the middle of the view loads first (a tile's distance, px). */
function tilePriority(el) {
  const scroller = $("photos-scroll");
  if (!scroller || !el.parentElement) return 0;
  const top = parseFloat(el.parentElement.style.top) || 0;
  return Math.abs(top - (scroller.scrollTop + scroller.clientHeight / 2));
}

function updateVisibleTilesForPage(pIdx, items) {
  const pageStart = pIdx * PAGE_SIZE;
  const pageEnd = pageStart + items.length;

  for (const [, mounted] of mountedRows) {
    if (mounted.type !== "tiles" || !mounted.tiles) continue;
    for (const t of mounted.tiles) {
      const idx = Number(t.el.dataset.index);
      if (idx >= pageStart && idx < pageEnd) {
        updateTile(t, items[idx - pageStart]);
      }
    }
  }
}

// ---- Selecting several photos, to delete them at once ----

// Selected photos by swarm path: it outlives the rows, which unmount as they
// scroll away, and the pages, which are fetched again after a change.
const sel = new Selection(() => selectionChanged());
let selAnchor = -1; // the index last tapped: where a shift-click range starts
let selBusy = ""; // what the bar says while the delete runs
let selBar = null; // built when the screen installs
let press = null; // the grid's long press

function markTile(tileObj) {
  const on = sel.active && !!tileObj.path && sel.has(tileObj.path);
  tileObj.el.classList.toggle("selected", on);
  if (sel.active) {
    tileObj.el.setAttribute("role", "checkbox");
    tileObj.el.setAttribute("aria-checked", on ? "true" : "false");
  } else {
    tileObj.el.removeAttribute("role");
    tileObj.el.removeAttribute("aria-checked");
  }
}

/** While selecting, a day's date is a button: it picks the whole day. */
function markDayHead(el) {
  el.classList.toggle("selectable", sel.active);
  if (sel.active) {
    el.setAttribute("role", "button");
    el.setAttribute("aria-label", `Select all of ${el.textContent}`);
  } else {
    el.removeAttribute("role");
    el.removeAttribute("aria-label");
  }
}

function drawSelectionBar() {
  if (!selBar) return;
  selBar.el.hidden = !sel.active;
  selBar.update({ count: sel.size, busy: selBusy });
}

function selectionChanged() {
  $("photos-section").classList.toggle("selecting", sel.active);
  $("photos-select").setAttribute("aria-pressed", sel.active ? "true" : "false");
  for (const mounted of mountedRows.values()) {
    if (mounted.type === "header") markDayHead(mounted.el);
    else if (mounted.tiles) for (const t of mounted.tiles) markTile(t);
  }
  drawSelectionBar();
  if (!sel.active) selAnchor = -1;
  syncBack(); // Back leaves select mode first
}

function tileClick(tileObj, itemIdx, e) {
  // The tap that ends a long press already selected the tile.
  if (press?.wasLongPress()) return;
  // Ctrl/Cmd-click picks one, Shift-click everything up to it.
  if (!sel.active && !e.ctrlKey && !e.metaKey && !e.shiftKey) return openPreviewAt(itemIdx);
  if (selBusy) return;
  if (e.shiftKey && selAnchor >= 0 && selAnchor !== itemIdx) {
    const from = Math.min(selAnchor, itemIdx);
    selectRange(from, Math.abs(selAnchor - itemIdx) + 1, true);
    selAnchor = itemIdx;
    return;
  }
  if (!tileObj.path) return; // not loaded yet: nothing to pick
  sel.toggle(tileObj.path);
  selAnchor = itemIdx;
}

/** Selects or unselects `count` photos from `start` (`on` null: unselects
 *  them when all are selected, else selects them). Their pages may still
 *  have to load. */
async function selectRange(start, count, on = null) {
  const gen = currentGeneration;
  const folder = currentFolder;
  const paths = [];
  try {
    for (let i = start; i < start + count; i++) {
      const item = await getItemAsync(i);
      if (gen !== currentGeneration || folder !== currentFolder || !sel.active) return;
      if (item?.path) paths.push(item.path);
    }
  } catch (err) {
    snack(`Couldn't select them: ${errText(err)}`);
    return;
  }
  if (!paths.length) return;
  sel.setMany(paths.map((p) => [p, true]), on ?? !sel.hasAll(paths));
}

function toggleDay(sectionIndex) {
  const sec = sections[sectionIndex];
  if (!sec || selBusy) return;
  selectRange(sec.start, sec.count);
}

async function deleteSelected() {
  if (selBusy || !sel.size) return;
  const ok = await askDialog({
    ...deleteCopy(sel.size, { noun: ["photo or video", "photos and videos"] }),
    confirm: "Delete",
    danger: true,
  });
  if (!ok || !sel.size) return;
  const paths = sel.keys();
  selBusy = "Deleting…";
  drawSelectionBar();
  const res = await deleteMany(invoke, paths, {
    size: 500,
    onProgress: (sent, total) => {
      if (!sent) return;
      selBusy = `Deleting ${sent} of ${total}…`;
      drawSelectionBar();
    },
  });
  selBusy = "";
  snack(deletedText(res));
  sel.leave();
  // A new index and new pages (loadPhotos empties the page cache): the
  // deleted ones are gone from the grid, which stays where it was.
  loadPhotos({ folder: currentFolder, keepScroll: true });
}

function installSelection() {
  selBar = selectionBar({
    label: "Selected photos",
    onDelete: deleteSelected,
    onCancel: () => sel.leave(),
  });
  $("photos-section").appendChild(selBar.el);
  $("photos-select").addEventListener("click", () => {
    if (sel.active) sel.leave();
    else sel.enter();
  });
  // Touch: a long press on a photo starts selecting, with that photo.
  press = longPress($("photos-window"), (e) => {
    const el = e.target.closest?.(".photo-tile");
    return el && !sel.active ? el : null;
  }, (el) => {
    const item = getCachedItem(Number(el.dataset.index));
    if (!item?.path || selBusy) return;
    sel.toggle(item.path);
    selAnchor = Number(el.dataset.index);
  }, { onRelease: syncBack }); // the history step is added on the tap's end
  document.addEventListener("keydown", (e) => {
    if (e.key !== "Escape" || !sel.active || selBusy) return;
    if (document.body.dataset.view !== "photos" || !$("ask").hidden) return;
    sel.leave();
  });
  registerUp({
    depth: () => (document.body.dataset.view === "photos" && sel.active ? 1 : 0),
    up: () => sel.leave(),
  });
}

function renderFolderChips(folders, total) {
  const chipsEl = $("photos-chips");
  if (!chipsEl) return;
  chipsEl.replaceChildren();

  const allChip = document.createElement("button");
  allChip.type = "button";
  allChip.className = `chip${currentFolder === "" ? " active" : ""}`;
  allChip.textContent = `All (${total})`;
  allChip.addEventListener("click", () => {
    if (currentFolder === "") return;
    sel.leave();
    currentFolder = "";
    loadPhotos({ folder: "", keepScroll: false });
  });
  chipsEl.appendChild(allChip);

  if (!folders || folders.length === 0) return;

  for (const f of folders) {
    const chip = document.createElement("button");
    chip.type = "button";
    chip.className = `chip${currentFolder === f.path ? " active" : ""}`;
    // The whole path: "Camera" alone would not tell a phone's from another's.
    const name = f.path.split("/").join(" › ");
    chip.textContent = `${name} (${f.count})`;
    chip.addEventListener("click", () => {
      if (currentFolder === f.path) return;
      sel.leave();
      currentFolder = f.path;
      loadPhotos({ folder: f.path, keepScroll: false });
    });
    chipsEl.appendChild(chip);
  }
}

function computeLayout() {
  const scrollEl = $("photos-scroll");
  const spacerEl = $("photos-spacer");
  if (!scrollEl || !spacerEl) return;

  // clientWidth includes the scroller's 8px side padding; the rows sit
  // inside it (.photos-window is inset 8px each side).
  const w = Math.max(120, (scrollEl.clientWidth || 360) - 16);
  rows = layout(sections, w, TILE_TARGET, GAP, HEADER_H);
  spacerEl.style.height = `${rows.totalHeight}px`;

  renderScrubber();
  unmountAllRows();
}

function unmountAllRows() {
  const windowEl = $("photos-window");
  for (const [, mounted] of mountedRows) {
    if (mounted.tiles) {
      for (const t of mounted.tiles) releaseTile(t);
    }
    mounted.el.remove();
  }
  mountedRows.clear();
  if (windowEl) windowEl.replaceChildren();
}

function updateVisibleWindow() {
  const scrollEl = $("photos-scroll");
  const windowEl = $("photos-window");
  if (!scrollEl || !windowEl || rows.length === 0) return;

  const scrollTop = scrollEl.scrollTop;
  const viewportH = scrollEl.clientHeight || window.innerHeight || 600;
  const renderTop = Math.max(0, scrollTop - 2 * viewportH);
  const renderBottom = scrollTop + 3 * viewportH;

  const firstRow = rowAt(rows, renderTop);
  const lastRow = rowAt(rows, renderBottom);

  // Unmount rows outside visible range
  for (const [rIdx, mounted] of mountedRows) {
    if (rIdx < firstRow || rIdx > lastRow) {
      if (mounted.tiles) {
        for (const t of mounted.tiles) releaseTile(t);
      }
      mounted.el.remove();
      mountedRows.delete(rIdx);
    }
  }

  // Mount rows within visible range
  const neededPages = new Set();

  for (let rIdx = firstRow; rIdx <= lastRow; rIdx++) {
    if (mountedRows.has(rIdx)) continue;
    const r = rows[rIdx];
    if (!r) continue;

    if (r.type === "header") {
      const headEl = document.createElement("div");
      headEl.className = "photos-day-head";
      headEl.style.top = `${r.top}px`;
      headEl.style.height = `${r.h}px`;
      headEl.textContent = r.label;
      headEl.onclick = () => { if (sel.active) toggleDay(r.sectionIndex); };
      markDayHead(headEl);
      windowEl.appendChild(headEl);
      mountedRows.set(rIdx, { el: headEl, type: "header" });
    } else if (r.type === "tiles") {
      const rowEl = document.createElement("div");
      rowEl.className = "photos-tile-row";
      rowEl.style.top = `${r.top}px`;
      rowEl.style.height = `${r.h}px`;
      rowEl.style.gap = `${r.gap}px`;

      const tiles = [];
      for (let k = 0; k < r.n; k++) {
        const itemIdx = r.start + k;
        const tileObj = acquireTile();
        tileObj.el.style.width = `${r.tileSize}px`;
        tileObj.el.style.height = `${r.tileSize}px`;
        tileObj.el.dataset.index = itemIdx;
        tileObj.el.onclick = (e) => tileClick(tileObj, itemIdx, e);

        const item = getCachedItem(itemIdx);
        updateTile(tileObj, item);
        rowEl.appendChild(tileObj.el);
        tiles.push(tileObj);

        const pIdx = Math.floor(itemIdx / PAGE_SIZE);
        if (!pageCache.has(pIdx) || !pageCache.get(pIdx).items) {
          neededPages.add(pIdx);
        }
      }

      windowEl.appendChild(rowEl);
      mountedRows.set(rIdx, { el: rowEl, type: "tiles", tiles });
    }
  }

  for (const pIdx of neededPages) {
    fetchPage(pIdx, currentGeneration, currentFolder).catch(() => {});
  }

  // What is on screen now goes first in the thumbnail queue.
  for (const mounted of mountedRows.values()) {
    if (!mounted.tiles) continue;
    for (const t of mounted.tiles) if (t.key) thumbs.setPriority(t.key, tilePriority(t.el));
  }
}

function onScroll() {
  const scrollEl = $("photos-scroll");
  const stickyEl = $("photos-sticky");
  if (!scrollEl) return;

  updateVisibleWindow();

  if (rows.length > 0 && stickyEl) {
    const rIdx = rowAt(rows, scrollEl.scrollTop);
    const r = rows[rIdx];
    if (r && sections[r.sectionIndex]) {
      stickyEl.textContent = sections[r.sectionIndex].label;
      stickyEl.hidden = false;
    }
  } else if (stickyEl) {
    stickyEl.hidden = true;
  }
}

function renderScrubber() {
  const scrubberEl = $("photos-scrubber");
  if (!scrubberEl) return;
  scrubberEl.replaceChildren();

  const marks = yearMarks(sections, rows);
  if (marks.length <= 1) {
    scrubberEl.hidden = true;
    return;
  }
  scrubberEl.hidden = false;

  for (const m of marks) {
    const dot = document.createElement("div");
    dot.className = "scrubber-mark";
    dot.dataset.top = m.top;
    dot.dataset.year = m.year;
    dot.textContent = m.label;
    dot.addEventListener("click", (e) => {
      e.stopPropagation();
      const scrollEl = $("photos-scroll");
      if (scrollEl) scrollEl.scrollTo({ top: m.top, behavior: "smooth" });
    });
    scrubberEl.appendChild(dot);
  }
}

function setupScrubberEvents() {
  const scrubberEl = $("photos-scrubber");
  const bubbleEl = $("photos-scrubber-bubble");
  const scrollEl = $("photos-scroll");
  if (!scrubberEl || !scrollEl) return;

  let isDragging = false;

  const jump = (clientY) => {
    const rect = scrubberEl.getBoundingClientRect();
    if (rect.height <= 0) return;
    const ratio = Math.max(0, Math.min(1, (clientY - rect.top) / rect.height));
    const maxScroll = Math.max(0, rows.totalHeight - scrollEl.clientHeight);
    const targetTop = ratio * maxScroll;
    scrollEl.scrollTop = targetTop;

    if (bubbleEl) {
      const rIdx = rowAt(rows, targetTop);
      const r = rows[rIdx];
      if (r && sections[r.sectionIndex]) {
        bubbleEl.textContent = sections[r.sectionIndex].key.slice(0, 4);
        bubbleEl.hidden = false;
        bubbleEl.style.top = `${clientY - rect.top}px`;
      }
    }
  };

  scrubberEl.addEventListener("pointerdown", (e) => {
    isDragging = true;
    if (scrubberEl.setPointerCapture) scrubberEl.setPointerCapture(e.pointerId);
    jump(e.clientY);
  });

  scrubberEl.addEventListener("pointermove", (e) => {
    if (!isDragging) return;
    jump(e.clientY);
  });

  const stop = () => {
    if (!isDragging) return;
    isDragging = false;
    if (bubbleEl) bubbleEl.hidden = true;
  };

  scrubberEl.addEventListener("pointerup", stop);
  scrubberEl.addEventListener("pointercancel", stop);
}

export async function loadPhotos(opts = {}) {
  const { folder = currentFolder, keepScroll = false } = opts;
  currentFolder = folder;

  const scrollEl = $("photos-scroll");
  const spacerEl = $("photos-spacer");
  const windowEl = $("photos-window");
  const stickyEl = $("photos-sticky");
  const scrubberEl = $("photos-scrubber");
  const emptyEl = $("photos-empty");
  const loadingEl = $("photos-loading");
  const errorEl = $("photos-error");

  const prevScroll = keepScroll && scrollEl ? scrollEl.scrollTop : 0;

  if (loadingEl) loadingEl.hidden = false;
  if (emptyEl) emptyEl.hidden = true;
  if (errorEl) errorEl.hidden = true;

  try {
    if (!window.oriel || typeof window.oriel.invoke !== "function") {
      throw new Error("Oriel backend unavailable");
    }

    let index;
    try {
      index = await invoke("photos_index", { folder, kinds: "all" });
    } catch (invokeErr) {
      if (loadingEl) loadingEl.hidden = true;
      if (errorEl) {
        errorEl.hidden = false;
        errorEl.textContent = `Photos unavailable: ${errText(invokeErr)}`;
      }
      return;
    }

    if (loadingEl) loadingEl.hidden = true;
    currentIndex = index;
    currentGeneration = index.generation;
    thumbBase = index.thumb_base || "";

    pageCache.clear();
    selAnchor = -1; // the photos have new positions

    renderFolderChips(index.folders, index.total);

    if (index.total === 0) {
      if (emptyEl) {
        emptyEl.hidden = false;
        emptyEl.textContent = folder ? "No photos or videos in this folder." : "No photos or videos in the swarm folder yet.";
      }
      if (spacerEl) spacerEl.style.height = "0px";
      if (windowEl) windowEl.replaceChildren();
      if (stickyEl) stickyEl.hidden = true;
      if (scrubberEl) scrubberEl.hidden = true;
      rows = [];
      sections = [];
      unmountAllRows();
      return;
    }

    sections = groupByDay(index.mtimes);
    computeLayout();

    if (scrollEl) {
      scrollEl.scrollTop = keepScroll ? prevScroll : 0;
    }
    onScroll();
  } catch (err) {
    if (loadingEl) loadingEl.hidden = true;
    if (errorEl) {
      errorEl.hidden = false;
      errorEl.textContent = `Error loading photos: ${errText(err)}`;
    }
  }
}

export function installPhotos() {
  const scrollEl = $("photos-scroll");
  if (scrollEl) {
    scrollEl.addEventListener("scroll", onScroll, { passive: true });
    if (typeof ResizeObserver !== "undefined") {
      new ResizeObserver(() => {
        if (document.body.dataset.view === "photos" && sections.length > 0) {
          computeLayout();
          onScroll();
        }
      }).observe(scrollEl);
    }
  }

  setupScrubberEvents();
  installSelection();

  window.oriel?.listen?.("photos://changed", () => {
    if (document.body.dataset.view === "photos") {
      loadPhotos({ folder: currentFolder, keepScroll: true });
    }
  });
}
