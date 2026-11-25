import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const elements = new Map();
function el(id) {
  if (!elements.has(id)) elements.set(id, {
    value: '', checked: false, textContent: '', disabled: false, hidden: false,
    dataset: {}, contains: () => false, querySelectorAll: () => [], listeners: {},
    classList: { add() {}, remove() {}, toggle() {} },
    addEventListener(type, fn) { this.listeners[type] = fn; },
  });
  return elements.get(id);
}
globalThis.document = { getElementById: el, activeElement: null, addEventListener() {} };
let saved = { port: 0, user: '', password_set: false, allow_other_users: false, running: false, address: '' };
let failure = null;
let infoGate = null;
const calls = [];
globalThis.window = { oriel: { invoke: async (cmd, args) => {
  calls.push({ cmd, args });
  if (cmd === 'ensure_config') return { path: '/tmp/webdav-test.conf' };
  if (cmd === 'mount_status') return { supported: true, mounted: false, default_path: '/tmp/mount' };
  if (cmd === 'webdav_info') {
    if (!infoGate) return { ...saved };
    const pending = infoGate.promise;
    infoGate = null;
    return pending;
  }
  if (failure) throw failure;
  if (cmd === 'webdav_set' && args.password && !args.user) throw new Error('InvalidWebDavUser');
  if (cmd === 'webdav_set') saved = { ...saved, ...args, running: true, password_set: !args.clear_password && (!!args.password || saved.password_set), address: `http://127.0.0.1:${args.port}/Swarm/` };
  if (cmd === 'webdav_stop') saved.running = false;
  if (cmd === 'webdav_start' || cmd === 'webdav_restart') saved.running = true;
} } };
const { setRunning } = await import('../frontend/state.js');
setRunning(true);
const { installMount, loadMount } = await import('../frontend/mount.js');
installMount({ setView() {}, nodeState() {} });
const click = id => el(id).listeners.click();
const submit = () => el('webdav-form').listeners.submit({ preventDefault() {} });

test('other-user checkbox explains why it is disabled without a saved login', async () => {
  await loadMount();
  assert.equal(el('webdav-other-users').disabled, true);
  assert.equal(el('webdav-other-users').checked, false);
  assert.match(el('webdav-other-users-hint').textContent, /Without a login.*option has no effect/);
});

test('Save snapshots port and login before an in-flight status refresh can overwrite them', async () => {
  await loadMount();
  el('webdav-port').value = '8080';
  el('webdav-user').value = 'reader';
  el('webdav-password').value = 'secret';
  // A node-state refresh started before the click, and its reply arrives
  // as Save yields to ensureConfig. The original form then sent an empty
  // user with a password, which validation rejected before writing a section.
  let resolveInfo;
  infoGate = { promise: new Promise(resolve => { resolveInfo = resolve; }) };
  const refresh = loadMount();
  await new Promise(setImmediate);
  resolveInfo({ ...saved });
  await Promise.resolve();
  const saving = submit();
  await Promise.all([refresh, saving]);
  infoGate = null;
  const args = calls.find(c => c.cmd === 'webdav_set').args;
  assert.equal(args.config_path, '/tmp/webdav-test.conf');
  assert.equal(args.user, 'reader');
  assert.equal(args.port, 8080);
  assert.equal(args.password, 'secret');
  assert.equal(el('webdav-state').textContent, 'Serving at http://127.0.0.1:8080/Swarm/');
  assert.equal(el('webdav-password').value, '');
});

test('busy-port failure stays inline across refresh and preserves the failed edit for retry', async () => {
  failure = new Error('AddressInUse');
  el('webdav-port').value = '8081';
  el('webdav-user').value = 'other';
  el('webdav-password').value = 'retry-password';
  await submit();
  const message = 'Port 8081 is already in use by another program. Choose another port.';
  assert.equal(el('webdav-error').textContent, `Error: ${message}`);
  assert.equal(el('webdav-error').hidden, false);
  assert.equal(el('webdav-state').textContent, `Error: ${message}`);
  assert.equal(el('webdav-port').value, '8081');
  assert.equal(el('webdav-user').value, 'other');
  assert.equal(el('webdav-password').value, 'retry-password');
  await loadMount();
  assert.equal(el('webdav-error').textContent, `Error: ${message}`);
  assert.equal(el('webdav-port').value, '8081');
  assert.equal(el('webdav-user').value, 'other');
  failure = null;
});

test('Stop, Start and Restart use saved settings and report the running state', async () => {
  await click('webdav-stop');
  assert.equal(el('webdav-state').textContent, 'Stopped');
  assert.equal(saved.port, 8080);
  assert.equal(el('webdav-start').disabled, false);
  await click('webdav-start');
  assert.match(el('webdav-state').textContent, /^Serving at /);
  await click('webdav-restart');
  assert.equal(calls.at(-2).cmd, 'webdav_restart');
  assert.deepEqual(calls.at(-2).args, { config_path: '/tmp/webdav-test.conf' });
  assert.equal(el('webdav-stop').disabled, false);
});

test('the rendered card has explicit controls and explains session-only Stop', () => {
  const html = readFileSync(new URL('../frontend/index.html', import.meta.url), 'utf8');
  for (const id of ['webdav-start', 'webdav-stop', 'webdav-restart', 'webdav-error']) assert.ok(html.includes(`id="${id}"`));
  assert.ok(!html.includes('id="webdav-enabled"'));
  assert.match(html, /Stop lasts until Start or the next node restart/);
});

test('other-user permission saves, reloads and disables again after clearing the login', async () => {
  await submit(); // retry the failed edit
  assert.equal(el('webdav-other-users').disabled, false);
  el('webdav-other-users').checked = true;
  await submit();
  assert.equal(calls.filter(c => c.cmd === 'webdav_set').at(-1).args.allow_other_users, true);
  assert.equal(el('webdav-other-users').checked, true);
  await loadMount();
  assert.equal(el('webdav-other-users').checked, true);
  await click('webdav-clear');
  assert.equal(el('webdav-other-users').disabled, true);
  assert.match(el('webdav-other-users-hint').textContent, /only programs running as your user/);
});
