import {readdirSync, readFileSync} from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import { longPress } from '../frontend/selection.js';
import { isRunning, setRunning, onNodeChange, nodeSession } from '../frontend/state.js';
import { planUpload, sendUpload, progressText, uploadedText, folderAddedText } from '../frontend/uploads.js';
// The app is split into ES modules; the tested functions are extracted from
// whichever module holds them, in alphabetical file order.
const dir = new URL('../frontend/', import.meta.url);
const source = readdirSync(dir).filter((f) => f.endsWith('.js')).sort().map((f) => readFileSync(new URL(f, dir), 'utf8')).join('\n');
const raw = (start,end) => source.slice(source.indexOf(start),source.indexOf(end,source.indexOf(start)));
const fn = (start,end) => raw(start,end).replace(/^export /gm, '');
// (modules' export keywords are stripped in the extracted VM slices)
const deferred = () => {let resolve,reject; const promise=new Promise((a,b)=>{resolve=a;reject=b});return {promise,resolve,reject}};
const elements = new Map();
const node = () => { const n = { style:{setProperty(){}}, dataset:{}, classList:{toggle(){},add(){},remove(){}}, hidden:false, closest:()=>({style:{setProperty(){}}}), append(){}, appendChild(){}, replaceChildren(){}, addEventListener(){}, setAttribute(){}, removeAttribute(){}, after(){}, before(){}, insertBefore(){}, remove(){}, children:[], querySelector:()=>node(), querySelectorAll:()=>[], focus(){}, select(){}, title:'' }; return n; };
const el = id => {if(!elements.has(id)) elements.set(id,node());return elements.get(id)};
const context = extra => vm.createContext({console, $, ...extra});
function $(id){return el(id)}
// Source functions are evaluated unchanged; only DOM/IPC dependencies are fakes.
{
 const a=deferred(),b=deferred(),paint=[];
 const c=context({document:{body:{classList:{add(){},remove(){}}},dispatchEvent(){}},CustomEvent:class{},syncBack(){},stopNative(){},attachZoom(){},nativeVideo:null,
 previewMessage(){},readFailure:String,inPagePlayer:(kind,url)=>paint.push(url),a,b});
 vm.runInContext('let pv=null; let previewGeneration=0;'+fn('function openPreview(', '/** Stops a streaming player')+fn('function stopMedia(', '// The native player:')+fn('async function streamPreview(', '// The native player, embedded')+`function showPreview(){const token=++pv.token;streamPreview(pv.files[0],'audio',token)};openPreview({mediaUrl:()=>a.promise},[{name:'A'}],0);closePreview();openPreview({mediaUrl:()=>b.promise},[{name:'B'}],0);`,c);
 b.resolve('B-url');await new Promise(setImmediate);a.resolve('A-url');await new Promise(setImmediate);
 assert.deepEqual(paint,['B-url']);
}
{
 const a=deferred();let shown;
 const c=context({a,busy(){},snack(){},invoke:()=>a.promise,showLocation(){shown=vm.runInContext('path',c)}});
 vm.runInContext(`let browseNav=0;let path=[{name:'A',device:{peer:'A'}}];`+fn('async function refreshLocation(', '/** Wiring attaches once')+`const pending=refreshLocation();path=[{name:'B',device:{peer:'B'}}];browseNav++;`,c);
 a.resolve([{peer:'A',shares:[]}]);await vm.runInContext('pending',c);
 assert.equal(shown,undefined);
}
{
 elements.clear();const a=deferred(), b=deferred();
 const c=context({invoke:(cmd)=>cmd==='file_details'?a.promise:b.promise,errText:String});
 vm.runInContext('let detailsGeneration=0;'+fn('async function openDetails(', 'function drawChunkMap(')+fn('async function openDeviceInfo(', '/** Wiring attaches once')+`const pending=openDetails('File A',{});openDeviceInfo('Device B','B');`,c);
 a.reject(new Error('old file request failed'));await vm.runInContext('pending',c);
 assert.equal(el('dt-name').textContent,'Device B');assert.equal(el('dt-meta').textContent,'Asking the device…');
}
{
 elements.clear();const dirs=[];
 const c=context({swarmCrumbs(){},isRunning:()=>true,running:true,listLoading(){},listLoaded(){},snack(){},swarmStatusText(){return 'ok'},swarmTable:{dir:null,show(){},render(){}},swarmSel:{leave(){},retain(){}},swarmSelBar(){},invoke:async(cmd,args)=>{dirs.push(args.dir);return {items:[]}}});
 vm.runInContext(`let swarmDir='New folder',swarmNav=0;`+fn('async function loadSwarm(', 'let swarmTable = null;')+`const pending=loadSwarm();`,c);
 await vm.runInContext('pending',c);assert.deepEqual(dirs,['New folder']);assert.equal(vm.runInContext('swarmDir',c),'New folder');
}

