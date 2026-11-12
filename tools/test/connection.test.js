import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Connection } from '../../apps/mobile/src/connection-core.js';
import { neutralState, xboxProfile } from '@tapping/controller';

const invitation = () => 'tapping://pair?data=' + Buffer.from(JSON.stringify({ v: 1, url: 'wss://192.168.1.2:1234/controller', pin: 'a'.repeat(64), token: 'b'.repeat(64), expires: Math.floor(Date.now() / 1000) + 120 })).toString('base64url');
function harness(beforeConnect) {
  let time = 0, next = 0, socket = 0;
  const callbacks = new Map(), events = {}, sent = [];
  const timers = { setTimeout: (fn, delay) => { callbacks.set(++next, { fn, at: time + delay, interval: 0 }); return next; }, setInterval: (fn, delay) => { callbacks.set(++next, { fn, at: time + delay, interval: delay }); return next; }, clearTimeout: id => callbacks.delete(id), clearInterval: id => callbacks.delete(id) };
  const native = { addListener: (event, fn) => events[event] = fn, connect: () => String(++socket), send: text => { sent.push(JSON.parse(text)); return native.accept; }, disconnect: () => {}, accept: true };
  const connection = new Connection(native, { beforeConnect, timers, now: () => time });
  const emit = (event, value, id = String(socket), extra = {}) => {
    events[event]({ value: typeof value === 'string' ? value : JSON.stringify(value), id, ...extra });
    if (event === 'message' && value.type === 'ready' && value.access === 1 && connection.snapshot().phase === 'connected') events.message({ value: JSON.stringify({ type: 'access', v: 1, pro: true, enabled: true, running: true, remaining: 1800, debitedUsed: 0, receiverId: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', nonce: 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' }), id });
  };
  const ready = () => { emit('status', 'open'); emit('message', { type: 'ready', seq: -1, lease: 'first', access: 1 }); };
  const advance = duration => {
    const end = time + duration;
    while (true) {
      const due = [...callbacks].filter(([, t]) => t.at <= end).sort((a, b) => a[1].at - b[1].at)[0];
      if (!due) break;
      const [id, timer] = due; time = timer.at;
      if (timer.interval) timer.at += timer.interval; else callbacks.delete(id);
      timer.fn();
    }
    time = end;
  };
  return { connection, native, emit, ready, advance, sent, callbacks };
}
test('late callbacks from an old socket cannot affect a replacement', async () => {
  const h = harness(); await h.connection.connect(invitation()); h.ready();
  await h.connection.connect(invitation()); h.ready();
  h.emit('status', 'old socket failed', '1');
  h.emit('message', { type: 'ready', seq: -1, lease: 'old' }, '1');
  assert.equal(h.connection.snapshot().phase, 'connected');
  assert.equal(h.connection.lease, 'first');
  assert.equal(h.callbacks.size, 1);
});
test('disconnect cancels an asynchronous pairing preparation', async () => {
  let resume;
  const h = harness(() => new Promise(resolve => resume = resolve));
  const pending = h.connection.connect(invitation());
  h.connection.disconnect(); resume(); await pending;
  assert.equal(h.connection.session, null); assert.equal(h.callbacks.size, 0);
});
test('overlapping preparation only opens the latest requested pairing', async () => {
  const resumes = [];
  const h = harness(() => new Promise(resolve => resumes.push(resolve)));
  const first = h.connection.connect(invitation()), second = h.connection.connect(invitation());
  resumes[1](); await second; resumes[0](); await first;
  assert.equal(h.connection.session, '1'); assert.equal(h.callbacks.size, 1);
});
test('pause releases held controls and uses the replacement lease immediately', async () => {
  const h = harness(); await h.connection.connect(invitation()); h.ready();
  h.connection.submit({ ...neutralState(), buttons: 1 });
  h.connection.resetListeners.add(() => h.connection.submit(neutralState()));
  const start = h.sent.length;
  h.emit('message', { type: 'paused', seq: h.connection.sequence, lease: 'replacement' });
  for (const message of h.sent.slice(start)) {
    assert.equal(message.lease, 'replacement'); assert.deepEqual(message.state, neutralState());
  }
  assert.deepEqual(h.connection.state, neutralState());
});
test('duplicate acknowledgements cannot keep a dead receiver alive', async () => {
  const h = harness(); await h.connection.connect(invitation()); h.ready();
  h.emit('message', { type: 'ack', seq: 1, lease: 'fresh' });
  h.advance(1000); h.emit('message', { type: 'ack', seq: 1, lease: 'fresh' });
  h.advance(550);
  assert.equal(h.connection.snapshot().phase, 'offline'); assert.equal(h.callbacks.size, 0);
});
test('failed initial input does not leave a heartbeat running', async () => {
  const h = harness(); await h.connection.connect(invitation()); h.native.accept = false; h.ready();
  assert.equal(h.connection.snapshot().phase, 'offline'); assert.equal(h.callbacks.size, 0);
});
test('handshake timeout and invalid future acknowledgements disconnect safely', async () => {
  const h = harness(); await h.connection.connect(invitation()); h.advance(5000);
  assert.equal(h.connection.snapshot().phase, 'offline');
  await h.connection.connect(invitation()); h.ready();
  h.emit('message', { type: 'ack', seq: 999, lease: 'future' });
  assert.equal(h.connection.snapshot().phase, 'offline'); assert.deepEqual(h.connection.state, neutralState());
});
test('touch timing context never leaks into heartbeats or neutral resets', async () => {
  const h = harness(); await h.connection.connect(invitation()); h.ready();
  h.connection.withTouch(() => h.connection.submit(neutralState()));
  assert.equal(h.connection.pending.get(h.connection.sequence).kind, 'touch');
  h.advance(33);
  assert.equal(h.connection.pending.get(h.connection.sequence).kind, 'heartbeat');
  h.connection.submit(neutralState());
  assert.equal(h.connection.pending.get(h.connection.sequence).kind, 'neutral');
  assert.throws(() => h.connection.withTouch(() => { throw Error('test'); }));
  assert.equal(h.connection.inputTime, null);
});

