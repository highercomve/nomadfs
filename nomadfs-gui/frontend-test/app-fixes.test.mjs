import {readFileSync} from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';
import assert from 'node:assert/strict';
const source = readFileSync(new URL('../frontend/app.js', import.meta.url),'utf8');
const fn = (start,end) => source.slice(source.indexOf(start),source.indexOf(end,source.indexOf(start)));
const deferred = () => {let resolve,reject; const promise=new Promise((a,b)=>{resolve=a;reject=b});return {promise,resolve,reject}};
const elements = new Map();
const node = () => { const n = { style:{setProperty(){}}, dataset:{}, classList:{toggle(){},add(){},remove(){}}, hidden:false, closest:()=>({style:{setProperty(){}}}), append(){}, appendChild(){}, replaceChildren(){}, addEventListener(){}, setAttribute(){}, querySelector:()=>node(), querySelectorAll:()=>[], focus(){}, select(){}, title:'' }; return n; };
const el = id => {if(!elements.has(id)) elements.set(id,node());return elements.get(id)};
const context = extra => vm.createContext({console, $, ...extra});
function $(id){return el(id)}
// Source functions are evaluated unchanged; only DOM/IPC dependencies are fakes.
{
 const a=deferred(),b=deferred(),paint=[];
 const c=context({document:{body:{classList:{add(){},remove(){}}}},syncBack(){},stopNative(){},nativeVideo:null,
 previewMessage(){},readFailure:String,inPagePlayer:(kind,url)=>paint.push(url),a,b});
 vm.runInContext('let pv=null; let previewGeneration=0;'+fn('function openPreview(', '/** Stops a streaming player')+fn('function stopMedia(', '// The native player:')+fn('async function streamPreview(', '// The native player, embedded')+`function showPreview(){const token=++pv.token;streamPreview(pv.files[0],'audio',token)};openPreview({mediaUrl:()=>a.promise},[{name:'A'}],0);closePreview();openPreview({mediaUrl:()=>b.promise},[{name:'B'}],0);`,c);
 b.resolve('B-url');await new Promise(setImmediate);a.resolve('A-url');await new Promise(setImmediate);
 assert.deepEqual(paint,['B-url']);
}
{
 const a=deferred();let shown;
 const c=context({a,busy(){},snack(){},invoke:()=>a.promise,showLocation(){shown=vm.runInContext('path',c)}});
 vm.runInContext(`let browseNav=0;let path=[{name:'A',device:{peer:'A'}}];`+fn('async function refreshLocation(', '// ---- Swarm folder:')+`const pending=refreshLocation();path=[{name:'B',device:{peer:'B'}}];browseNav++;`,c);
 a.resolve([{peer:'A',shares:[]}]);await vm.runInContext('pending',c);
 assert.equal(shown,undefined);
}
{
 elements.clear();const a=deferred(), b=deferred();
 const c=context({invoke:(cmd)=>cmd==='file_details'?a.promise:b.promise,errText:String});
 vm.runInContext('let detailsGeneration=0;'+fn('async function openDetails(', 'function drawChunkMap(')+fn('async function openDeviceInfo(', '$('+'"dt-close"'+')')+`const pending=openDetails('File A',{});openDeviceInfo('Device B','B');`,c);
 a.reject(new Error('old file request failed'));await vm.runInContext('pending',c);
 assert.equal(el('dt-name').textContent,'Device B');assert.equal(el('dt-meta').textContent,'Asking the device…');
}
{
 elements.clear();const dirs=[];
 const c=context({swarmCrumbs(){},running:true,listLoading(){},listLoaded(){},snack(){},swarmStatusText(){return 'ok'},swarmTable:{dir:null,show(){},render(){}},invoke:async(cmd,args)=>{dirs.push(args.dir);return {items:[]}}});
 vm.runInContext(`let swarmDir='New folder',swarmNav=0;`+fn('async function loadSwarm(', 'const swarmTable =')+`const pending=loadSwarm();`,c);
 await vm.runInContext('pending',c);assert.deepEqual(dirs,['New folder']);assert.equal(vm.runInContext('swarmDir',c),'New folder');
}

test('glm-3 askDialog queues shared handlers', async () => {
  elements.clear();
  for (const id of ['ask-ok','ask-input']) Object.assign(el(id), {focus(){},setSelectionRange(){},classList:{toggle(){}}});
  const c=context({});
  vm.runInContext('let askQueue=Promise.resolve();'+fn('function askDialog(', 'async function swarmRenamePrompt(')+"const first=askDialog({title:'First'});const second=askDialog({title:'Second'});",c);
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
  vm.runInContext(fn('async function loadDownloads(', 'window.oriel.listen'),c);
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
  const c = context({
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