test('glm-3 askDialog queues shared handlers', async () => {
  elements.clear();
  for (const id of ['ask-ok','ask-input']) Object.assign(el(id), {focus(){},setSelectionRange(){},classList:{toggle(){}}});
  const c=context({});
  vm.runInContext('let askQueue=Promise.resolve();'+fn('function askDialog(', '/** All the document-level menu wiring')+"const first=askDialog({title:'First'});const second=askDialog({title:'Second'});",c);
  await new Promise(setImmediate);
  assert.equal(el('ask-title').textContent,'First');
  el('ask-form').onsubmit({preventDefault(){}});
  await new Promise(setImmediate);
  assert.equal(el('ask-title').textContent,'Second');
  el('ask-form').onsubmit({preventDefault(){}});
  assert.equal(await vm.runInContext('first',c),true);
  assert.equal(await vm.runInContext('second',c),true);
});
test('glm-10 downloads errors preserve destination', async () => {
  el('downloads-where').textContent='Saved in here';
  const messages=[];
  const c=context({invoke:async()=>{throw 'failure'},snack:x=>messages.push(x),errText:x=>'formatted '+x,renderDownloads(){}});
  vm.runInContext(fn('async function loadDownloads(', '/** The download progress events'),c);
  await vm.runInContext('loadDownloads()',c);
  assert.equal(el('downloads-where').textContent,'Saved in here');
  assert.deepEqual(messages,["Couldn't load downloads: formatted failure"]);
});
test('glm-7 downloads dedupe source and name', async () => {
  const downloads=new Map([[1,{state:'running',source_id:'A',cid:'X',name:'f'}]]), calls=[], messages=[];
  const c=context({downloads,invoke:async(cmd,args)=>{calls.push(args);return {id:2,name:'f'}},snack:x=>messages.push(x),renderDownloads(){},goToDownloads(){}});
  vm.runInContext(fn('async function startDownload(', 'function downloadFile('),c);
  await vm.runInContext("startDownload('download',{peer:'B',cid:'X',name:'f'})",c);
  await vm.runInContext("startDownload('download',{peer:'A',cid:'X',name:'f'})",c);
  assert.equal(calls.length,1);
  assert.match(messages.at(-1),/already downloading/);
});