test('layout activation releases input, blocks old geometry, and waits for fresh receiver lease', async () => {
  const { xboxProfile } = await import('@tapping/controller');
  const h = harness(); await h.connection.connect(invitation()); h.ready();
  h.connection.submit({ ...neutralState(), buttons: 1 });
  h.connection.resetListeners.add(() => h.connection.submit(neutralState()));
  const profile = structuredClone(xboxProfile); profile.name = 'Warrior';
  let observed;
  h.connection.subscribeProfile(() => { observed = h.connection.profileSnapshot(); });
  const start = h.sent.length;
  h.emit('message', { type: 'layout', revision: 3, profile });
  assert.equal(observed.profile.name, 'Warrior');
  assert.deepEqual(h.connection.state, neutralState());
  assert.equal(h.connection.layoutPending, true);
  h.connection.submit({ ...neutralState(), buttons: 1 });
  h.advance(33);
  assert.equal(h.sent.length, start, 'input is blocked until render and lease acknowledgement');
  h.connection.acknowledgeLayout(2);
  assert.equal(h.sent.length, start);
  h.connection.acknowledgeLayout(3);
  assert.deepEqual(h.sent.at(-1), { type: 'layout-ready', revision: 3 });
  h.emit('message', { type: 'paused', seq: h.connection.sequence, lease: 'new-layout' });
  assert.equal(h.sent.at(-1).revision, 3);
  assert.equal(h.sent.at(-1).lease, 'new-layout');
  assert.deepEqual(h.sent.at(-1).state, neutralState());
});
test('invalid or stale layout disconnects and reconnect can receive the same active revision', async () => {
  const { xboxProfile } = await import('@tapping/controller');
  const h = harness(); await h.connection.connect(invitation()); h.ready();
  h.emit('message', { type: 'layout', revision: 1, profile: xboxProfile });
  h.connection.acknowledgeLayout(1);
  h.emit('message', { type: 'layout', revision: 1, profile: xboxProfile });
  assert.equal(h.connection.snapshot().phase, 'offline');
  await h.connection.connect(invitation()); h.ready();
  h.emit('message', { type: 'layout', revision: 1, profile: xboxProfile });
  assert.equal(h.connection.snapshot().phase, 'connected');
  h.emit('message', { type: 'layout', revision: 2, profile: { ...xboxProfile, code: 'no' } });
  assert.equal(h.connection.snapshot().phase, 'offline');
});
test('superseded renders cannot acknowledge a more recent layout', async () => {
  const { xboxProfile } = await import('@tapping/controller');
  const h = harness(); await h.connection.connect(invitation()); h.ready();
  h.emit('message', { type: 'layout', revision: 1, profile: xboxProfile });
  h.emit('message', { type: 'layout', revision: 2, profile: xboxProfile });
  const count = h.sent.length;
  h.connection.acknowledgeLayout(1);
  assert.equal(h.sent.length, count);
  h.connection.acknowledgeLayout(2);
  assert.deepEqual(h.sent.at(-1), { type: 'layout-ready', revision: 2 });
});

