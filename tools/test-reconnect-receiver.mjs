// Exercise the real mobile connection core and receiver protocol without creating a HID device.
import { mkdtemp, mkdir, readFile, rm, readdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import assert from 'node:assert/strict';
import WebSocket from 'ws';
import { Connection } from '../apps/mobile/src/connection-core.js';

const folder = await mkdtemp(join(tmpdir(), 'thumble-reconnect-'));
let child;
const connections = [];
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(get, label) {
  const deadline = Date.now() + 7000;
  while (Date.now() < deadline) { const value = await get(); if (value) return value; await sleep(10); }
  throw Error(`Timed out: ${label}`);
}
function run(command, args) {
  const result = spawnSync(command, args, { encoding: 'utf8' });
  if (result.status !== 0) throw Error(result.stderr || result.stdout);
}
try {
  await mkdir('build/reconnect-tests', { recursive: true });
  run('xcrun', ['swiftc', '-module-cache-path', resolve('build/receiver/swift-cache'), 'apps/receiver/Sources/ReceiverSecrets.swift', 'apps/receiver/Sources/Identity.swift', 'apps/receiver/Sources/RememberedPhone.swift', 'tools/reconnect-tests/main.swift', '-o', resolve('build/reconnect-tests/credential-check')]);
  run(resolve('build/reconnect-tests/credential-check'), []);
  const binary = resolve('build/reconnect-tests/receiver-stub');
  run('xcrun', ['clang', '-c', 'tools/access-receiver-tests/GamepadStub.c', '-o', join(folder, 'stub.o')]);
  const sources = (await readdir('apps/receiver/Sources')).filter(name => name.endsWith('.swift') && name !== 'main.swift');
  run('xcrun', ['swiftc', '-swift-version', '5', '-module-cache-path', resolve('build/receiver/swift-cache'), '-import-objc-header', 'apps/receiver/Sources/Gamepad.h', ...sources.map(name => `apps/receiver/Sources/${name}`), 'tools/access-receiver-tests/main.swift', join(folder, 'stub.o'), '-o', binary]);
  const invitationPath = join(folder, 'invitation');
  const startReceiver = () => spawn(binary, [], { env: { ...process.env, TAPPING_PROFILE_DIR: join(folder, 'profiles'), TAPPING_TEST_INVITATION: invitationPath, TAPPING_TEST_REPORTS: join(folder, 'reports') }, stdio: 'ignore' });
  child = startReceiver();
  const invitation = await until(async () => { try { return await readFile(invitationPath, 'utf8'); } catch { return null; } }, 'initial invitation');
  const storage = { value: null, async load() { return this.value; }, async save(value) { this.value = value; } };
  function phone(phoneId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb') {
    const listeners = {}; let socket, generation = 0;
    const native = {
      addListener: (event, fn) => { listeners[event] = fn; },
      connect(url, pin) {
        const id = String(++generation);
        const ws = new WebSocket(url, { rejectUnauthorized: false }); socket = ws;
        ws.on('open', () => {
          assert.equal(createHash('sha256').update(ws._socket.getPeerCertificate().raw).digest('hex'), pin);
          listeners.status({ id, value: 'open' });
        });
        ws.on('message', data => listeners.message({ id, value: String(data) }));
        ws.on('close', () => listeners.status({ id, value: 'closed' }));
        ws.on('error', () => listeners.status({ id, value: 'failed' }));
        return id;
      },
      send(text) { if (socket?.readyState !== WebSocket.OPEN) return false; socket.send(text); return true; },
      disconnect() { socket?.terminate(); socket = null; },
    };
    const connection = new Connection(native); connection.phoneId = phoneId; connection.pairingStorage = storage;
    connections.push(connection); return connection;
  }
  const initial = phone();
  await initial.connect(invitation);
  await until(() => initial.snapshot().phase === 'connected', 'initial QR handshake');
  await initial.storageWrite;
  assert.equal(storage.value.token, undefined);
  assert.match(storage.value.reconnectToken, /^[a-f0-9]{64}$/);
  initial.suspend(); await initial.reconnect();
  await until(() => initial.snapshot().phase === 'connected', 'checkout return reconnect');
  console.log('PASS real receiver: background/foreground reconnects with a distinct credential');
  initial.suspend();
  const restarted = phone(); await restarted.reconnect();
  await until(() => restarted.snapshot().phase === 'connected', 'process restart reconnect');
  console.log('PASS real receiver: fresh mobile process reconnects from saved credential');
  restarted.suspend();
  child.kill('SIGTERM');
  await new Promise(resolve => child.once('exit', resolve));
  await rm(invitationPath, { force: true });
  child = startReceiver();
  const nextInvitation = await until(async () => { try { return await readFile(invitationPath, 'utf8'); } catch { return null; } }, 'receiver relaunch');
  const decode = link => JSON.parse(Buffer.from(new URL(link).searchParams.get('data'), 'base64url'));
  assert.equal(decode(nextInvitation).pin, storage.value.pin, 'receiver restart must retain the pinned TLS identity');
  assert.equal(decode(nextInvitation).url, storage.value.url, 'receiver restart must retain its listening endpoint');
  await restarted.reconnect();
  await until(() => restarted.snapshot().phase === 'connected', 'Mac receiver process restart reconnect');
  console.log('PASS real receiver: Mac receiver restart retains TLS pin, endpoint and phone authentication');
  const intruder = phone('cccccccc-cccc-cccc-cccc-cccccccccccc');
  await intruder.reconnect(); await sleep(200);
  assert.notEqual(intruder.snapshot().phase, 'connected');
  assert.equal(restarted.snapshot().phase, 'connected');
  console.log('PASS real receiver: credential cannot authenticate a different phone or replace its session');
  restarted.disconnect(); await restarted.storageWrite;
  assert.equal(storage.value, null);
  console.log('PASS mobile: explicit disconnect forgets remembered computer');
} finally {
  for (const connection of connections) connection.disconnect();
  child?.kill('SIGTERM');
  await rm(folder, { recursive: true, force: true });
}
