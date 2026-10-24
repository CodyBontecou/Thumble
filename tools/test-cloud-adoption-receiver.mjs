// Actual TLS receiver + production phone state machine, with a non-HID test stub.
import { spawn } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { once } from 'node:events';
import { createHash } from 'node:crypto';
import assert from 'node:assert/strict';
import WebSocket from 'ws';
import { Connection } from '../apps/mobile/src/connection-core.js';
import { xboxProfile, parseInvitation } from '@tapping/controller';
import { ProfileStore } from '../packages/profile-tools/src/store.js';
const fixture = spawn(process.execPath, ['tools/test-onboarding-receiver.mjs', '--preview'], { stdio: ['ignore', 'pipe', 'pipe'] });
let output = ''; fixture.stdout.on('data', d => { output += d; }); fixture.stderr.on('data', d => { output += d; });
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(read, timeout = 30000) { const end = Date.now() + timeout; while (Date.now() < end) { const value = await read(); if (value) return value; await pause(20); } throw Error('Receiver integration timed out: ' + output); }
let socket, connection;
try {
  await until(() => output.includes('preview ready'));
  const invitationPath = await readFile('build/onboarding-preview-invitation', 'utf8');
  const directory = await readFile('build/onboarding-preview-directory', 'utf8');
  const invitation = await readFile(invitationPath, 'utf8');
  const parsed = parseInvitation(invitation), listeners = {};
  const native = {
    addListener: (name, fn) => { listeners[name] = fn; },
    connect(url) {
      socket = new WebSocket(url, { rejectUnauthorized: false });
      socket.on('open', () => { assert.equal(createHash('sha256').update(socket._socket.getPeerCertificate().raw).digest('hex'), parsed.pin); listeners.status({ value: 'open', id: 'fixture-pairing' }); });
      socket.on('message', value => listeners.message({ value: String(value), id: 'fixture-pairing' }));
      return 'fixture-pairing';
    },
    send: text => { if (socket?.readyState !== WebSocket.OPEN) return false; socket.send(text); return true; },
    disconnect: () => socket?.close(),
  };
  connection = new Connection(native); connection.phoneId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
  connection.subscribeProfile(() => { if (connection.layoutPending) setImmediate(() => connection.acknowledgeLayout(connection.layout.revision)); });
  await connection.connect(invitation);
  await until(() => connection.snapshot().phase === 'connected');
  const catalog = await connection.requestProfiles(); assert.equal(connection.cloudAdoptionSupported, true);
  const profile = structuredClone(xboxProfile); profile.id = 'cloud-receiver-test'; profile.name = 'Cloud receiver test';
  for (const control of profile.controls) control.layers = Object.fromEntries(['', 'SHIFT-', 'CTRL-', 'ALT-', 'CTRL-SHIFT-', 'ALT-SHIFT-', 'ALT-CTRL-', 'ALT-CTRL-SHIFT-'].map(key => [key, { label: 'Layer '.repeat(10).trim() }]));
  assert.ok(Buffer.byteLength(JSON.stringify(profile)) > 4096);
  const source = { service: 'https://pilot.example', accountId: 'a'.repeat(64), profileId: profile.id, revision: 7 };
  const adopted = await connection.adoptProfile(profile, source, catalog.activationRevision);
  assert.equal(adopted.activationRevision, 1); assert.equal(connection.canPlay, false);
  assert.equal(connection.layoutPending, false); assert.equal(connection.recovering, false);
  const disk = await new ProfileStore(directory).read();
  assert.equal(disk.active.profile.id, adopted.adoption.profileId);
  assert.equal(disk.profiles[0].cloudSource.revision, 7);
  assert.deepEqual({ ...disk.active.profile, id: profile.id }, profile);
  const retry = await connection.adoptProfile(profile, source, adopted.activationRevision);
  assert.equal(retry.activationRevision, 1);
  assert.equal((await new ProfileStore(directory).read()).profiles.length, 1);
  console.log('PASS actual TLS receiver adoption: >4KiB validated profile, isolated persisted copy, phone layout/neutral ACK, paused input, idempotent retry');
} finally {
  connection?.disconnect(); socket?.terminate(); fixture.kill('SIGTERM'); await once(fixture, 'exit').catch(() => {});
}
