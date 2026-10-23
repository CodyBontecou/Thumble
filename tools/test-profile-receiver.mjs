// Opt-in native integration test. Sends only neutral gameplay state.
// node tools/test-profile-receiver.mjs PRIVATE_INVITATION_FILE PROFILE_DIRECTORY
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { once } from 'node:events';
import assert from 'node:assert/strict';
import WebSocket from 'ws';
import { parseInvitation, neutralState } from '../packages/controller/src/index.js';
import { ProfileStore } from '../packages/profile-tools/src/store.js';
const [invitationPath, directory] = process.argv.slice(2);
assert(invitationPath && directory, 'Pass a private invitation file and isolated profile directory');
const store = new ProfileStore(directory);
const phoneId = '11111111-1111-1111-1111-111111111111';
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const profile = JSON.parse(await readFile(new URL('../examples/profiles/warrior.json', import.meta.url)));
let saved;
try { saved = await store.get(profile.id); } catch { saved = await store.save(profile, 0); }
async function activate() {
  const {active} = await store.list();
  return store.activate(saved.profile.id, saved.revision, active?.revision ?? 0);
}
async function connect() {
  const invitation = parseInvitation(await readFile(invitationPath, 'utf8'));
  const socket = new WebSocket(invitation.url, { rejectUnauthorized: false });
  const messages = [];
  socket.on('message', data => messages.push(JSON.parse(String(data))));
  await once(socket, 'open');
  assert.equal(createHash('sha256').update(socket._socket.getPeerCertificate().raw).digest('hex'), invitation.pin);
  const send = message => socket.send(JSON.stringify(message));
  async function wait(predicate, since = 0) {
    const deadline = Date.now() + 4500;
    while (Date.now() < deadline) {
      const message = messages.slice(since).find(predicate);
      if (message) return message;
      if (socket.readyState !== WebSocket.OPEN) throw Error('Receiver closed the session');
      await sleep(10);
    }
    throw Error('Timed out waiting for receiver');
  }
  send({type:'hello',v:3,phoneId,token:invitation.token});
  await wait(m => m.type === 'ready');
  return {socket,messages,send,wait};
}
await activate();
let client = await connect();
try {
  const first = await client.wait(m => m.type === 'layout');
  assert.equal(first.profile.id, profile.id);
  // Old render acknowledgement must not disconnect a newer pending activation.
  const next = await activate();
  const layout = await client.wait(m => m.type === 'layout' && m.revision === next.revision);
  client.send({type:'layout-ready',revision:first.revision});
  const marker = client.messages.length;
  client.send({type:'input',revision:first.revision,seq:1,lease:'old',state:neutralState()});
  await sleep(50);
  assert.equal(client.messages.slice(marker).some(m => m.type === 'ack'), false);
  assert.equal(client.socket.readyState, WebSocket.OPEN);
  client.send({type:'layout-ready',revision:layout.revision});
  const resumed = await client.wait(m => m.type === 'paused', marker);
  client.send({type:'input',revision:layout.revision,seq:2,lease:resumed.lease,state:neutralState()});
  await client.wait(m => m.type === 'ack' && m.seq === 2);
  // A fresh valid lease still cannot authorize an old profile revision.
  const ack = client.messages.find(m => m.type === 'ack' && m.seq === 2);
  const staleMarker = client.messages.length;
  client.send({type:'input',revision:first.revision,seq:3,lease:ack.lease,state:neutralState()});
  await sleep(40);
  assert.equal(client.messages.slice(staleMarker).some(m => m.type === 'ack' && m.seq === 3), false);
  client.send({type:'bye'});
  await once(client.socket, 'close');
  await sleep(100);
  client = await connect();
  const restored = await client.wait(m => m.type === 'layout');
  assert.equal(restored.revision, layout.revision);
  assert.equal(restored.profile.name, saved.profile.name);
  client.send({type:'bye'});
  await once(client.socket, 'close');
  console.log('PASS native receiver: queued activation, live replacement, superseded acknowledgement, stale input rejection, neutral recovery, reconnect restoration');
} finally { client.socket.terminate(); }