test('UDP input requires the encrypted native handshake; blocked handshake keeps WebSocket input', async () => {
  const h = harness(), frames = [];
  h.native.configureDatagram = () => true;
  h.native.sendDatagram = text => { frames.push(JSON.parse(text)); return 100; };
  await h.connection.connect(invitation()); h.ready();
  h.emit('message', {type:'udp-offer',port:1234,key:Buffer.alloc(32).toString('base64')});
  h.advance(33); assert.equal(h.connection.inputTransport,'wss'); assert.equal(frames.length,0);
  h.emit('message',{type:'udp-ready'}); assert.equal(h.connection.inputTransport,'wss');
  h.emit('message',{type:'udp-ready'},'1',{transport:'udp'});
  assert.equal(h.connection.inputTransport,'udp');assert.equal(frames.length,1);assert.deepEqual(frames[0].state,neutralState());
  h.connection.disconnect(); assert.equal(h.connection.inputTransport,'wss');
  h.emit('message',{type:'udp-ready'},'1',{transport:'udp'});assert.equal(h.connection.inputTransport,'wss');
});
test('UDP send failure releases controls and closes the control session', async () => {
  const h = harness();h.native.configureDatagram=()=>true;h.native.sendDatagram=()=>-1;
  await h.connection.connect(invitation());h.ready();h.emit('message',{type:'udp-offer',port:1234,key:Buffer.alloc(32).toString('base64')});
  h.emit('message',{type:'udp-ready'},'1',{transport:'udp'});
  assert.equal(h.connection.snapshot().phase,'offline');assert.deepEqual(h.connection.state,neutralState());assert.equal(h.callbacks.size,0);
});

test('a burst of analog updates cannot disconnect a healthy but temporarily backpressured session', async () => {
  const h = harness(); await h.connection.connect(invitation()); h.ready();
  // ACK delivery runs on a later event-loop turn than this touch burst.
  for (let i = 0; i < 200; i++) h.connection.withTouch(() => h.connection.submit({ ...neutralState(), lx: i / 200 }));
  assert.equal(h.connection.snapshot().phase, 'connected');
  assert(h.connection.pending.size <= 4, 'in-flight input must be bounded below the native eight-send limit');
});

test('backpressure preserves press/release edges while merging intermediate motion', async () => {
  const h = harness(); await h.connection.connect(invitation()); h.ready();
  for (let i = 0; i < 3; i++) h.connection.submit(neutralState());
  const start = h.sent.length;
  h.connection.withTouch(() => h.connection.submit({ ...neutralState(), buttons: 1 }));
  for (let i = 0; i < 100; i++) h.connection.withTouch(() => h.connection.submit({ ...neutralState(), buttons: 1, lx: i / 100 }));
  h.connection.withTouch(() => h.connection.submit(neutralState()));
  assert.equal(h.sent.length, start);
  h.emit('message', { type: 'ack', seq: 4, lease: 'fresh' });
  const inputs = h.sent.slice(start).filter(m => m.type === 'input');
  assert.equal(inputs.length, 2);
  assert.equal(inputs[0].state.buttons, 1);
  assert.deepEqual(inputs[1].state, neutralState());
  assert.equal(h.connection.snapshot().phase, 'connected');
});

test('an expired queued press is cancelled, never replayed when ACK delivery resumes', async () => {
  const h = harness(); await h.connection.connect(invitation()); h.ready();
  for (let i = 0; i < 3; i++) h.connection.submit(neutralState());
  h.connection.submit({ ...neutralState(), buttons: 1 });
  h.advance(160);
  const start = h.sent.length;
  h.emit('message', { type: 'ack', seq: 4, lease: 'fresh' });
  assert(h.sent.slice(start).every(m => m.state.buttons === 0));
  assert.deepEqual(h.connection.state, neutralState());
});

