// A small, safe Markdown renderer for notes.
//
// `parseMarkdown` turns text into a plain tree (no DOM, testable in Node);
// `renderMarkdown` builds DOM nodes from it. Text only ever reaches the page
// through text nodes: there is no innerHTML, no HTML passthrough and no
// remote images. Anything that isn't one of the constructs below is shown as
// the text it is.
//
// Constructs: headings, paragraphs, **bold**, *italic* / _italic_, ~~strike~~,
// `inline code`, fenced code blocks, [links](https://…), bullet, numbered and
// task lists (one level of nesting per two spaces), > quotes, horizontal rules.

// Notes come from other devices, so every pattern below is written to run in
// linear time on hostile input (no nested or overlapping quantifiers), and
// oversized input is shown as plain text instead of being parsed.
const MAX_LINE = 10_000; // a longer line is shown as plain text
const MAX_NOTE = 1_000_000; // in a longer note no line gets inline markup
const MAX_INLINE_DEPTH = 16; // nesting of emphasis and link text
const MAX_LIST_DEPTH = 16; // nesting of lists
const MAX_LINK_TEXT = 500;
const MAX_HREF = 500;

const FENCE = /^\s{0,3}(```|~~~)\s*(?:([\w+-]+)\s*)?$/;
const HEADING = /^\s{0,3}(#{1,6})\s+(.*)$/;
const LINK = new RegExp(`\\[([^\\[\\]]{1,${MAX_LINK_TEXT}})\\]\\(\\s*([^)\\s]{1,${MAX_HREF}})\\s*\\)`, "y");
const RULE = /^\s{0,3}([-*_])(?:\s*\1){2,}\s*$/;
const QUOTE = /^\s{0,3}>\s?(.*)$/;
const ITEM = /^(\s*)([-*+]|\d{1,9}[.)])\s+(.*)$/;
const TASK = /^\[([ xX])\]\s+(.*)$/;
const ESCAPABLE = /[\\`*_{}[\]()#+\-.!~>|]/;

/** Block structure of `text`. Every block that can be edited from the
 *  preview (a task item) carries `line`, its 0-based source line. */
