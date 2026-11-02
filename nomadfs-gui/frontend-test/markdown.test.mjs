import test from "node:test";
import assert from "node:assert/strict";
import { isOpenableLink, parseInline, parseMarkdown, renderMarkdown, toggleTask } from "../frontend/markdown.js";
import { all, doc, shape } from "./fake-dom.mjs";

const render = (text, options = {}) => renderMarkdown(text, { doc, ...options });
const types = (text) => parseMarkdown(text).map((b) => b.type);

test("headings, paragraphs and rules", () => {
  assert.deepEqual(types("# One\n\ntext\nmore text\n\n---\n\n###### Six"), ["heading", "paragraph", "rule", "heading"]);
  const [h1, p] = parseMarkdown("# One\n\ntext\nmore");
  assert.equal(h1.level, 1);
  assert.equal(p.lines.length, 2, "single newlines are line breaks");
  assert.equal(parseMarkdown("####### seven")[0].type, "paragraph", "seven #s is not a heading");
  assert.equal(parseMarkdown("#nospace")[0].type, "paragraph");
  assert.equal(shape(render("a\nb")), 'p("a" br "b")');
});

test("inline: bold, italic, strike, code, links", () => {
  assert.equal(shape(render("**b** *i* _u_ ~~s~~ `c`")), 'p(strong("b") " " em("i") " " em("u") " " del("s") " " code("c"))');
  assert.equal(shape(render("**bold *and italic***")), 'p(strong("bold " em("and italic")))');
  assert.deepEqual(parseInline("snake_case_name"), [{ t: "text", v: "snake_case_name" }]);
  assert.deepEqual(parseInline("2 * 3 * 4"), [{ t: "text", v: "2 * 3 * 4" }]);
  assert.deepEqual(parseInline("a \\*not\\* b"), [{ t: "text", v: "a *not* b" }]);
  assert.deepEqual(parseInline("`a*b*c`"), [{ t: "code", v: "a*b*c" }]);
  assert.deepEqual(parseInline("**unclosed"), [{ t: "text", v: "**unclosed" }]);
  const [link] = parseInline("[site](https://example.com/a?b=1)");
  assert.equal(link.t, "link");
  assert.equal(link.href, "https://example.com/a?b=1");
});

test("code blocks keep their text untouched", () => {
  const blocks = parseMarkdown("```js\nconst a = **1**;\n# not a heading\n```\nafter");
  assert.deepEqual(blocks.map((b) => b.type), ["code", "paragraph"]);
  assert.equal(blocks[0].text, "const a = **1**;\n# not a heading");
  assert.equal(blocks[0].lang, "js");
  assert.equal(parseMarkdown("~~~\nopen")[0].text, "open", "an unclosed fence runs to the end");
  assert.equal(shape(render("```\n<b>x</b>\n```")), 'pre(code("<b>x</b>"))');
});

test("bullet, numbered and task lists, with nesting", () => {
  const [list] = parseMarkdown("- a\n  - b\n  - c\n- d");
  assert.equal(list.items.length, 2);
  assert.equal(list.items[0].children[0].items.length, 2);
  const [ordered] = parseMarkdown("3. x\n4. y");
  assert.equal(ordered.ordered, true);
  assert.equal(ordered.start, 3);
  assert.equal(shape(render("1. x\n2. y")), 'ol(li("x") li("y"))');
  const [tasks] = parseMarkdown("- [ ] milk\n- [x] eggs\n* [X] bread\n- plain");
  assert.deepEqual(tasks.items.map((i) => i.task), [false, true, true, null]);
  assert.deepEqual(tasks.items.map((i) => i.line), [0, 1, 2, 3]);
  assert.equal(parseMarkdown("- a\nnot indented")[1].type, "paragraph");
  assert.equal(shape(render("- a\n  continued")), 'ul(li("a" " " "continued"))');
});

test("quotes", () => {
  const [quote] = parseMarkdown("> one\n> two\n\n> three");
  assert.equal(quote.type, "quote");
  assert.equal(quote.lines.length, 2);
  assert.equal(shape(render("> hi")), 'blockquote("hi")');
});

test("text is never markup: <script> and attributes stay text", () => {
  const out = render("<script>alert(1)</script> and <img src=x onerror=alert(1)>\n\n# <b>h</b>\n\n- <i>item</i>\n\n> <u>q</u>");
  const tags = all(out).map((el) => el.tag);
  assert.deepEqual(tags.filter((t) => !["p", "h1", "ul", "li", "blockquote", "br"].includes(t)), []);
  assert.match(shape(out), /"<script>alert\(1\)<\/script> and <img src=x onerror=alert\(1\)>"/);
  const [link] = all(render("[x](javascript:alert(1))")).filter((el) => el.tag === "a");
  assert.equal(link.href, "#", "the href is never the link's target");
  assert.equal(all(render("![img](https://example.com/a.png)")).some((el) => el.tag === "img"), false, "no remote images");
});