test('heartbeats coalesce to the current held state without falsely cancelling a sustained hold', async () => {
  const h = harness(); await h.connection.connect(invitation()); h.ready();
  h.connection.withTouch(() => h.connection.submit({ ...neutralState(), lt: 1 }));
  h.advance(250); // Four in flight; subsequent heartbeat snapshots replace one another.
  const start = h.sent.length;
  h.emit('message', { type: 'ack', seq: 4, lease: 'fresh' });
  assert(h.sent.slice(start).some(m => m.state.lt === 1));
  assert.equal(h.connection.state.lt, 1);
  assert.equal(h.connection.recovering, false);
});

test('slow ACK return does not stop forward heartbeats when native writes are available', async () => {
  const h = harness(); h.native.canSendInput = () => true;
  await h.connection.connect(invitation()); h.ready();
  h.connection.submit({ ...neutralState(), lt: 1 });
  h.advance(330);
  assert(h.sent.filter(m => m.type === 'input').length >= 11);
  assert.equal(h.connection.state.lt, 1);
  assert.equal(h.connection.snapshot().phase, 'connected');
});

test('native backpressure coalesces motion, preserves edges, and retries without waiting for network ACK', async () => {
  const h = harness(); let writable = true; h.native.canSendInput = () => writable;
  await h.connection.connect(invitation()); h.ready(); writable = false;
  h.connection.withTouch(() => h.connection.submit({ ...neutralState(), buttons: 1 }));
  for (let i = 0; i < 200; i++) h.connection.withTouch(() => h.connection.submit({ ...neutralState(), buttons: 1, lx: i / 200 }));
  h.connection.withTouch(() => h.connection.submit(neutralState()));
  assert.equal(h.connection.outbox.length, 2); assert.equal(h.connection.pending.size, 1);
  writable = true; h.advance(8);
  assert.equal(h.sent.at(-2).state.buttons, 1); assert.deepEqual(h.sent.at(-1).state, neutralState());
  assert.equal(h.connection.snapshot().phase, 'connected');
  h.connection.disconnect(); assert.equal(h.callbacks.size, 0);
});

test('pause blocks held input until fresh neutral is acknowledged and clears queued edges', async () => {
  const h = harness(); await h.connection.connect(invitation()); h.ready();
  h.emit('message', { type: 'paused', seq: 1, lease: 'recover' });
  const recovery = h.sent.at(-1), start = h.sent.length;
  h.connection.withTouch(() => h.connection.submit({ ...neutralState(), buttons: 1 }));
  assert.equal(h.sent.length, start);
  h.emit('message', { type: 'ack', seq: recovery.seq, lease: 'resumed' });
  h.connection.withTouch(() => h.connection.submit({ ...neutralState(), buttons: 1 }));
  assert.equal(h.sent.at(-1).state.buttons, 1);
});