export function parseMarkdown(text) {
  const source = String(text);
  const lines = source.replace(/\r\n?/g, "\n").split("\n");
  const inline = source.length > MAX_NOTE ? plainInline : parseInline;
  const blocks = [];
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (!line.trim()) { i += 1; continue; }

    const fence = FENCE.exec(line);
    if (fence) {
      const body = [];
      i += 1;
      while (i < lines.length && !lines[i].trimStart().startsWith(fence[1])) { body.push(lines[i]); i += 1; }
      i += 1; // the closing fence (or the end of the text)
      blocks.push({ type: "code", lang: fence[2] ?? "", text: body.join("\n") });
      continue;
    }
    const heading = HEADING.exec(line);
    if (heading) {
      blocks.push({ type: "heading", level: heading[1].length, inline: inline(heading[2].trimEnd().replace(/\s#+$/, "")) });
      i += 1;
      continue;
    }
    if (RULE.test(line)) { blocks.push({ type: "rule" }); i += 1; continue; }
    if (QUOTE.test(line)) {
      const quoted = [];
      while (i < lines.length && QUOTE.test(lines[i])) { quoted.push(inline(QUOTE.exec(lines[i])[1])); i += 1; }
      blocks.push({ type: "quote", lines: quoted });
      continue;
    }
    if (ITEM.test(line)) {
      const [list, next] = parseList(lines, i, inline);
      blocks.push(list);
      i = next;
      continue;
    }
    const para = [];
    while (i < lines.length && lines[i].trim() && !startsBlock(lines[i])) { para.push(inline(lines[i].trim())); i += 1; }
    if (para.length === 0) { para.push(inline(line.trim())); i += 1; }
    blocks.push({ type: "paragraph", lines: para });
  }
  return blocks;
}

function startsBlock(line) {
  return FENCE.test(line) || HEADING.test(line) || RULE.test(line) || QUOTE.test(line) || ITEM.test(line);
}

/** The list starting at `lines[start]`, and the index after it. Nesting
 *  follows indentation: an item indented deeper than the one before it is
 *  that item's child list. */
function parseList(lines, start, inline) {
  const newList = (marker) => {
    const ordered = /\d/.test(marker[0]);
    return { type: "list", ordered, start: ordered ? parseInt(marker, 10) : 1, items: [] };
  };
  let root = null;
  const stack = []; // the open lists, outermost first, with their indent
  let last = null;
  let i = start;
  while (i < lines.length) {
    const m = ITEM.exec(lines[i]);
    if (!m) {
      // An indented line under an item continues it.
      if (last && /^\s{2,}\S/.test(lines[i]) && !startsBlock(lines[i])) {
        last.inline.push({ t: "text", v: " " }, ...inline(lines[i].trim()));
        i += 1;
        continue;
      }
      break;
    }
    const indent = m[1].replace(/\t/g, "    ").length;
    if (stack.length === 0) {
      root = newList(m[2]);
      stack.push({ indent, list: root });
    } else if (indent > stack[stack.length - 1].indent && stack.length < MAX_LIST_DEPTH) {
      const child = newList(m[2]);
      last.children.push(child);
      stack.push({ indent, list: child });
    } else {
      while (stack.length > 1 && indent < stack[stack.length - 1].indent) stack.pop();
    }
    const task = TASK.exec(m[3]);
    last = {
      line: i,
      task: task ? task[1] !== " " : null,
      inline: inline(task ? task[2] : m[3]),
      children: [],
    };
    stack[stack.length - 1].list.items.push(last);
    i += 1;
  }
  return [root, i];
}

const plainInline = (source) => (source ? [{ t: "text", v: source }] : []);

/** Inline structure: { t: "text" | "code" | "strong" | "em" | "del" | "link" }.
 *  A line over MAX_LINE characters, or nesting past MAX_INLINE_DEPTH, is text. */
export function parseInline(source, depth = 0) {
  if (source.length > MAX_LINE || depth > MAX_INLINE_DEPTH) return plainInline(source);
  const out = [];
  const closers = new Map(); // marker -> last closer search, reused while still valid
  let buf = "";
  let i = 0;
  const flush = () => { if (buf) { out.push({ t: "text", v: buf }); buf = ""; } };
  while (i < source.length) {
    const c = source[i];
    if (c === "\\" && i + 1 < source.length && ESCAPABLE.test(source[i + 1])) { buf += source[i + 1]; i += 2; continue; }
    if (c === "`") {
      const end = source.indexOf("`", i + 1);
      if (end > i + 1) { flush(); out.push({ t: "code", v: source.slice(i + 1, end) }); i = end + 1; continue; }
    }
    if (c === "[") {
      LINK.lastIndex = i;
      const m = LINK.exec(source);
      if (m) { flush(); out.push({ t: "link", href: m[2], c: parseInline(m[1], depth + 1) }); i += m[0].length; continue; }
    }
    const marker = emphasisAt(source, i);
    if (marker) {
      const end = closingMarker(source, marker, i + marker.length, closers);
      if (end > 0) {
        flush();
        const t = marker === "**" ? "strong" : marker === "~~" ? "del" : "em";
        out.push({ t, c: parseInline(source.slice(i + marker.length, end), depth + 1) });
        i = end + marker.length;
        continue;
      }
    }
    buf += c;
    i += 1;
  }
  flush();
  return out;
}

function emphasisAt(s, i) {
  for (const marker of ["**", "~~", "*", "_"]) {
    if (!s.startsWith(marker, i)) continue;
    // "_" inside a word (snake_case) is not emphasis.
    if (marker === "_" && i > 0 && /\w/.test(s[i - 1])) return null;
    // "*" next to "*" belongs to the longer marker, tried first.
    const after = s[i + marker.length];
    if (after === undefined || /\s/.test(after)) return null;
    return marker;
  }
  return null;
}

/** Index of the marker that closes the one opened before `from`, or -1.
 *  The first valid closer after `from` is also the first after any later
 *  `from` up to it (and "none" stays none), so `cache` keeps one scan per
 *  marker and the whole line is scanned about once. */
function closingMarker(s, marker, from, cache) {
  let hit = cache.get(marker);
  if (!hit || from < hit.from || (hit.raw !== -1 && from >= hit.raw)) {
    hit = { from, raw: scanCloser(s, marker, from) };
    cache.set(marker, hit);
  }
  const j = hit.raw;
  // "***" closes an inner * first, then the **: the last two are the strong's.
  return j !== -1 && marker === "**" && s[j + 2] === "*" ? j + 1 : j;
}

function scanCloser(s, marker, from) {
  let j = from;
  while ((j = s.indexOf(marker, j)) !== -1) {
    const before = s[j - 1];
    const escaped = before === "\\";
    const spaced = before === undefined || /\s/.test(before);
    const longer = (marker === "*" || marker === "_") && (s[j + 1] === marker || before === marker);
    const inWord = marker === "_" && /\w/.test(s[j + 1] ?? "");
    if (j > from && !escaped && !spaced && !longer && !inWord) return j;
    j += longer ? 2 : 1;
  }
  return -1;
}

/** `text` with the checkbox on source line `line` set; unchanged if that line
 *  isn't a task item. */
export function toggleTask(text, line, checked) {
  const lines = String(text).split("\n");
  if (line < 0 || line >= lines.length) return text;
  const replaced = lines[line].replace(/^(\s*(?:[-*+]|\d{1,9}[.)])\s+)\[[ xX]\]/, `$1[${checked ? "x" : " "}]`);
  if (replaced === lines[line]) return text;
  lines[line] = replaced;
  return lines.join("\n");
}

/** Where a link may lead: the web and mail open outside the app. */
export function isOpenableLink(href) {
  return /^(https?:\/\/|mailto:)/i.test(href);
}

/** Builds the rendered note as a DocumentFragment.
 *  `onToggleTask(line, checked)`: a task box was ticked in the preview.
 *  `onLink(href)`: a link was clicked (default: web and mail links open
 *  outside the app, everything else does nothing). */
export function renderMarkdown(text, { onToggleTask = () => {}, onLink = defaultLink, doc = globalThis.document } = {}) {
  const fragment = doc.createDocumentFragment();
  for (const block of parseMarkdown(text)) fragment.append(renderBlock(block, { onToggleTask, onLink, doc }));
  return fragment;
}

function defaultLink(href) {
  if (isOpenableLink(href)) globalThis.window?.oriel?.openExternal?.(href);
}

function renderBlock(block, ctx) {
  const { doc } = ctx;
  const make = (tag, className) => { const el = doc.createElement(tag); if (className) el.className = className; return el; };
  switch (block.type) {
    case "heading": {
      const el = make(`h${block.level}`);
      el.append(renderInline(block.inline, ctx));
      return el;
    }
    case "paragraph": {
      const el = make("p");
      appendLines(el, block.lines, ctx);
      return el;
    }
    case "quote": {
      const el = make("blockquote");
      appendLines(el, block.lines, ctx);
      return el;
    }
    case "code": {
      const pre = make("pre");
      const code = make("code");
      if (block.lang) code.className = `lang-${block.lang}`;
      code.textContent = block.text;
      pre.append(code);
      return pre;
    }
    case "rule": return make("hr");
    case "list": return renderList(block, ctx);
    default: return make("p");
  }
}

function appendLines(el, lines, ctx) {
  lines.forEach((inline, index) => {
    if (index > 0) el.append(ctx.doc.createElement("br"));
    el.append(renderInline(inline, ctx));
  });
}

function renderList(list, ctx) {
  const { doc } = ctx;
  const el = doc.createElement(list.ordered ? "ol" : "ul");
  if (list.ordered && list.start !== 1) el.start = list.start;
  for (const item of list.items) {
    const li = doc.createElement("li");
    if (item.task !== null) {
      li.className = "task";
      const box = doc.createElement("input");
      box.type = "checkbox";
      box.checked = item.task;
      box.addEventListener("change", () => ctx.onToggleTask(item.line, box.checked));
      li.append(box, doc.createTextNode(" "));
    }
    li.append(renderInline(item.inline, ctx));
    for (const child of item.children) li.append(renderList(child, ctx));
    el.append(li);
  }
  return el;
}

function renderInline(nodes, ctx) {
  const { doc } = ctx;
  const fragment = doc.createDocumentFragment();
  for (const node of nodes) {
    switch (node.t) {
      case "text": fragment.append(doc.createTextNode(node.v)); break;
      case "code": { const el = doc.createElement("code"); el.textContent = node.v; fragment.append(el); break; }
      case "strong": case "em": case "del": {
        const el = doc.createElement(node.t);
        el.append(renderInline(node.c, ctx));
        fragment.append(el);
        break;
      }
      case "link": {
        const el = doc.createElement("a");
        el.append(renderInline(node.c, ctx));
        el.href = "#";
        el.title = node.href;
        el.addEventListener("click", (event) => { event.preventDefault(); ctx.onLink(node.href); });
        fragment.append(el);
        break;
      }
      default: break;
    }
  }
  return fragment;
}