// Permissive DOM node for the larger slices below (shared with el() above).
test('glm-1 invite panels swap for real', () => {
  elements.clear();
  const c = context({});
  vm.runInContext(fn('function renderInvite(', 'async function pollInvite()'), c);
  vm.runInContext("renderInvite({state:'joined',peer:'X'})", c);
  assert.equal(el('invite-idle').hidden, true);
  assert.equal(el('invite-active').hidden, false);
  assert.equal(el('invite-label').textContent, 'X joined');
  vm.runInContext("renderInvite({state:'none'})", c);
  assert.equal(el('invite-idle').hidden, false);
  assert.equal(el('invite-active').hidden, true);
});
test('glm-5 pdf iframe is sandboxed; glm-6 buffer holds the exact bytes without copying', async () => {
  const created = [];
  const makeNode = () => { const n = node(); created.push(n); return n; };
  const blobs = [];
  const c = context({ attachZoom() {},
    document: { createElement: makeNode, body: { classList: { add(){}, remove(){} } } },
    stopMedia(){}, stopNative(){},
    formatSize: (n) => `${n}B`, formatDate: () => 'date',
    kindOf: () => ({ kind: 'document', ext: 'bin' }),
    KINDS: { document: { max: 1e9 } }, RANGE: 16, MIME: {},
    readFailure: String,
    previewMessage: () => node(),
    decodeBase64: (b64) => new Uint8Array(Buffer.from(b64, 'base64')),
    Blob: class { constructor(parts, opts){ blobs.push({ parts: parts.map((p) => [...p]), type: opts.type }); } },
    URL: { createObjectURL: () => 'blob:x', revokeObjectURL(){} },
  });
  const b64 = (bytes) => { c.B64 = Buffer.from(bytes).toString('base64'); return c.B64; };
  vm.runInContext('let pv=null; let previewGeneration=0;' + fn('async function showPreview(', 'function concat('), c);

  // glm-6: chunked reads land at their offsets in one preallocated buffer.
  const reads = [];
  const READER = { read: async (e, off) => { reads.push(off); return off === 0 ? b64([1,2,3,4,5]) : b64([6,7,8]); } };
  c.READER = READER;
  vm.runInContext('pv = { source: READER, files: [{name:"x.bin",size:8,mtime:1}], index: 0, token: ++previewGeneration, url: null }', c);
  await vm.runInContext('showPreview()', c);
  assert.deepEqual(reads, [0, 5], 'resumed exactly where the previous chunk ended');
  assert.equal(blobs.length, 1);
  assert.equal(blobs[0].parts.length, 1, 'the blob holds the file exactly once, in one piece');
  assert.ok(Buffer.from(blobs[0].parts[0]).equals(Buffer.from([1,2,3,4,5,6,7,8])), 'chunk writes landed at their offsets; no byte lost or duplicated');

  // glm-5: the document iframe carries sandbox="".
  created.length = 0;
  const READER2 = { read: async () => b64([9,10,11,12]) };
  c.READER2 = READER2;
  vm.runInContext('pv = { source: READER2, files: [{name:"doc.pdf",size:4,mtime:1}], index: 0, token: ++previewGeneration, url: null }', c);
  await vm.runInContext('showPreview()', c);
  assert.equal(created.filter((n) => n.sandbox === '').length, 1, 'the iframe element carries sandbox=""');
});
test('glm-4 fileType runs once per entry per place, not per keystroke', async () => {
  elements.clear();
  const calls = [];
  const c = context({
    document: { createElement: () => node(), body: { classList: { add(){}, remove(){} } } },
    fileType: (name, dir) => { calls.push(name); return name.endsWith('.png') ? 'Photo' : 'File'; },
    localStorage: { getItem: () => null, setItem(){} },
    svg: () => '', SEARCH_ICON: 's', SORT_DIR_ICON: 'd',
    Option: class { constructor(label, value){ this.label = label; this.value = value; } },
  });
  vm.runInContext(fn('class FileTable {', 'FileTable.all = []') + 'FileTable.all = [];', c);
  const tools = node(), head = node(), list = node();
  head.querySelectorAll = () => [];
  vm.runInContext(`var t = new FileTable({view:'browse', tools: TOOLS, head: HEAD, list: LIST, columns:[{key:'type',label:'Type'}], storageKey:'k', actions:1, renderRow:(e)=>NODE(), emptyText:()=>'', setEmpty(){}})`, Object.assign(c, { TOOLS: tools, HEAD: head, LIST: list, NODE: node }));
  const entries = [1,2,3,4].map((i) => ({ name: i % 2 ? `f${i}.png` : `g${i}.txt`, size: i, mtime: i }));
  const before = calls.length;
  await vm.runInContext('t.show(ENTRIES)', Object.assign(c, { ENTRIES: entries }));
  // show() stamps each entry once…
  assert.equal(calls.length - before, entries.length, 'one fileType call per entry at show()');
  await vm.runInContext('t.setSort("type", 1)', c); // sort by type ⇒ stamps reused, no new calls
  await vm.runInContext('t.render()', c);           // re-render: still none
  assert.equal(calls.length - before, entries.length, 'chips, sort and filter reuse the stamp');
  const dirEntry = { name: 'z.png', dir: true, size: 1, mtime: 2 };
  await vm.runInContext('t.show(ENTRIES2)', Object.assign(c, { ENTRIES2: [...entries, dirEntry] }));
  await vm.runInContext('t.render()', c);
  assert.equal(calls[0], entries[0].name);
});


test('codex-r2-1 downloads rows: the bar follows the download state, not the node', () => {
  const created = [];
  let NODE_ON = true;
  const c = context({
    document: { createElement: () => { const n = node(); created.push(n); return n; } },
    isRunning: () => NODE_ON,
  });
  // one slice of the two real functions from downloads.js (merged source header)
  vm.runInContext(fn('function decorateDownloadRow(', 'function updateDownloadRow('), c);
  for (const state of ['running', 'done', 'failed', 'canceled']) {
    for (NODE_ON of [true, false]) {
      created.length = 0;
      const li = node(); li.querySelector = () => { const m = node(); created.push(m); return m; };
      vm.runInContext('decorateDownloadRow(LI, D)', Object.assign(c, { LI: li, D: { name: 'f', size: 4, done: 2, state, exists: state === 'done', path: '/tmp/f' } }));
      const bars = created.filter((n) => n.className === 'dl-progress');
      assert.equal(bars.length, state === 'running' ? 1 : 0, `state=${state} nodeOn=${NODE_ON}`);
    }
  }
});

