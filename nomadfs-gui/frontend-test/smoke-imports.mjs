// Smoke: import the real entry (app.js) with a fake Oriel + DOM shim. All the
// module top-level code runs as it would in the browser; boot() runs against
// fakes, so this validates the import graph and wiring.
const stub = new Proxy(function () {}, { get: () => stub, apply: () => stub });

const el = () => {
  const o = {
    style: { setProperty() {} },
    dataset: {}, classList: { add() {}, remove() {}, toggle() {}, contains() { return false; } },
    hidden: false, title: '', value: '', textContent: '', closest: () => ({ style: { setProperty() {} } }),
    replaceChildren() {}, appendChild() {}, append() {}, addEventListener() {}, setAttribute() {}, removeAttribute() {}, after() {}, before() {}, insertBefore() {}, remove() {}, children: [],
    querySelector: () => el(), querySelectorAll: () => [], focus() {}, select() {},
    getBoundingClientRect: () => ({ right: 0, bottom: 0 }),
    onclick: null, disabled: false, checked: false, srcObject: null, innerHTML: '',
  };
  return o;
};

globalThis.document = {
  getElementById: () => el(),
  createElement: () => el(),
  createElementNS: () => el(),
  addEventListener: () => {},
  createRange: () => ({ selectNodeContents(){} }),
  body: { dataset: {}, classList: { add() {}, remove() {} } },
  querySelectorAll: () => [],
  createEvent: () => stub,
  activeElement: null,
};
globalThis.window = {
  oriel: { invoke: async (cmd) => ({
    // Minimal but honest answers, so the smoke run can render the swarm and
    // downloads screens for real (the bare-global `running` slips happened
    // exactly on those paths).
    app_info: { zig: "0.16.0", mode: "release", dev: false },
    node_state: { running: true, device_id: "x".repeat(24) },
    remote_devices: [],
    notes_list: { notes: [], notebooks: ["Daily"] },
    swarm_list: { entries: 2, peers_synced: 0, last_sync: 0, peers_failed: 0, items: [
      { name: "a.png", path: "a.png", dir: false, size: 5, mtime: 1700000000, cid: "cc", author: "", author_id: "aa" },
      { name: "sub", path: "sub", dir: true, size: 0, mtime: 0, cid: "dd", author: "", author_id: "aa" },
    ] },
    downloads_list: [ { id: 1, name: "f.png", cid: "c", size: 5, done: 5, state: "done", exists: true, path: "/tmp/f.png", source_id: "peer" } ],
    downloads_dir: "/tmp",
    shares_local: [],
  })[cmd] ?? {}, listen: () => null, extensions: null, openExternal: async () => ({}), platform: {}, share: { capabilities: async () => ({}), save: async () => {} },},
  addEventListener: () => {}, scrollTo: () => {}, open: () => null,
};
globalThis.history = { pushState() {}, go() {} };
globalThis.innerWidth = 0; globalThis.innerHeight = 0;
globalThis.addEventListener = () => {};
globalThis.localStorage = { getItem: () => null, setItem() {} };

globalThis.Option = class Option {};
globalThis.MutationObserver = class MutationObserver { observe() {} };
globalThis.BarcodeDetector = Object; // scannerAvailable resolves via getSupportedFormats().includes
globalThis.ResizeObserver = class { observe() {} };
globalThis.getComputedStyle = () => ({ getPropertyValue: () => '#888' });
globalThis.matchMedia = () => el();
globalThis.getSelection = () => ({ toString: () => '', removeAllRanges() {}, addRange() {} });
Object.defineProperty(globalThis, 'navigator', { value: { clipboard: { writeText: async () => {} } }, configurable: true });

try {
  const rejects = [];
  process.on('unhandledRejection', (r) => { const e = r && r.stack ? r : new Error(String(r)); rejects.push(String(e.stack).split('\n').slice(0, 5).join(' | ')); });
  const root = await import('../frontend/app.js');
  await new Promise((r) => setTimeout(r, 100));
  // Render the screens the boot path skips at these fake answers.
  root.setView('swarm');
  await new Promise((r) => setTimeout(r, 100));
  root.setView('downloads');
  await new Promise((r) => setTimeout(r, 100));
  console.log('SMOKE OK');
  if (rejects.length) {
    console.log('SMOKE REJECTED:', rejects.join(' | '));
    process.exit(1);
  }
  process.exit(0);
} catch (err) {
  console.log('SMOKE FAILED:', String(err).slice(0, 300));
  if (err.stack) console.log('AT', err.stack.split('\n').slice(1, 6).join(' | '));
  if (err.context) console.log('AT', String(err.context).slice(0, 120));
  process.exit(1);
}
