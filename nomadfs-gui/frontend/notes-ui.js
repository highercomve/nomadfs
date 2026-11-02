// Shared by the parts of the Notes screen: element helpers, the small modal
// question, the banner above the editor, and where the row menu opened.

export const draftKey = (path) => `note-draft:${path}`;

/** deps: the page's helpers (see initNotes). */
export function createUi(deps) {
  const { icons, svg, showMenu } = deps;
  const $ = (id) => document.getElementById(id);
  const banner = $("notes-banner");

  const el = (tag, props = {}, ...children) => {
    const node = document.createElement(tag);
    for (const [key, value] of Object.entries(props)) {
      if (key === "class") node.className = value;
      else if (key === "text") node.textContent = value;
      else if (key.startsWith("on")) node.addEventListener(key.slice(2), value);
      else if (value !== undefined && value !== false) node.setAttribute(key, value === true ? "" : value);
    }
    node.append(...children.filter((child) => child != null));
    return node;
  };
  const button = (text, onclick, cls = "btn text") => el("button", { type: "button", class: cls, onclick, text });
  const iconButton = (name, label, onclick) => {
    const node = el("button", { type: "button", class: "icon-btn", "aria-label": label, title: label, onclick });
    node.append(svg(icons[name]));
    return node;
  };
  const here = () => deps.deviceName();
  const parentDir = (path) => path.split("/").slice(0, -1).join("/");

  /** Where the row menu opened (a submenu opens there). */
  const menuAt = { x: 80, y: 80 };
  const openMenu = (x, y, items) => {
    menuAt.x = x;
    menuAt.y = y;
    showMenu(x, y, items);
  };

  /** A small modal question with one text field. Resolves to the text, or
   *  null when cancelled. */
  function ask({ title, text = "", label, ok, value = "", paste = false }) {
    const dialog = $("notes-dialog");
    $("notes-dialog-title").textContent = title;
    $("notes-dialog-text").textContent = text;
    $("notes-dialog-text").hidden = !text;
    $("notes-dialog-label").textContent = label;
    $("notes-dialog-ok").textContent = ok;
    $("notes-dialog-paste").hidden = !paste;
    const input = $("notes-dialog-input");
    input.value = value;
    return new Promise((resolve) => {
      let answer = null;
      const done = () => { dialog.removeEventListener("close", done); resolve(answer); };
      dialog.addEventListener("close", done);
      $("notes-dialog-form").onsubmit = () => { answer = input.value.trim(); };
      $("notes-dialog-cancel").onclick = () => dialog.close();
      $("notes-dialog-paste").onclick = async () => {
        try { input.value = (await navigator.clipboard.readText()).trim(); } catch { deps.snack("Clipboard unavailable: paste with Ctrl+V"); }
      };
      dialog.showModal();
      input.focus();
      input.select();
    });
  }

  /** `parts`: nodes and strings. */
  function showBanner(kind, ...parts) {
    banner.replaceChildren(...parts.map((part) => (typeof part === "string" ? document.createTextNode(part) : part)));
    banner.className = `note-banner ${kind}`;
    banner.hidden = false;
  }
  function hideBanner() {
    banner.hidden = true;
    banner.replaceChildren();
  }
  const strong = (text) => el("strong", { text });
  const actions = (...buttons) => el("span", { class: "note-banner-actions" }, ...buttons);

  return { $, el, button, iconButton, here, parentDir, menuAt, openMenu, ask, showBanner, hideBanner, strong, actions, narrow: matchMedia("(max-width: 839px)") };
}
