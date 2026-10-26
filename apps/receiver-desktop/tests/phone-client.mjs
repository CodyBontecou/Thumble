// Drive the real portable phone connection through a TLS-backed native bridge double.
// Invitation arrives over stdin and is never printed or passed on the command line.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import WebSocket from 'ws';
import { Connection } from '../../mobile/src/connection-core.js';
import { neutralState } from '@tapping/controller';

let input = '';
for await (const chunk of process.stdin) input += chunk;
const { invitation } = JSON.parse(input);
const listeners = {};
let socket, serial = 0;
const native = {
  addListener: (name, handler) => { listeners[name] = handler; },
  connect: (url, pin) => {
    const id = String(++serial);
    // The test listens on loopback; the production invitation parser still checks RFC1918.
    const address = new URL(url); address.hostname = '127.0.0.1';
    socket = new WebSocket(address, { rejectUnauthorized: false });
    socket.on('open', () => {
      assert.equal(createHash('sha256').update(socket._socket.getPeerCertificate().raw).digest('hex'), pin);
      listeners.status({ id, value: 'open' });
    });
    socket.on('message', value => listeners.message({ id, value: String(value) }));
    socket.on('close', () => listeners.status({ id, value: 'closed' }));
    socket.on('error', () => listeners.status({ id, value: 'error' }));
    return id;
  },
  send: value => { if (socket?.readyState !== WebSocket.OPEN) return false; socket.send(value); return true; },
  disconnect: () => socket?.close(),
};
const connection = new Connection(native);
connection.phoneId = '11111111-1111-1111-1111-111111111111';
const wait = async predicate => {
  const deadline = performance.now() + 5000;
  while (!predicate()) {
    assert(performance.now() < deadline, `Phone timed out: ${connection.snapshot().detail}`);
    await new Promise(resolve => setTimeout(resolve, 10));
  }
};
connection.subscribeProfile(() => {
  if (connection.layoutPending) queueMicrotask(() => connection.acknowledgeLayout(connection.layout.revision));
});
try {
  await connection.connect(invitation);
  await wait(() => connection.snapshot().phase === 'connected' && connection.access);
  const catalog = await connection.requestProfiles();
  const starter = catalog.profiles.find(profile => profile.id === 'consoleport-standard');
  const selected = await connection.selectProfile(starter, catalog.activationRevision);
  assert.equal(connection.layout.profile.id, starter.id);
  assert.equal(connection.layout.revision, selected.activationRevision);
  assert(!connection.recovering && !connection.layoutPending);
  connection.resumePlay();
  await wait(() => connection.canPlay && !connection.recovering);
  const before = connection.sequence;
  connection.submit({ ...neutralState(), buttons: 1 });
  await wait(() => connection.sequence > before && connection.pending.size === 0);
  const profile = { ...structuredClone(connection.layout.profile), id: 'cloud-phone-test', name: 'Cloud phone test' };
  const source = { service: 'https://thumble.example/v1', accountId: 'a'.repeat(64), profileId: profile.id, revision: 1 };
  const adopted = await connection.adoptProfile(profile, source, selected.activationRevision);
  assert.equal(connection.layout.profile.id, adopted.adoption.profileId);
  assert(!connection.canPlay && !connection.recovering && !connection.layoutPending);
  assert.deepEqual(connection.layout.profile.controls, profile.controls);
  const retried = await connection.adoptProfile(profile, source, adopted.activationRevision);
  assert.equal(retried.activationRevision, adopted.activationRevision);
  assert.equal(retried.adoption.profileId, adopted.adoption.profileId);
  console.log('PASS real phone connection: TLS, select, render, neutral ACK, resume, input, cloud adoption');
} finally {
  connection.disconnect();
}