test('chat requires receiver support and never enters the datagram input path', async () => {
  const h = harness(); await h.connection.connect(invitation()); h.ready();
  await assert.rejects(h.connection.sendChat('Ready to pull', 'party'), /updated receiver/);
  h.connection.view = { ...h.connection.view, chat: true };
  h.connection.inputTransport = 'udp';
  h.native.sendDatagram = () => { throw Error('Chat must use reliable control transport'); };
  const delivery = h.connection.sendChat('Ready to pull', 'party');
  const message = h.sent.at(-1);
  assert.equal(message.type, 'chat'); assert.equal(message.text, 'Ready to pull');
  assert.equal(message.channel, 'party'); assert.equal(message.revision, 0);
  h.emit('message', { type: 'chat-result', id: message.id });
  await delivery;
  assert.equal(h.connection.snapshot().phase, 'connected');
});
test('chat matches acknowledgement IDs and surfaces receiver errors without disconnecting', async () => {
  const h = harness(); await h.connection.connect(invitation());
  h.emit('status', 'open'); h.emit('message', { type: 'ready', seq: -1, lease: 'first', access: 1, chat: 1 });
  const delivery = h.connection.sendChat('Hello', 'say');
  await assert.rejects(h.connection.sendChat('Duplicate', 'say'), /already being delivered/);
  const id = h.sent.at(-1).id;
  h.emit('message', { type: 'chat-result', id: 'old' });
  assert.equal(h.connection.chatRequest.id, id);
  h.emit('message', { type: 'chat-result', id, error: 'Bring World of Warcraft to the front.' });
  await assert.rejects(delivery, /World of Warcraft/);
  assert.equal(h.connection.snapshot().phase, 'connected');
});
test('chat disconnect rejects pending delivery and clears its timer', async () => {
  const h = harness(); await h.connection.connect(invitation()); h.ready();
  h.connection.view = { ...h.connection.view, chat: true };
  const delivery = h.connection.sendChat('Hello', 'say');
  h.connection.disconnect();
  await assert.rejects(delivery, /Check World of Warcraft/);
  assert.equal(h.connection.chatRequest, null); assert.equal(h.callbacks.size, 0);
});
test('chat rejects commands with newlines, control characters, excessive UTF-8 bytes and unknown channels', async () => {
  const { chatValidation, utf8Length } = await import('../../apps/mobile/src/connection-core.js');
  assert.equal(utf8Length('😀你好'), 10);
  for (const text of ['', '   ', 'hello\n/run dangerous()', 'hello\tworld', '\u2028', '😀'.repeat(61)]) {
    assert.ok(chatValidation(text, 'say'), JSON.stringify(text));
  }
  assert.ok(chatValidation('hello', 'whisper'));
  assert.equal(chatValidation('😀'.repeat(60), 'party'), null);
  assert.equal(chatValidation('/run is spoken as chat text', 'say'), null);
});
test('unconfirmed chat times out without automatically resending', async () => {
  const h = harness(); await h.connection.connect(invitation()); h.ready();
  h.connection.view = { ...h.connection.view, chat: true };
  h.connection.timers.clearInterval(h.connection.timer);
  const delivery = h.connection.sendChat('Hello', 'say');
  h.advance(5000);
  await assert.rejects(delivery, /could not be confirmed/);
  assert.equal(h.sent.filter(message => message.type === 'chat').length, 1);
  assert.equal(h.connection.chatRequest, null);
});

test('profile list uses paired control transport; selecting waits for rendered layout and fresh neutral ACK', async () => {
  const { xboxProfile } = await import('@tapping/controller');
  const h = harness(); await h.connection.connect(invitation()); h.ready(); h.connection.profilesSupported = true;
  const catalog = { profiles: [{id:'xbox-standard',name:'Xbox',revision:1}], activationRevision:3 };
  const list = h.connection.requestProfiles(); const request = h.sent.at(-1);
  assert.equal(request.type,'profiles-list');
  h.emit('message',{type:'profiles-result',id:request.id,catalog}); assert.deepEqual(await list,catalog);
  let completed = false; const selecting = h.connection.selectProfile(catalog.profiles[0],3).then(()=>completed=true);
  const select = h.sent.at(-1); assert.equal(select.type,'profile-select'); assert.equal(select.expectedActivationRevision,3);
  h.emit('message',{type:'profiles-result',id:select.id,catalog:{...catalog,activationRevision:4}});
  await Promise.resolve(); assert.equal(completed,false);
  h.emit('message',{type:'layout',revision:4,profile:xboxProfile});
  h.connection.acknowledgeLayout(4); h.emit('message',{type:'paused',seq:h.connection.sequence,lease:'profile-lease'});
  const neutral=h.sent.at(-1);assert.deepEqual(neutral.state,neutralState());
  h.emit('message',{type:'ack',seq:neutral.seq,lease:'active'});
  await selecting; assert.equal(completed,true);
});
test('profile conflicts, invalid catalogs, and disconnect reject without claiming activation', async () => {
  const h=harness();await h.connection.connect(invitation());h.ready();h.connection.profilesSupported=true;
  const first=h.connection.requestProfiles();h.emit('message',{type:'profiles-result',id:h.sent.at(-1).id,catalog:{profiles:[{id:'../bad'}],activationRevision:1}});
  await assert.rejects(first,/invalid profile/);
  const second=h.connection.selectProfile({id:'warrior',revision:1},2);h.emit('message',{type:'profiles-result',id:h.sent.at(-1).id,error:'Profiles changed. Refresh.'});await assert.rejects(second,/Refresh/);
  const third=h.connection.requestProfiles();h.connection.disconnect();await assert.rejects(third,/Disconnected/);
  await assert.rejects(h.connection.requestProfiles(),/Connect your computer/);
});

