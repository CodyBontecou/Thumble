// Drive the real portable phone connection through a TLS-backed native bridge double.
// Invitation arrives over stdin and is never printed or passed on the command line.
import assert from 'node:assert/strict';
import { createHash, createCipheriv, createDecipheriv } from 'node:crypto';
import dgram from 'node:dgram';
import WebSocket from 'ws';
import { Connection } from '../../mobile/src/connection-core.js';
import { Controller, neutralState } from '@tapping/controller';
import { createGrant } from '../../entitlements/src/grants.js';

import { desktopProfile } from '../../../packages/desktop-workspace/src/model.js';

let input = '';
for await (const chunk of process.stdin) input += chunk;
// grantKey is the test's throwaway entitlement key; the receiver under test trusts only it.
const { invitation, grantKey, expectUdp = false, expectChat = false } = JSON.parse(input);
const listeners = {};
let socket, serial = 0;
let udp, udpKey, udpPort, sending = 0n, received = 0n;
const seal = text => {
  const nonce = Buffer.alloc(12); nonce.writeUInt32BE(1); nonce.writeBigUInt64BE(++sending, 4);
  const cipher = createCipheriv('aes-256-gcm', udpKey, nonce);
  cipher.setAAD(Buffer.from('tapping-udp-v1'));
  return Buffer.concat([nonce, cipher.update(text), cipher.final(), cipher.getAuthTag()]);
};
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
  configureDatagram: (port, key) => {
    sending = received = 0n;
    udpKey = Buffer.from(key, 'base64'); udpPort = port;
    udp = dgram.createSocket('udp4');
    const id = String(serial);
    udp.on('message', packet => {
      try {
        const nonce = packet.subarray(0, 12), count = nonce.readBigUInt64BE(4);
        assert.equal(nonce.readUInt32BE(), 2); assert(count > received);
        const decipher = createDecipheriv('aes-256-gcm', udpKey, nonce);
        decipher.setAAD(Buffer.from('tapping-udp-v1')); decipher.setAuthTag(packet.subarray(-16));
        const value = Buffer.concat([decipher.update(packet.subarray(12, -16)), decipher.final()]).toString();
        received = count;
        listeners.message({ id, value, transport: 'udp' });
      } catch { /* Corrupt and replayed datagrams cannot refresh the phone watchdog. */ }
    });
    udp.on('error', () => listeners.status({ id, value: 'udp error' }));
    udp.bind(0, '127.0.0.1', () => udp.send(seal('{"type":"probe"}'), port, '127.0.0.1'));
  },
  sendDatagram: text => {
    if (!udp) return false;
    udp.send(seal(text), udpPort, '127.0.0.1'); return true;
  },
  disconnect: () => { socket?.close(); if (udp) { udp.close(); udp = null; } },
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
  assert.equal(connection.access.pro, false); assert.equal(connection.access.remaining, 0);
  // Restore a plan as the phone does after a store purchase or restore.
  connection.sendGrant(createGrant({ receiverId: connection.access.receiverId, nonce: connection.access.nonce,
    phoneId: connection.phoneId, pro: true }, grantKey));
  await wait(() => connection.access?.pro);
  if (expectUdp) await wait(() => connection.inputTransport === 'udp');
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
  if (expectChat) await connection.sendChat('literal hello 😀', 'say');
  const profile = { ...structuredClone(connection.layout.profile), id: 'cloud-phone-test', name: 'Cloud phone test' };
  const source = { service: 'https://thumble.example/v1', accountId: 'a'.repeat(64), profileId: profile.id, revision: 1 };
  const adopted = await connection.adoptProfile(profile, source, selected.activationRevision);
  assert.equal(connection.layout.profile.id, adopted.adoption.profileId);
  assert(!connection.canPlay && !connection.recovering && !connection.layoutPending);
  assert.deepEqual(connection.layout.profile.controls, profile.controls);
  const retried = await connection.adoptProfile(profile, source, adopted.activationRevision);
  assert.equal(retried.activationRevision, adopted.activationRevision);
  assert.equal(retried.adoption.profileId, adopted.adoption.profileId);
  assert.equal(connection.phoneProfileSaveSupported, true);
  assert.equal(connection.desktopInputSupported, true);
  const phoneDraft = { ...structuredClone(desktopProfile), id: 'phone-' + 'a'.repeat(32), name: 'Phone-edited controller' };
  const savedPhone = await connection.savePhoneProfile(phoneDraft, retried.activationRevision, 0);
  assert.equal(connection.layout.profile.id, phoneDraft.id);
  assert.equal(connection.layout.revision, savedPhone.activationRevision);
  assert(!connection.canPlay && !connection.recovering && !connection.layoutPending);
  assert.match(connection.remembered?.reconnectToken ?? '', /^[a-f0-9]{64}$/);
  const remembered = { ...connection.remembered };
  connection.suspend(); // Checkout/background must retain trust and release input.
  await connection.reconnect();
  await wait(() => connection.snapshot().phase === 'connected' && connection.access && !connection.layoutPending && !connection.recovering);
  assert.equal(connection.inputTransport, 'wss');
  assert.deepEqual(connection.remembered, remembered);
  assert.equal(connection.layout.profile.id, phoneDraft.id);
  assert(!connection.canPlay);
  connection.resumePlay();
  await wait(() => connection.canPlay && !connection.recovering);
  const desktop = new Controller(phoneDraft);
  connection.submit(desktop.update('space',true));
  await wait(() => connection.pending.size === 0);
  connection.submit(desktop.update('left-click',true));
  connection.submit(desktop.update('trackpad',[12,8,0,1]));
  await wait(() => connection.pending.size === 0);
  connection.submit(desktop.releaseAll());
  await wait(() => connection.pending.size === 0);
  console.log(`PASS real phone connection: TLS, plan grant, select, render, neutral ACK, resume, input, cloud adoption, phone editing, reconnect, transport=${connection.inputTransport}, chat=${expectChat}`);
} finally {
  connection.disconnect();
}