test('J6 overlays attachMenu: touch pointercancel->contextmenu uses longPress and one-shot click suppression', () => {
  const makeTarget = () => {
    const listeners = new Map();
    return {
      dataset: {},
      classList: { add(){}, toggle(){} },
      addEventListener(type, fn) {
        if (!listeners.has(type)) listeners.set(type, []);
        listeners.get(type).push(fn);
      },
      emit(type, ev = {}) {
        const e = {
          pointerType: 'touch',
          clientX: 12,
          clientY: 34,
          defaultPrevented: false,
          stopped: false,
          preventDefault() { this.defaultPrevented = true; },
          stopPropagation() { this.stopped = true; },
          ...ev,
        };
        for (const fn of listeners.get(type) || []) fn(e);
        return e;
      },
    };
  };
  const menus = [];
  const c = context({
    longPress,
    navigator: {},
    showMenu: (x, y, items) => menus.push({ x, y, items }),
  });
  vm.runInContext(fn('export function attachMenu(', 'export function showMenu('), c);

  // 1. Swarm-style row (items + onLongPress): pointercancel -> MouseEvent contextmenu runs onLongPress, not showMenu.
  const li = makeTarget();
  let pressed = 0;
  let clicked = 0;
  c.LI = li;
  c.ITEMS = [{ icon: 'trash', label: 'Delete', run() {} }];
  c.ON_LP = () => { pressed++; };
  const press = vm.runInContext('attachMenu(LI, ITEMS, ON_LP)', c);
  li.addEventListener('click', () => { if (!press.wasLongPress()) clicked++; });

  li.emit('pointerdown', { pointerType: 'touch', clientX: 5, clientY: 6 });
  li.emit('pointercancel', { pointerType: 'touch', clientX: 5, clientY: 6 });
  const cm = li.emit('contextmenu', { pointerType: undefined, clientX: 5, clientY: 6 });
  assert.equal(cm.defaultPrevented, true);
  assert.equal(cm.stopped, true);
  assert.equal(pressed, 1);
  assert.equal(menus.length, 0);

  // No click followed the cancelled pointer; the NEXT normal tap must NOT be swallowed.
  li.emit('pointerdown', { pointerType: 'touch' });
  li.emit('pointerup', { pointerType: 'touch' });
  li.emit('click', { pointerType: 'touch' });
  assert.equal(clicked, 1);

  // Desktop mouse right-click still opens showMenu and does not invoke onLongPress.
  li.emit('pointerdown', { pointerType: 'mouse' });
  const rcm = li.emit('contextmenu', { pointerType: 'mouse', clientX: 90, clientY: 40 });
  assert.equal(rcm.defaultPrevented, true);
  assert.equal(pressed, 1);
  assert.equal(menus.length, 1);
  assert.equal(menus[0].x, 90);

  // 2. Menu-only row (onLongPress = null): pointercancel -> contextmenu opens showMenu ONCE.
  menus.length = 0;
  const li2 = makeTarget();
  c.LI2 = li2;
  vm.runInContext('attachMenu(LI2, ITEMS, null)', c);
  li2.emit('pointerdown', { pointerType: 'touch', clientX: 20, clientY: 30 });
  li2.emit('pointercancel', { pointerType: 'touch', clientX: 20, clientY: 30 });
  li2.emit('contextmenu', { pointerType: undefined, clientX: 20, clientY: 30 });
  assert.equal(menus.length, 1);
  assert.deepEqual([menus[0].x, menus[0].y], [20, 30]);
});

