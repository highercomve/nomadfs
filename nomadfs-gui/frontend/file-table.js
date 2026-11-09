// File tables: search, sort, type chips and sortable columns (Browse, Swarm folder).
import { svg } from "./core.js";
import { fileType } from "./file-types.js";

// ---- File tables: search, sort and sortable columns (Browse, Swarm folder) ----

const SEARCH_ICON = "M15.5 14h-.79l-.28-.27A6.47 6.47 0 0 0 16 9.5 6.5 6.5 0 1 0 9.5 16c1.61 0 3.09-.59 4.23-1.57l.27.28v.79l5 4.99L20.49 19l-4.99-5zm-6 0C7.01 14 5 11.99 5 9.5S7.01 5 9.5 5 14 7.01 14 9.5 11.99 14 9.5 14z";
const SORT_DIR_ICON = "M4 12l1.41 1.41L11 7.83V20h2V7.83l5.58 5.59L20 12l-8-8-8 8z";

/**
 * A list of files and folders with a search field, a sort menu (phones) and
 * sortable column headers (wide windows). The owner gives the entries
 * ({ name, size, mtime, dir, ... }) and draws each row; the table filters,
 * sorts (folders first) and remembers the order across runs.
 *
 *   columns: [{ key, label, cls }] after Name, e.g. size, mtime, author
 *   renderRow(entry, files): an <li>; files = the shown files, in order
 *   emptyText(query): what an empty list says
 */
class FileTable {
  constructor({ view, tools, head, list, columns, storageKey, actions, placeholder = "Search this folder", renderRow, emptyText, setEmpty }) {
    Object.assign(this, { view, tools, head, list, columns, storageKey, renderRow, emptyText, setEmpty });
    this.entries = null;
    this.sort = { key: "name", dir: 1 };
    this.filterType = "all";
    try { Object.assign(this.sort, JSON.parse(localStorage.getItem(storageKey) || "{}")); } catch {}
    if (!this.allColumns().some((c) => c.key === this.sort.key)) this.sort = { key: "name", dir: 1 };
    // Room for the row buttons, so the header lines up with the rows.
    head.closest(".table-scroll").style.setProperty("--act-w", `${actions * 34}px`);
    this.buildTools(placeholder);
    this.buildHead();
    FileTable.all.push(this);
  }

  allColumns() {
    return [{ key: "name", label: "Name", cls: "th-name" }, ...this.columns];
  }

  buildTools(placeholder) {
    const searchRow = document.createElement("div");
    searchRow.className = "tools-search-row";

    const field = document.createElement("label");
    field.className = "search-field";
    field.append(svg(SEARCH_ICON));
    const input = document.createElement("input");
    Object.assign(input, { type: "search", placeholder, autocomplete: "off", spellcheck: false });
    input.setAttribute("aria-label", placeholder);
    input.addEventListener("input", () => this.render());
    input.addEventListener("keydown", (e) => {
      if (e.key === "Escape" && input.value) { input.value = ""; this.render(); e.stopPropagation(); }
    });
    field.append(input);

    const select = document.createElement("select");
    select.className = "sort-select";
    select.setAttribute("aria-label", "Sort by");
    for (const c of this.allColumns()) select.append(new Option(c.label, c.key));
    select.addEventListener("change", () => this.setSort(select.value, this.sort.dir));

    const dir = document.createElement("button");
    dir.type = "button";
    dir.className = "icon-btn sort-dir";
    dir.setAttribute("aria-label", "Sort direction");
    dir.append(svg(SORT_DIR_ICON));
    dir.addEventListener("click", () => this.setSort(this.sort.key, -this.sort.dir));

    searchRow.append(field, select, dir);

    const chipsBox = document.createElement("div");
    chipsBox.className = "type-chips";
    chipsBox.hidden = true;

    this.tools.replaceChildren(searchRow, chipsBox);
    Object.assign(this, { input, select, dirBtn: dir, chipsBox });
  }

