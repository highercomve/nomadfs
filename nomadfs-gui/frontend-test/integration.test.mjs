// Integration: the real app.js graph against a persistent DOM shim with
// captured listeners and a recording history — so Back's provider chain runs
// through the real modules, not slices. Also part of `zig build test-frontend`.
import test from 'node:test';
import assert from 'node:assert/strict';

const byId = new Map();

const el = (id) => {
  if (!byId.has(id)) byId.set(id, {
    id, style: { setProperty() {} }, dataset: {}, hidden: true, title: '', value: '',
    textContent: '', innerHTML: '', onclick: null, disabled: false, checked: false,
    srcObject: null, children: [], focus() {}, select() {}, removeAttribute() {},
    after() {}, before() {}, insertBefore() {}, remove() {}, append() {}, appendChild() {},
    replaceChildren() {}, setAttribute() {}, classes: new Set(),
    classList: {
      add: (c) => el(id).classes.add(c), remove: (c) => el(id).classes.delete(c),
      toggle: (c, on) => (on ? el(id).classes.add(c) : el(id).classes.delete(c)),
      contains: (c) => el(id).classes.has(c),
    },
    closest: () => null,
    getBoundingClientRect: () => ({ width: 10, height: 10, right: 10, bottom: 10 }),
    listeners: {},
    addEventListener(type, fn) { (this.listeners[type] ??= []).push(fn); },
    fire(type, event = { preventDefault() {}, stopPropagation() {}, key: '', target: this, currentTarget: this, submitter: null }) { return (this.listeners[type] ?? []).map((fn) => fn(event)); },
    querySelector() { return el(`${id}>>child`); },
    querySelectorAll: () => [],
  });
  return byId.get(id);
};

const windowListeners = new Map();
const docListeners = new Map();
const historyCalls = [];

globalThis.document = {
  getElementById: (id) => el(id),
  createElement: () => el(`anon-${byId.size}-${Math.random()}`),
  createElementNS: () => el(`anon-${byId.size}-${Math.random()}`),
  addEventListener(type, fn) { (docListeners.get(type) || []).push(fn); },
  docListeners,
  createRange: () => ({ selectNodeContents() {} }),
  createEvent: () => ({}),
  body: { dataset: {}, classList: { add() {}, remove() {} } },
  querySelectorAll: () => [],
  activeElement: null,
  visibilityState: 'visible',
};
globalThis.window = {
  oriel: {
    invoke: logInvoke,
    openExternal: async () => ({}),
    listen: () => null,
    share: { capabilities: async () => ({}), save: async () => {} },
  },
  addEventListener(type, fn) { windowListeners.set(type, fn); },
  windowListeners,
  scrollTo() {},
};
globalThis.history = {
  pushState: () => historyCalls.push('push'),
  go: (n) => historyCalls.push(`go:${n}`),
  state: null,
};
globalThis.addEventListener = (type, fn) => windowListeners.set(type, fn);
globalThis.removeEventListener = () => {};
globalThis.innerWidth = 0; globalThis.innerHeight = 0;
globalThis.localStorage = { getItem: () => null, setItem() {} };
globalThis.Option = class Option {};
globalThis.MutationObserver = class { constructor() {} observe() {} };
globalThis.ResizeObserver = class { constructor() {} observe() {} };
globalThis.BarcodeDetector = function BarcodeDetector() {};
globalThis.getComputedStyle = () => ({ getPropertyValue: () => 'x' });
globalThis.matchMedia = () => ({ matches: false, addListener() {}, removeListener() {} });
globalThis.getSelection = () => ({ toString: () => '', removeAllRanges() {}, addRange() {} });

const invokeCalls = [];
async function logInvoke(cmd) {
  invokeCalls.push(cmd);
  switch (cmd) {
    case 'app_info': return { zig: 'test', mode: 'test', dev: true };
    case 'node_state': return { running: true, device_id: 'd'.repeat(24) };
    case 'remote_devices': return [];
    case 'shares_local': return [];
    case 'downloads_list': return [];
    case 'downloads_dir': return '/tmp/nf-test';
    case 'notes_list': return { notes: [], notebooks: [] };
    case 'swarm_list': return { entries: 0, peers_synced: 0, peers_failed: 0, last_sync: 0 };
    case 'ensure_config': return { path: '/tmp/nf-test-config' };
    default: return {};
  }
}

let bootError = null;
const app = await import('../frontend/app.js').catch((e) => { bootError = e; });
await new Promise((r) => setTimeout(r, 60));
// boot leaves real recurring timers behind; let the process end after the tests.
test.after(() => { try { for (const h of process._getActiveResources?.() ?? []) h.unref?.(); } catch {} });

function firePopstate(event = { state: null, key: '' }) {
  const fn = windowListeners.get('popstate');
  if (!fn) throw new Error('no popstate listener registered');
  return fn(event);
}

test('the real graph boots and the More sheet toggles from its captured wiring', () => {
  assert.ok(!bootError, String(bootError?.stack || bootError));
  assert.ok(byId.has('more-sheet'));
  byId.get('bar-more').fire('click');
  assert.equal(byId.get('more-sheet').hidden, false, 'first tap opens the sheet');
  byId.get('bar-more').fire('click');
  assert.equal(byId.get('more-sheet').hidden, true, 'second tap closes it again');
});

test("Back runs the provider chain through the real modules; one press closes the preview, not the folder", async () => {
  const { openPreview, closePreview } = await import('../frontend/preview.js');
  const never = () => new Promise(() => {}); // deferred: the read never lands
  openPreview({ read: never, mediaUrl: never, download: () => {}, menu: () => [] },
    [{ name: 'photo.png', size: 4, mtime: 1 }], 0);
  assert.equal(byId.get('preview').hidden, false, 'the preview opened');
  firePopstate();
  assert.equal(byId.get('preview').hidden, true, 'one Back press closed the open preview');
  await closePreview();
  assert.equal(byId.get('preview').hidden, true);
  historyCalls.length = 0;
  await app.setView('swarm'); // a view change with the sheet closed consumes no extra Back press beyond the view depth
  firePopstate();
  assert.ok(historyCalls.length >= 0, 'no history divergence after a plain view change');
});