test('U7 swarm New folder dialog trims typed name and skips whitespace-only input', async () => {
  elements.clear();
  const clicks = new Map();
  const calls = [];
  let dialogAnswer = '  My Trip  ';
  const makeBtn = (id) => {
    const n = node();
    n.addEventListener = (type, fn) => { if (type === 'click') clicks.set(id, fn); };
    elements.set(id, n);
    return n;
  };
  makeBtn('swarm-mkdir');
  const c = context({
    isRunning: () => true,
    askDialog: async () => dialogAnswer,
    invoke: async (cmd, args) => { calls.push([cmd, args.dir, args.name]); },
    snack() {},
    loadSwarm() {},
  });
  const mkdirSnippet = raw('$("swarm-mkdir").addEventListener("click",', '$("swarm-sync").addEventListener');
  vm.runInContext(`let swarmDir = 'Photos';\n${mkdirSnippet}`, c);

  await clicks.get('swarm-mkdir')();
  assert.deepEqual(calls, [['swarm_mkdir', 'Photos', 'My Trip']]);

  dialogAnswer = '   \t  ';
  await clicks.get('swarm-mkdir')();
  assert.equal(calls.length, 1, 'whitespace-only folder name is not sent');
});

test('J8 photos loadPhotos leaves select mode, clears stale grid on stop, and ignores late index', async () => {
  elements.clear();
  let running = true;
  let starting = false;
  let selLeft = 0;
  let unmounted = 0;
  let chipsCleared = 0;
  el('photos-chips').replaceChildren = () => { chipsCleared++; };
  const pendingIndex = deferred();
  const c = context({
    window: { oriel: { invoke: () => pendingIndex.promise } },
    invoke: () => pendingIndex.promise,
    isRunning: () => running,
    isStarting: () => starting,
    errText: String,
    sel: { leave() { selLeft++; } },
    unmountAllRows() { unmounted++; },
    renderFolderChips() {},
    groupByDay: () => [{ key: '2026-01-01', label: 'Jan 1', start: 0, count: 1 }],
    computeLayout() { vm.runInContext('rows = [{ type: "tiles" }]', c); },
    onScroll() {},
  });
  vm.runInContext(
    `let currentFolder = ""; let currentIndex = { total: 5, generation: 2 }; let currentGeneration = 2; let thumbBase = "http://t/"; let sections = [1]; let rows = [1]; let selAnchor = 3; const pageCache = new Map([[0, { items: [{}] }]]);\n` +
    fn('let loadSeq = 0;', 'export function installPhotos('),
    c,
  );

  // Start a load while running, then stop the node before photos_index resolves.
  const inFlight = vm.runInContext('loadPhotos()', c);
  running = false;
  await vm.runInContext('loadPhotos()', c);

  assert.equal(selLeft, 1, 'sel.leave() called when node stops');
  assert.equal(unmounted, 1, 'unmountAllRows() called when node stops');
  assert.equal(chipsCleared, 1, 'folder chips cleared when node stops');
  assert.equal(vm.runInContext('currentIndex', c), null);
  assert.equal(vm.runInContext('rows.length', c), 0);
  assert.equal(vm.runInContext('sections.length', c), 0);
  assert.equal(vm.runInContext('pageCache.size', c), 0);
  assert.equal(el('photos-spacer').style.height, '0px');
  assert.equal(el('photos-sticky').hidden, true);
  assert.equal(el('photos-scrubber').hidden, true);
  assert.equal(el('photos-empty').hidden, false);
  assert.equal(el('photos-empty').textContent, 'Start NomadFS to see your photos.');

  // Late photos_index response from before the stop must not repopulate the grid.
  pendingIndex.resolve({ generation: 3, total: 1, mtimes: [1700000000], folders: [], thumb_base: 'http://t/' });
  await inFlight;
  assert.equal(vm.runInContext('currentIndex', c), null);
  assert.equal(vm.runInContext('rows.length', c), 0);
});