  updateFilterChips() {
    if (!this.entries || !this.chipsBox) return;
    const counts = { all: this.entries.length };
    for (const e of this.entries) {
      const t = e._type;
      counts[t] = (counts[t] || 0) + 1;
    }
    const categories = ["Photo", "Video", "Audio", "Document", "Archive", "Code", "Folder", "File"];
    const activeCats = categories.filter((c) => (counts[c] || 0) > 0);

    if (activeCats.length <= 1) {
      this.chipsBox.replaceChildren();
      this.chipsBox.hidden = true;
      return;
    }
    this.chipsBox.hidden = false;

    const makeChip = (id, label, count) => {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = `type-chip${this.filterType === id ? " active" : ""}`;
      btn.dataset.type = id;
      const lbl = document.createElement("span");
      lbl.textContent = label;
      btn.appendChild(lbl);
      const cnt = document.createElement("span");
      cnt.className = "count";
      cnt.textContent = count;
      btn.appendChild(cnt);
      btn.addEventListener("click", () => {
        this.filterType = this.filterType === id && id !== "all" ? "all" : id;
        this.render();
      });
      return btn;
    };

    const chips = [makeChip("all", "All", counts.all)];
    const pluralLabels = {
      Photo: "Photos",
      Video: "Videos",
      Audio: "Audio",
      Document: "Documents",
      Archive: "Archives",
      Code: "Code",
      Folder: "Folders",
      File: "Files",
    };
    for (const c of activeCats) {
      chips.push(makeChip(c, pluralLabels[c] || c, counts[c]));
    }
    this.chipsBox.replaceChildren(...chips);
  }

  buildHead() {
    this.head.replaceChildren();
    for (const c of this.allColumns()) {
      const th = document.createElement("button");
      th.type = "button";
      th.className = `${c.cls} th-sort`;
      th.dataset.sort = c.key;
      th.textContent = c.label;
      th.addEventListener("click", () => {
        // Sizes and dates read best biggest/newest first.
        const first = c.key === "size" || c.key === "mtime" ? -1 : 1;
        this.setSort(c.key, this.sort.key === c.key ? -this.sort.dir : first);
      });
      this.head.append(th);
    }
    const act = document.createElement("span");
    act.className = "th-act";
    this.head.append(act);
  }

  setSort(key, dir) {
    this.sort = { key, dir };
    try { localStorage.setItem(this.storageKey, JSON.stringify(this.sort)); } catch {}
    this.render();
  }

  compare(a, b) {
    // Folders stay above files whatever the order.
    if (!!a.dir !== !!b.dir) return b.dir - a.dir;
    const { key, dir } = this.sort;
    let c = 0;
    if (key !== "name") {
      let x = a[key] ?? "";
      let y = b[key] ?? "";
      if (key === "type") {
        x = a._type;
        y = b._type;
      }
      c = typeof x === "number" && typeof y === "number" ? x - y : String(x).localeCompare(String(y), undefined, { sensitivity: "base" });
    }
    if (c === 0) c = a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: "base" });
    return c * dir;
  }

  /** A new place: new entries, search cleared. */
  show(entries) {
    for (const e of entries) e._type = e.dir ? "Folder" : fileType(e.name, false);
    this.entries = entries;
    this.input.value = "";
    this.filterType = "all";
    this.render();
  }

  render() {
    if (!this.entries) return;
    this.select.value = this.sort.key;
    this.dirBtn.title = this.sort.dir > 0 ? "Ascending" : "Descending";
    this.dirBtn.classList.toggle("desc", this.sort.dir < 0);
    for (const th of this.head.querySelectorAll(".th-sort")) {
      th.classList.toggle("sorted", th.dataset.sort === this.sort.key);
      th.classList.toggle("desc", this.sort.dir < 0);
    }
    const raw = this.input.value.trim();
    const query = raw.toLocaleLowerCase();
    const filter = this.filterType || "all";
    const shown = this.entries
      .filter((e) => {
        if (filter !== "all") {
          const t = e._type;
          if (t !== filter) return false;
        }
        return !query || e.name.toLocaleLowerCase().includes(query);
      })
      .sort((a, b) => this.compare(a, b));

    this.updateFilterChips();

    this.list.replaceChildren();
    if (!shown.length) {
      if (filter !== "all") {
        const plural = { Photo: "photos", Video: "videos", Audio: "audio files", Document: "documents", Folder: "folders" }[filter] || filter.toLowerCase() + "s";
        this.setEmpty(query ? `Nothing matches "${raw}" in ${plural}.` : `No ${plural} found in this folder.`);
      } else {
        this.setEmpty(query ? `Nothing here matches "${raw}".` : this.emptyText());
      }
      return;
    }
    this.setEmpty("");
    // Previews step through the files in the order shown.
    const files = shown.filter((x) => !x.dir);
    for (const e of shown) this.list.appendChild(this.renderRow(e, files));
  }

  focusSearch() {
    this.input.focus();
    this.input.select();
  }
}
FileTable.all = [];

export { FileTable };

/** The shortcut installer runs once: "/" or Ctrl+F searches the open
 *  folder's table (not while typing elsewhere). */
export function installTableShortcuts(getView) {
  document.addEventListener("keydown", (e) => {
    const table = FileTable.all.find((t) => t.view === getView() && !t.tools.hidden);
    if (!table) return;
    const typing = /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement?.tagName || "");
    if ((e.key === "/" && !typing) || ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "f")) {
      e.preventDefault();
      table.focusSearch();
    }
  });
}
