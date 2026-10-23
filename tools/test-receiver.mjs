// Opt-in integration test against the receiver's private QA invitation export.
// Applied input is always neutral; non-neutral recovery attempts must be discarded.
import { readFile } from 'node:fs/promises';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { createHash } from 'node:crypto';
import WebSocket from 'ws';
import { parseInvitation } from '../packages/controller/src/pairing.js';
const path = process.argv[2];
assert(path, 'Pass the private invitation file path');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const neutral = {buttons:0,lx:0,ly:0,rx:0,ry:0,lt:0,rt:0};
async function connect(wrongToken = false) {
  const invitation = parseInvitation(await readFile(path,'utf8'));
  // Test client checks the exact QR leaf before transmitting any credential.
  const socket = new WebSocket(invitation.url, {rejectUnauthorized:false,handshakeTimeout:3000,maxPayload:4096});
  const inbox = [];
  socket.on('message', data => inbox.push(JSON.parse(data)));
  const closed = once(socket,'close');
  await once(socket,'open');
  assert.equal(createHash('sha256').update(socket._socket.getPeerCertificate().raw).digest('hex'),invitation.pin);
  socket.send(JSON.stringify({type:'hello',v:3,phoneId:'11111111-1111-1111-1111-111111111111',token:wrongToken?'0'.repeat(64):invitation.token}));
  return {socket,inbox,closed};
}
async function message(client, type) {
  const deadline = performance.now() + 1800;
  while (performance.now() < deadline) {
    const index = client.inbox.findIndex(value => value.type === type);
    if (index >= 0) return client.inbox.splice(index,1)[0];
    await sleep(5);
  }
  throw Error(`Receiver ${type} reply timed out`);
}
async function close(client) {
  await Promise.race([client.closed,sleep(3000).then(()=>{client.socket.terminate();throw Error('Receiver close timed out');})]);
}
const unauthorized = await connect(true); await close(unauthorized); console.log('PASS invalid pairing token rejected');
for (const mode of ['ack','replay','pause-recovery','watchdog','invalid-state']) {
  await sleep(100);
  const client = await connect();
  const ready = await message(client,'ready');
  const frame = {type:'input',seq:1,lease:ready.lease,state:neutral};
  if (mode === 'watchdog') {
    await message(client,'paused');
    await close(client);
    console.log('PASS receiver pauses then closes an idle session');
    continue;
  }
  if (mode === 'pause-recovery') {
    // Unknown leases cannot apply or refresh the watchdog.
    client.socket.send(JSON.stringify({...frame,lease:'invalid-lease'}));
    const paused = await message(client,'paused');
    assert.equal(paused.seq,-1);
    // The pre-pause lease is expired; buffered input cannot revive controls.
    client.socket.send(JSON.stringify(frame));
    // Even a fresh recovery lease cannot re-arm held buttons before neutral.
    client.socket.send(JSON.stringify({...frame,seq:2,lease:paused.lease,state:{...neutral,buttons:1}}));
    await sleep(15);
    assert.equal(client.inbox.some(value=>value.type==='ack'),false);
    client.socket.send(JSON.stringify({...frame,seq:3,lease:paused.lease}));
    const ack = await message(client,'ack'); assert.equal(ack.seq,3);
    client.socket.send(JSON.stringify({type:'bye'})); await close(client);
    console.log('PASS expired/unknown leases discarded; paused input requires fresh lease and neutral recovery');
    continue;
  }
  if (mode === 'invalid-state') frame.state = {...neutral,lx:2};
  client.socket.send(JSON.stringify(frame));
  if (mode === 'invalid-state') { await close(client);console.log('PASS invalid state rejected');continue; }
  const ack = await message(client,'ack'); assert.equal(ack.seq,1);
  if (mode === 'replay') { client.socket.send(JSON.stringify(frame));await close(client);console.log('PASS duplicate sequence rejected'); }
  else { client.socket.send(JSON.stringify({type:'bye'}));await close(client);console.log('PASS authenticated TLS hello / input / ack / disconnect'); }
}