test('older receivers cannot be sent profile requests and duplicate requests are rejected', async () => {
  const h=harness();await h.connection.connect(invitation());h.ready();
  const before=h.sent.length;await assert.rejects(h.connection.requestProfiles(),/Update your receiver/);assert.equal(h.sent.length,before);
  h.connection.profilesSupported=true;const pending=h.connection.requestProfiles();
  await assert.rejects(h.connection.requestProfiles(),/already in progress/);
  h.emit('message',{type:'profiles-result',id:h.sent.at(-1).id,catalog:{profiles:[null],activationRevision:0}});
  await assert.rejects(pending,/invalid profile/);assert.equal(h.connection.snapshot().phase,'connected');
});

test('demo includes profiles and custom layouts; expiry blocks live input and chat only', async () => {
  const h = harness(); await h.connection.connect(invitation()); h.ready();
  const access = { type: 'access', v: 1, pro: false, enabled: true, running: true, remaining: 10, debitedUsed: 1790, receiverId: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', nonce: 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' };
  h.emit('message', access);
  h.connection.profilesSupported = true;
  const listing = h.connection.requestProfiles();
  const request = h.sent.at(-1);
  h.emit('message', { type: 'profiles-result', id: request.id, catalog: { profiles: [], activationRevision: 0 } });
  assert.deepEqual((await listing).profiles, []);
  h.connection.submit({ ...neutralState(), buttons: 1 });
  h.emit('message', { ...access, remaining: 0, enabled: false, running: false, debitedUsed: 1800 });
  assert.equal(h.connection.canPlay, false);
  const count = h.sent.length;
  h.connection.submit({ ...neutralState(), buttons: 1 });
  assert.equal(h.sent.length, count);
  await assert.rejects(h.connection.sendChat('hello', 'say'), /Start your demo/);
  h.advance(33); assert.deepEqual(h.sent.at(-1).state, neutralState());
  h.emit('message', { type: 'layout', revision: 1, profile: xboxProfile });
  assert.equal(h.connection.snapshot().phase, 'connected');
  assert.equal(h.connection.profileSnapshot().revision, 1);
});
test('legacy receivers without access negotiation cannot become an unmetered connection', async () => {
  const h = harness(); await h.connection.connect(invitation()); h.emit('status', 'open');
  h.emit('message', { type: 'ready', seq: -1, lease: 'legacy' });
  assert.equal(h.connection.snapshot().phase, 'offline');
  assert.match(h.connection.snapshot().detail, /Update your receiver/);
});

test('cloud adoption pauses input and confirms exact content only after receiver activation and neutral ACK', async () => {
  const h = harness(); await h.connection.connect(invitation()); h.ready();
  h.connection.profilesSupported = true; h.connection.cloudAdoptionSupported = true;
  const source = { service: 'https://pilot.example', accountId: 'a'.repeat(64), profileId: xboxProfile.id, revision: 7 };
  const localId = 'cloud-' + 'b'.repeat(40);
  let complete = false;
  const pending = h.connection.adoptProfile(xboxProfile, source, 0).then(value => { complete = true; return value; });
  assert.equal(h.connection.canPlay, false);
  const request = h.sent.at(-1); assert.equal(request.type, 'profile-adopt');
  const catalog = { profiles: [{ id: localId, name: xboxProfile.name, revision: 1 }], activationRevision: 1, adoption: { profileId: localId, profileRevision: 1, source } };
  h.emit('message', { type: 'profiles-result', id: request.id, catalog });
  await Promise.resolve(); assert.equal(complete, false);
  h.emit('message', { type: 'layout', revision: 1, profile: { ...xboxProfile, id: localId } });
  h.connection.acknowledgeLayout(1);
  h.emit('message', { type: 'paused', seq: h.connection.sequence, lease: 'adopt-lease' });
  const neutral = h.sent.at(-1); assert.deepEqual(neutral.state, neutralState());
  await Promise.resolve(); assert.equal(complete, false);
  h.emit('message', { type: 'ack', seq: neutral.seq, lease: 'confirmed' });
  assert.equal((await pending).activationRevision, 1);
  assert.equal(complete, true); assert.equal(h.connection.canPlay, false);
});

