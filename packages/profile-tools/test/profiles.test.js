process.env.AI_CONTROLLER_GENERATOR_ENABLED = 'true';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { ProfileStore } from '../src/store.js';
import { callProfileTool, profileTools } from '../src/tools.js';
import { xboxProfile } from '../../controller/src/index.js';
const warrior = () => ({ ...structuredClone(xboxProfile), id: 'warrior', name: 'Warrior' });
async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'tapping-profiles-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  return new ProfileStore(directory);
}
test('both starters are available without an agent and upgrades preserve saved profiles and activation', async t => {
  const store = await fixture(t);
  assert.deepEqual((await store.list()).profiles.map(p => p.id), ['xbox-standard', 'consoleport-standard']);
  await store.save(warrior(), 0);
  await store.activate('warrior', 1, 0);
  const old = await store.read();
  old.profiles = old.profiles.filter(entry => entry.profile.id !== 'consoleport-standard');
  old.profiles.find(entry => entry.profile.id === 'xbox-standard').profile.name = 'My Xbox';
  await writeFile(join(store.directory, 'store.json'), JSON.stringify(old));
  const upgraded = await store.read();
  assert.equal(upgraded.active.profile.id, 'warrior');
  assert.equal(upgraded.profiles.find(entry => entry.profile.id === 'xbox-standard').profile.name, 'My Xbox');
  await store.activate('consoleport-standard', 1, 1);
  assert.equal((await new ProfileStore(store.directory).read()).active.profile.theme, 'consoleport');
});
test('a full older catalog stays readable without discarding saved profiles for starters', async t => {
  const store = await fixture(t);
  const profiles = Array.from({ length: 256 }, (_, i) => ({ revision: 1, profile: { ...warrior(), id: `saved-${i}` } }));
  await writeFile(join(store.directory, 'store.json'), JSON.stringify({ version: 1, profiles, active: null }));
  assert.equal((await store.list()).profiles.length, 256);
  assert.equal((await store.get('saved-255')).profile.id, 'saved-255');
});
test('saved revisions persist, invalid edits are atomic, and saving never changes an active layout', async t => {
  const store = await fixture(t);
  const entry = await store.save(warrior(), 0);
  const active = await store.activate('warrior', entry.revision, 0);
  const changed = warrior(); changed.name = 'Warrior v2';
  await store.save(changed, 1);
  assert.equal((await new ProfileStore(store.directory).get('warrior')).revision, 2);
  assert.equal((await store.list()).active.profile.name, 'Warrior');
  changed.controls[0].frame.width = 2;
  await assert.rejects(store.save(changed, 2), /frame/);
  assert.equal((await store.get('warrior')).revision, 2);
  assert.equal((await store.list()).active.revision, active.revision);
  await assert.rejects(store.activate('warrior', 1, 1), /revision conflict/);
  await assert.rejects(store.activate('warrior', 2, 0), /Activation conflict/);
});
test('two independent agents cannot overwrite each other or corrupt the store', async t => {
  const store = await fixture(t);
  await store.save(warrior(), 0);
  const other = new ProfileStore(store.directory);
  const outcomes = await Promise.allSettled([store.save(warrior(), 1), other.save(warrior(), 1)]);
  assert.equal(outcomes.filter(result => result.status === 'fulfilled').length, 1);
  assert.equal(outcomes.filter(result => result.status === 'rejected').length, 1);
  assert.equal((await store.get('warrior')).revision, 2);
});
test('delivery status requires a fresh phone acknowledgement for the exact activation', async t => {
  const store = await fixture(t);
  await store.save(warrior(), 0); await store.activate('warrior', 1, 0);
  const path = join(store.directory, 'receiver-status.json');
  for (const status of [
    { connected: false, ready: true, revision: 1, updatedAt: Date.now() },
    { connected: true, ready: false, revision: 1, updatedAt: Date.now() },
    { connected: true, ready: true, revision: 2, updatedAt: Date.now() },
    { connected: true, ready: true, revision: 1, updatedAt: Date.now() - 6000 },
  ]) {
    await writeFile(path, JSON.stringify(status));
    assert.equal((await store.status()).delivery, 'queued');
  }
  await writeFile(path, JSON.stringify({ connected: true, ready: true, revision: 1, updatedAt: Date.now() }));
  assert.equal((await store.status()).delivery, 'acknowledged');
});
test('tool surface has no input execution tools, rejects extra arguments, and validates semantics', async t => {
  const store = await fixture(t);
  assert.deepEqual(profileTools.map(tool => tool.name), ['show_pairing_code', 'agent_connection_check', 'profile_schema', 'list_profiles', 'get_profile', 'validate_profile', 'save_profile', 'activate_profile', 'controller_status', 'read_addon_export', 'list_characters', 'mirror_consoleport', 'import_character', 'get_character', 'propose_bindings', 'get_binding_plan', 'import_binding_result', 'sync_binding_labels']);
  await assert.rejects(callProfileTool(store, 'save_profile', { profile: warrior(), expectedRevision: 0, execute: true }), /Invalid tool arguments/);
  await assert.rejects(callProfileTool(store, 'press_button', {}), /Unknown tool/);
  const invalid = warrior(); invalid.mappings[0].outputs = ['a'];
  assert.equal((await callProfileTool(store, 'validate_profile', { profile: invalid })).valid, false);
});
test('MCP stdio saves and activates profiles without a purchase and reports revision conflicts', async t => {
  const store = await fixture(t);
  const child = spawn(process.execPath, [fileURLToPath(new URL('../src/server.js', import.meta.url))], { env: { ...process.env, TAPPING_PROFILE_DIR: store.directory }, stdio: ['pipe', 'pipe', 'pipe'] });
  t.after(() => child.kill());
  let output = '', errors = '';
  child.stdout.on('data', chunk => output += chunk);
  child.stderr.on('data', chunk => errors += chunk);
  const requests = [
    { method: 'initialize', params: { protocolVersion: '2025-11-25', capabilities: {}, clientInfo: { name: 'test', version: '1' } } },
    { method: 'notifications/initialized' },
    { method: 'tools/list' },
    { method: 'tools/call', params: { name: 'save_profile', arguments: { profile: warrior(), expectedRevision: 0 } } },
    { method: 'tools/call', params: { name: 'activate_profile', arguments: { id: 'warrior', profileRevision: 1, expectedActivationRevision: 0 } } },
    { method: 'tools/call', params: { name: 'save_profile', arguments: { profile: warrior(), expectedRevision: 0 } } },
  ];
  child.stdin.end(requests.map((request, id) => JSON.stringify({ jsonrpc: '2.0', ...(request.method.startsWith('notifications/') ? {} : { id }), ...request })).join('\n') + '\n');
  const code = await new Promise(resolve => child.on('close', resolve));
  assert.equal(code, 0, errors);
  const responses = output.trim().split('\n').map(line => JSON.parse(line));
  assert.equal(responses.length, 5);
  assert.equal(responses[0].result.protocolVersion, '2025-11-25');
  assert.equal(responses[1].result.tools.length, profileTools.length);
  assert.equal(JSON.parse(responses[2].result.content[0].text).revision, 1);
  assert.equal(JSON.parse(responses[3].result.content[0].text).delivery, 'queued');
  assert.equal(responses[4].result.isError, true);
});

test('agent connection check is validated, persists through the shared store and changes no layout', async t => {
  const store = await fixture(t);
  const before = await store.list();
  await assert.rejects(callProfileTool(store, 'agent_connection_check', { code: '../bad' }), /check code/);
  const result = await callProfileTool(store, 'agent_connection_check', { code: '123456abcdef' });
  assert.equal(result.status, 'recorded');
  const after = await store.list();
  assert.deepEqual(after, before);
  const check = (await new ProfileStore(store.directory).read()).agentConnection;
  assert.equal(check.code, '123456abcdef');
  assert.ok(Date.now() - check.checkedAt < 1000);
  await store.save(warrior(), 0);
  assert.deepEqual((await store.read()).agentConnection, check);
});