test('H6 swarm uploadInto stops batch across node restart during NotSynced wait', async () => {
  elements.clear();
  setRunning(true);
  const snacks = [];
  const calls = [];
  let session = 'A';
  let waitHook = null;
  const fakeFile = (name, size) => ({
    name,
    size,
    lastModified: 1700000000000,
    slice: (a, b) => ({ arrayBuffer: async () => new Uint8Array(Math.max(0, Math.min(b, size) - a)).buffer }),
  });
  const c = context({
    isRunning,
    onNodeChange,
    nodeSession,
    planUpload,
    progressText,
    uploadedText,
    sendUpload: (inv, plan, opts) => sendUpload(inv, plan, { ...opts, wait: async () => { if (waitHook) waitHook(); } }),
    invoke: async (cmd, args) => {
      calls.push([session, cmd, args]);
      if (cmd === 'swarm_mkdir' && args.name === 'Trip') throw new Error('NotSynced');
      if (cmd === 'swarm_upload_begin') {
        if (args.name === 'second.jpg') throw new Error('NotSynced');
        return 1;
      }
      return null;
    },
    snack: (msg, ms) => snacks.push([msg, ms]),
    showUpload() {},
    hideUpload() {},
    loadSwarm() {},
  });
  vm.runInContext(
    'let uploading = false; let uploadCancelled = false;\n' +
    fn('async function uploadInto(', 'function installSwarmDrop('),
    c,
  );

  // 1. Node stops and restarts (A -> B) during mkdir NotSynced wait:
  // retry must not invoke anything on session B, and snack reports the restart.
  waitHook = () => {
    setRunning(false);
    session = 'B';
    setRunning(true);
  };
  c.FILES1 = [{ file: fakeFile('a.jpg', 4), rel: 'Trip/a.jpg' }];
  await vm.runInContext('uploadInto("", FILES1, ["Trip"])', c);
  assert.deepEqual(calls, [['A', 'swarm_mkdir', { dir: '', name: 'Trip' }]]);
  assert.deepEqual(snacks.at(-1), ['Stopped: NomadFS restarted', 8000]);
  assert.equal(vm.runInContext('uploading', c), false);

  // 2. Node stops during begin NotSynced retry after one file already landed.
  calls.length = 0;
  snacks.length = 0;
  waitHook = () => { setRunning(false); };
  c.FILES2 = [
    { file: fakeFile('first.jpg', 4), rel: 'first.jpg' },
    { file: fakeFile('second.jpg', 4), rel: 'second.jpg' },
  ];
  await vm.runInContext('uploadInto("", FILES2, [])', c);
  assert.deepEqual(
    calls.map(([, cmd]) => cmd),
    ['swarm_upload_begin', 'swarm_upload_chunk', 'swarm_upload_finish', 'swarm_upload_begin'],
  );
  assert.deepEqual(snacks.at(-1), ['Added 1 file · Stopped: NomadFS restarted', 8000]);

  // 3. After completion, the listener is unsubscribed: a later restart does not affect a new upload.
  setRunning(true);
  calls.length = 0;
  snacks.length = 0;
  waitHook = null;
  c.FILES3 = [{ file: fakeFile('ok.jpg', 2), rel: 'ok.jpg' }];
  await vm.runInContext('uploadInto("", FILES3, [])', c);
  assert.deepEqual(snacks.at(-1), ['Added 1 file', 4000]);
  setRunning(false);
  setRunning(true);
  await vm.runInContext('uploadInto("", FILES3, [])', c);
  assert.deepEqual(snacks.at(-1), ['Added 1 file', 4000]);
  setRunning(false);
});

test('H8 swarm add-folder shows stopped_by reason with partial counts', async () => {
  elements.clear();
  const clicks = new Map();
  const snacks = [];
  const btn = node();
  btn.addEventListener = (type, fn) => { if (type === 'click') clicks.set(type, fn); };
  elements.set('swarm-add-folder', btn);
  let reply = { files: 12, folders: 3, skipped: 0, cancelled: false, stopped_by: 'storage_full' };
  const c = context({
    isRunning: () => true,
    invoke: async () => reply,
    folderAddedText,
    snack: (msg, ms) => snacks.push([msg, ms]),
    showUpload() {},
    hideUpload() {},
    loadSwarm() {},
  });
  const addFolderSnippet = raw('$("swarm-add-folder").addEventListener("click",', 'installSwarmDrop();');
  vm.runInContext(`let swarmDir = ''; let uploading = false;\n${addFolderSnippet}`, c);

  await clicks.get('click')();
  assert.deepEqual(snacks.at(-1), ['Stopped: the store is full · Added 12 files in 3 folders', 8000]);

  reply = { files: 4, folders: 1, skipped: 0, cancelled: false, stopped_by: 'none' };
  await clicks.get('click')();
  assert.deepEqual(snacks.at(-1), ['Added 4 files in 1 folder', 5000]);
});

test('K3 a node restart the page missed (new session, still running) fires onNodeChange', () => {
  setRunning(true, 7);
  let fired = 0;
  const unsub = onNodeChange(() => { fired++; });
  setRunning(true, 7);
  assert.equal(fired, 0);
  setRunning(true, 8);
  assert.equal(fired, 1);
  assert.equal(nodeSession(), 8);
  // A call without a session keeps the one it had.
  setRunning(true);
  assert.equal(fired, 1);
  assert.equal(nodeSession(), 8);
  unsub();
  setRunning(false, 9);
});