test('cloud adoption refuses old receivers and rejects forged provenance before success', async () => {
  const h = harness(); await h.connection.connect(invitation()); h.ready(); h.connection.profilesSupported = true;
  const source = { service: 'https://pilot.example', accountId: 'a'.repeat(64), profileId: xboxProfile.id, revision: 1 };
  await assert.rejects(h.connection.adoptProfile(xboxProfile, source, 0), /Update your receiver/);
  h.connection.cloudAdoptionSupported = true;
  const pending = h.connection.adoptProfile(xboxProfile, source, 0);
  const request = h.sent.at(-1);
  h.emit('message', { type: 'profiles-result', id: request.id, catalog: { profiles: [], activationRevision: 1, adoption: { profileId: 'cloud-' + 'b'.repeat(40), profileRevision: 1, source: { ...source, revision: 2 } } } });
  await assert.rejects(pending, /requested cloud revision/);
});

test('explicit practice retains character appearance while disconnecting input and clearing activation state', async () => {
  const h = harness(); await h.connection.connect(invitation()); h.ready();
  const profile = structuredClone(xboxProfile); profile.id = 'character-artwork'; profile.name = 'Character';
  h.emit('message', { type: 'layout', revision: 9, profile });
  h.connection.disconnect(undefined, { keepLayout: true });
  assert.equal(h.connection.snapshot().phase, 'offline');
  assert.equal(h.connection.profileSnapshot().profile.id, profile.id);
  assert.equal(h.connection.profileSnapshot().revision, 0);
  assert.equal(h.connection.canPlay, false);
  const count = h.sent.length;
  h.connection.submit({ ...neutralState(), buttons: 1, rt: 1 }); h.advance(1000);
  assert.equal(h.sent.length, count);
  assert.equal(h.connection.session, null);
  assert.equal(h.connection.layoutPending, false);
  assert.deepEqual(h.connection.state, neutralState());
  h.connection.disconnect();
  assert.notEqual(h.connection.profileSnapshot().profile.id, profile.id);
});

test('a paired phone reconnects after background and process restart without reusing its QR token', async () => {
  const saved = { value: null, async load() { return this.value; }, async save(value) { this.value = value; } };
  const h = harness(); h.connection.pairingStorage = saved;
  h.connection.phoneId = 'cccccccc-cccc-cccc-cccc-cccccccccccc';
  await h.connection.connect(invitation()); h.emit('status', 'open');
  h.emit('message', { type: 'ready', seq: -1, lease: 'first', access: 1, reconnectToken: 'c'.repeat(64) });
  await Promise.resolve();
  h.connection.suspend();
  assert.equal(h.connection.snapshot().phase, 'offline');
  await h.connection.reconnect(); h.emit('status', 'open');
  assert.equal(h.sent.at(-1).reconnectToken, 'c'.repeat(64));
  assert.equal(h.sent.at(-1).token, undefined, 'the single-use QR credential is never replayed');
  h.emit('message', { type: 'ready', seq: -1, lease: 'new', access: 1 });
  assert.equal(h.connection.snapshot().phase, 'connected');
  h.connection.suspend();
  const restarted = harness(); restarted.connection.pairingStorage = saved;
  restarted.connection.phoneId = h.connection.phoneId;
  await restarted.connection.reconnect(); restarted.emit('status', 'open');
  assert.equal(restarted.sent.at(-1).reconnectToken, 'c'.repeat(64));
  restarted.emit('message', { type: 'ready', seq: -1, lease: 'restart', access: 1 });
  assert.equal(restarted.connection.snapshot().phase, 'connected');
});

test('explicit disconnect forgets trust and never reconnects a stale saved computer', async () => {
  const saved = { value: { url: 'wss://192.168.1.2:1234/controller', pin: 'a'.repeat(64), reconnectToken: 'c'.repeat(64) }, async load() { return this.value; }, async save(value) { this.value = value; } };
  const h = harness(); h.connection.pairingStorage = saved;
  h.connection.disconnect(); await h.connection.reconnect();
  assert.equal(saved.value, null); assert.equal(h.connection.session, null);
});

test('remembered connections reject public or malformed endpoints before opening a socket', async () => {
  for (const url of ['wss://example.com:1234/controller', 'ws://192.168.1.2:1234/controller', 'wss://192.168.1.2:1234/controller?token=secret']) {
    const saved = { value: { url, pin: 'a'.repeat(64), reconnectToken: 'c'.repeat(64) }, async load() { return this.value; }, async save(value) { this.value = value; } };
    const h = harness(); h.connection.pairingStorage = saved;
    await h.connection.reconnect(); await h.connection.storageWrite;
    assert.equal(h.connection.session, null); assert.equal(saved.value, null);
  }
});

