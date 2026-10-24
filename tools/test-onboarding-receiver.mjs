// Isolated real receiver transport; the linked gamepad stub never creates HID.
// --preview leaves it available for a simulator, exporting private paths in build/.
import { mkdtemp, mkdir, writeFile, readFile, rm, readdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawn, execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { once } from 'node:events';
import assert from 'node:assert/strict';
import WebSocket from 'ws';
import { parseInvitation } from '../packages/controller/src/pairing.js';
import { ProfileStore } from '../packages/profile-tools/src/store.js';
import { callProfileTool } from '../packages/profile-tools/src/tools.js';
const folder = await mkdtemp(join(tmpdir(), 'tapping-onboarding-'));
const preview = process.argv.includes('--preview');
let child, socket;
const invitationExport = resolve('build/onboarding-preview-invitation');
const directoryExport = resolve('build/onboarding-preview-directory');
try {
  const contents = join(folder, 'OnboardingTest.app/Contents');
  await mkdir(join(contents, 'MacOS'), { recursive: true });
  const binary = join(contents, 'MacOS/receiver');
  await writeFile(join(contents, 'Info.plist'), '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>receiver</string><key>CFBundleIdentifier</key><string>test.tapping.onboarding</string></dict></plist>');
  execFileSync('xcrun', ['clang', '-c', 'tools/access-receiver-tests/GamepadStub.c', '-o', join(folder, 'stub.o')]);
  const sources = (await readdir('apps/receiver/Sources')).filter(name => name.endsWith('.swift') && name !== 'main.swift').map(name => `apps/receiver/Sources/${name}`);
  execFileSync('xcrun', ['swiftc', '-swift-version', '5', '-module-cache-path', resolve('build/onboarding-swift-cache'), '-import-objc-header', 'apps/receiver/Sources/Gamepad.h', ...sources, 'tools/access-receiver-tests/main.swift', join(folder, 'stub.o'), '-o', binary]);
  const directory = join(folder, 'profiles');
  await mkdir(directory);
  const invitationPath = join(folder, 'invitation');
  child = spawn(binary, [], { env: { ...process.env, TAPPING_PROFILE_DIR: directory, TAPPING_TEST_INVITATION: invitationPath, TAPPING_TEST_REPORTS: join(folder, 'reports') }, stdio: ['ignore', 'ignore', 'pipe'] });
  let errors = ''; child.stderr.on('data', value => errors += value);
  async function until(get) {
    const deadline = Date.now() + 7000;
    while (Date.now() < deadline) { const value = await get(); if (value) return value; await new Promise(resolve => setTimeout(resolve, 20)); }
    throw Error(`Timed out waiting for receiver: ${errors}`);
  }
  await until(async () => { try { return await readFile(invitationPath, 'utf8'); } catch { return null; } });
  if (preview) {
    // The invitation rotates after disconnect; export its path, never its secret.
    await writeFile(invitationExport, invitationPath, { mode: 0o600 });
    await writeFile(directoryExport, directory, { mode: 0o600 });
    console.log('Isolated onboarding preview ready. Input goes only to the test stub.');
    await new Promise(resolve => { process.once('SIGTERM', resolve); process.once('SIGINT', resolve); });
  } else {
    const invite = parseInvitation(await readFile(invitationPath, 'utf8'));
    socket = new WebSocket(invite.url, { rejectUnauthorized: false });
    const messages = []; socket.on('message', data => messages.push(JSON.parse(String(data))));
    await once(socket, 'open');
    assert.equal(createHash('sha256').update(socket._socket.getPeerCertificate().raw).digest('hex'), invite.pin);
    const send = value => socket.send(JSON.stringify(value));
    send({ type: 'hello', v: 3, phoneId: 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', demoUsed: 0, token: invite.token });
    await until(() => messages.find(message => message.type === 'ready'));
    async function catalog(id) {
      send({ type: 'profiles-list', id });
      const response = await until(() => messages.find(message => message.id === id));
      assert(!response.error, response.error);
      return response.catalog;
    }
    const fresh = await catalog('fresh-install');
    assert.deepEqual(fresh.profiles.map(profile => profile.id), ['xbox-standard', 'consoleport-standard']);
    assert.equal(fresh.agentCheckSupported, true);
    const store = new ProfileStore(directory);
    await callProfileTool(store, 'agent_connection_check', { code: '123456abcdef' });
    const checked = await catalog('after-agent-tool');
    assert.equal(checked.agentConnection.code, '123456abcdef');
    assert(checked.agentConnection.ageSeconds >= 0 && checked.agentConnection.ageSeconds < 10);
    await store.transaction(data => { data.agentConnection.checkedAt = Date.now() - 601000; });
    assert.equal((await catalog('expired-check')).agentConnection, undefined);
    assert.equal((await store.list()).active, null);
    assert.equal(socket.readyState, WebSocket.OPEN);
    console.log('PASS receiver transport: built-in first-install catalog, matching agent tool round trip, expired marker omitted, no profile activation');
  }
} finally {
  socket?.terminate();
  if (child) { child.kill('SIGTERM'); await once(child, 'exit').catch(() => {}); }
  if (preview) { await rm(invitationExport, { force: true }); await rm(directoryExport, { force: true }); }
  await rm(folder, { recursive: true, force: true });
}