test("links open only the web and mail, through onLink", () => {
  assert.equal(isOpenableLink("https://a.b"), true);
  assert.equal(isOpenableLink("HTTP://a.b"), true);
  assert.equal(isOpenableLink("mailto:a@b.c"), true);
  assert.equal(isOpenableLink("javascript:alert(1)"), false);
  assert.equal(isOpenableLink("file:///etc/passwd"), false);
  const clicked = [];
  const [link] = all(render("[go](nomadfs://note/Notes/a.md)", { onLink: (href) => clicked.push(href) })).filter((el) => el.tag === "a");
  let prevented = false;
  link.fire("click", { preventDefault() { prevented = true; } });
  assert.deepEqual(clicked, ["nomadfs://note/Notes/a.md"]);
  assert.equal(prevented, true);
});

test("task boxes report their source line", () => {
  const calls = [];
  const out = render("intro\n\n- [ ] milk\n- [x] eggs", { onToggleTask: (line, checked) => calls.push([line, checked]) });
  const boxes = all(out).filter((el) => el.tag === "input");
  assert.equal(boxes.length, 2);
  assert.equal(boxes[0].checked, false);
  assert.equal(boxes[1].checked, true);
  boxes[0].checked = true;
  boxes[0].fire("change");
  boxes[1].checked = false;
  boxes[1].fire("change");
  assert.deepEqual(calls, [[2, true], [3, false]]);
});

test("toggleTask edits only the checkbox on that line", () => {
  const text = "# T\n\n- [ ] milk\n- [x] eggs\n1. [ ] numbered\nplain [ ] text";
  assert.equal(toggleTask(text, 2, true), "# T\n\n- [x] milk\n- [x] eggs\n1. [ ] numbered\nplain [ ] text");
  assert.equal(toggleTask(text, 3, false), "# T\n\n- [ ] milk\n- [ ] eggs\n1. [ ] numbered\nplain [ ] text");
  assert.equal(toggleTask(text, 4, true), "# T\n\n- [ ] milk\n- [x] eggs\n1. [x] numbered\nplain [ ] text");
  assert.equal(toggleTask(text, 5, true), text, "not a task line");
  assert.equal(toggleTask(text, 99, true), text);
  assert.equal(toggleTask("  - [ ] nested", 0, true), "  - [x] nested");
});

test("the line numbers follow code blocks and blank lines", () => {
  const text = "```\n- [ ] not a task\n```\n\n- [ ] real";
  const lists = parseMarkdown(text).filter((b) => b.type === "list");
  assert.equal(lists.length, 1);
  assert.equal(lists[0].items[0].line, 4);
});

test("CRLF text renders like LF", () => {
  assert.deepEqual(types("# a\r\n\r\n- b\r\n- c"), ["heading", "list"]);
});

test("empty and odd input does not throw", () => {
  assert.deepEqual(parseMarkdown(""), []);
  assert.deepEqual(parseMarkdown("\n\n  \n"), []);
  for (const text of ["*", "**", "`", "[", "[a](", "- ", "> ", "#", "```", "1.", "~~~~", "_ _", "\\", "[a]()"]) assert.doesNotThrow(() => render(text), text);
});

// Notes come from other devices: hostile input must not freeze the page.
const fast = (name, text, limitMs = 500) => {
  const start = performance.now();
  parseMarkdown(text);
  const took = performance.now() - start;
  assert.ok(took < limitMs, `${name}: ${Math.round(took)} ms`);
};

test("crafted long lines parse in linear time", () => {
  const n = 200_000;
  fast("emphasis", " *x".repeat(n / 3));
  fast("links", "[".repeat(n));
  fast("heading", "# a" + " ".repeat(n) + "b");
  fast("fence", "```" + " ".repeat(n) + "a!");
  fast("list", "- " + "[x](".repeat(n / 4));
  fast("many lines", Array(n / 100).fill("*a ".repeat(33) + "[").join("\n"));
  fast("deep lists", Array.from({ length: 2000 }, (_, i) => " ".repeat(i + 1) + "- x").join("\n"));
  assert.doesNotThrow(() => render("- x\n" + Array.from({ length: 2000 }, (_, i) => " ".repeat(i + 1) + "- x").join("\n")));
});

test("lines under the cap that are quadratic for a naive parser stay fast", () => {
  const line = " *x".repeat(3300);
  fast("emphasis lines", Array(200).fill(line).join("\n"), 1000);
  fast("link lines", Array(200).fill("[".repeat(9900)).join("\n"), 1000);
});

test("oversized lines and notes are shown as plain text", () => {
  const long = "**b** " + "x".repeat(10_000);
  assert.deepEqual(parseMarkdown(long)[0].lines[0], [{ t: "text", v: long }]);
  const huge = ("**b** word\n").repeat(100_000);
  assert.deepEqual(parseMarkdown(huge)[0].lines[0], [{ t: "text", v: "**b** word" }]);
  assert.equal(shape(render("**b** short")), 'p(strong("b") " short")');
});

test("emphasis behaves the same with the closer cache", () => {
  assert.equal(shape(render("*a* and *b* and **c** **d**")), 'p(em("a") " and " em("b") " and " strong("c") " " strong("d"))');
  assert.equal(shape(render("*a b *c* d*")), 'p(em("a b *c") " d*")', "unchanged from before the cache");
  assert.equal(shape(render("*x *y")), 'p("*x *y")');
  assert.equal(shape(render("***a***")), 'p(strong(em("a")))');
});