test('background during secure storage loading cannot open a late connection', async () => {
  let finish;
  const h = harness(); h.connection.pairingStorage = { load: () => new Promise(resolve => finish = resolve), save: async () => {} };
  const opening = h.connection.reconnect();
  while (!finish) await Promise.resolve();
  h.connection.suspend();
  finish({ url: 'wss://192.168.1.2:1234/controller', pin: 'a'.repeat(64), reconnectToken: 'c'.repeat(64) });
  await opening;
  assert.equal(h.connection.session, null);
});

test('a receiver that forgot this phone stops reconnect retries and clears saved trust', async () => {
  const saved = { value: { url: 'wss://192.168.1.2:1234/controller', pin: 'a'.repeat(64), reconnectToken: 'c'.repeat(64) }, async load() { return this.value; }, async save(value) { this.value = value; } };
  const h = harness(); h.connection.pairingStorage = saved;
  await h.connection.reconnect(); h.emit('status', 'open');
  h.emit('message', { type: 'forgotten' }); await h.connection.storageWrite;
  assert.equal(h.connection.snapshot().phase, 'offline');
  assert.match(h.connection.snapshot().detail, /Scan its QR code/);
  assert.equal(h.connection.remembered, null); assert.equal(saved.value, null);
});

test('transient input overload keeps the remembered computer', async () => {
  const saved = { value: null, async load() { return this.value; }, async save(value) { this.value = value; } };
  const h = harness(); h.connection.pairingStorage = saved;
  await h.connection.connect(invitation()); h.emit('status', 'open');
  h.emit('message', { type: 'ready', seq: -1, lease: 'first', access: 1, reconnectToken: 'c'.repeat(64) });
  h.connection.outbox = Array.from({ length: 64 }, () => ({ state: { buttons: -1, lt: 0, rt: 0 }, kind: 'input' }));
  h.connection.submit(neutralState(), 'input');
  await h.connection.storageWrite;
  assert.equal(h.connection.snapshot().phase, 'offline');
  assert.equal(saved.value?.reconnectToken, 'c'.repeat(64));
});

test('WoW binding requests negotiate support, match responses and release their request slot', async () => {
  const h = harness(); await h.connection.connect(invitation()); h.ready();
  await assert.rejects(h.connection.readBindings(), /Update your Mac receiver/);
  h.connection.phoneBindingsSupported = true;
  h.connection.profilesSupported = true;
  let complete = false;
  const pending = h.connection.readBindings().then(value => { complete = true; return value; });
  const request = h.sent.at(-1);
  assert.equal(request.type, 'bindings-read');
  await assert.rejects(h.connection.requestProfiles(), /in progress/);
  h.emit('message', { type: 'bindings-result', id: 'other-request', data: {} });
  await Promise.resolve(); assert.equal(complete, false);
  const page = { snapshotId: 'snapshot', spells: [], nextOffset: null };
  h.emit('message', { type: 'bindings-result', id: request.id, data: page });
  assert.deepEqual(await pending, page);
  const next = h.connection.readBindings(32, 'snapshot');
  assert.equal(h.sent.at(-1).snapshotId, 'snapshot');
  h.emit('message', { type: 'bindings-result', id: h.sent.at(-1).id, error: 'Character changed. Refresh.' });
  await assert.rejects(next, /Refresh/);
});

test('WoW binding timeouts and disconnects reject without claiming a handoff', async () => {
  const h = harness(); await h.connection.connect(invitation()); h.ready();
  h.connection.phoneBindingsSupported = true;
  h.connection.timers.clearInterval(h.connection.timer);
  const timed = h.connection.readBindings();
  h.advance(10000);
  await assert.rejects(timed, /Could not confirm/);
  const copying = h.connection.copyBindingPlan({ id: 'proposal' });
  assert.equal(h.connection.canPlay, false);
  h.connection.disconnect();
  await assert.rejects(copying, /Connection closed/);
  assert.equal(h.connection.bindingRequest, null);
  assert.equal(h.connection.phoneBindingsSupported, false);
});
