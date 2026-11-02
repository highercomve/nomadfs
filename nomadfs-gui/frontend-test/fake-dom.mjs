// Just enough of the DOM for renderMarkdown: elements, text nodes,
// fragments, attributes and listeners. innerHTML is deliberately missing, so
// a renderer that used it would throw.
class Node {
  constructor() { this.children = []; this.listeners = {}; this.parent = null; }
  append(...nodes) {
    for (const node of nodes) {
      if (node instanceof Fragment) { for (const child of [...node.children]) this.append(child); continue; }
      node.parent = this;
      this.children.push(node);
    }
  }
  addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); }
  fire(type, event = { preventDefault() {} }) { for (const fn of this.listeners[type] || []) fn(event); }
}
class Fragment extends Node {}
class Text extends Node { constructor(value) { super(); this.value = value; } }
class Element extends Node {
  constructor(tag) { super(); this.tag = tag; this.className = ""; this.attrs = {}; }
  set textContent(value) { this.children = [new Text(value)]; }
  get textContent() { return this.children.map((c) => c.value ?? c.textContent).join(""); }
}
export const doc = {
  createDocumentFragment: () => new Fragment(),
  createElement: (tag) => new Element(tag),
  createTextNode: (value) => new Text(value),
};
/** Elements of a tree, depth first. */
export function all(node, out = []) {
  for (const child of node.children) { if (child instanceof Element) out.push(child); all(child, out); }
  return out;
}
/** A compact string of the tree: "p(text, strong(bold))". */
export function shape(node) {
  return node.children.map((c) => (c instanceof Text ? JSON.stringify(c.value) : `${c.tag}${c.children.length ? `(${shape(c)})` : ""}`)).join(" ");
}
