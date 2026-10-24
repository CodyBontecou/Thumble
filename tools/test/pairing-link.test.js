import { test } from 'node:test';
import assert from 'node:assert/strict';
import { followPairingLink } from '../../apps/mobile/src/pairing-link.js';
import { Connection } from '../../apps/mobile/src/connection-core.js';

function harness(initial = 'inactive') {
  const listeners = new Set(), calls = [], events = {}, timers = new Map();
  const appState = { currentState: initial, addEventListener: (_, fn) => { listeners.add(fn); return { remove: () => listeners.delete(fn) }; } };
  const native = { addListener: (name, fn) => events[name] = fn, connect: () => { calls.push('connect'); return String(calls.length); }, disconnect() {}, send: () => true };
  const connection = new Connection(native, { beforeConnect: async () => { if (appState.currentState !== 'active') throw Error('Open Thumble before connecting to your Mac.'); }, timers: { setTimeout: fn => { timers.set(1, fn); return 1; }, clearTimeout: id => timers.delete(id), clearInterval: id => timers.delete(id) } });
  const value = 'thumble://pair?data=' + Buffer.from(JSON.stringify({ v: 1, url: 'wss://192.168.1.2:1234/controller', pin: 'a'.repeat(64), token: 'b'.repeat(64), expires: Math.floor(Date.now() / 1000) + 120 })).toString('base64url');
  const errors = [];
  const start = () => followPairingLink(connection, appState, value, error => errors.push(error.message));
  const phase = value => { appState.currentState = value; for (const fn of listeners) fn(value); };
  return { connection, calls, errors, start, phase, listeners };
}
const settle = async () => { for (let i = 0; i < 8; i++) await Promise.resolve(); };
test('a pairing link arriving during foreground transition connects once active without reopening', async () => {
  const h = harness(); const stop = h.start(); await settle();
  assert.deepEqual(h.errors, [], 'foreground transition must not fail pairing');
  assert.equal(h.calls.length, 0);
  h.phase('active'); await settle();
  assert.equal(h.calls.length, 1); assert.equal(h.connection.snapshot().phase, 'connecting');
  stop(); h.connection.disconnect();
});
test('refocusing the same link retries; repeated active events never open duplicate sockets', async () => {
  const h = harness('active'); let stop = h.start(); await settle();
  h.phase('inactive'); h.phase('active'); await settle(); assert.equal(h.calls.length, 1);
  stop(); h.connection.disconnect(); stop = h.start(); await settle(); assert.equal(h.calls.length, 2);
  stop(); h.connection.disconnect();
});
test('leaving pairing removes the foreground listener and cancels pending preparation', async () => {
  const h = harness(); const stop = h.start(); stop(); h.phase('active'); await settle();
  assert.equal(h.calls.length, 0); assert.equal(h.listeners.size, 0);
  const h2 = harness('active'); const stop2 = h2.start(); stop2(); await settle();
  assert.equal(h2.calls.length, 0); assert.equal(h2.errors.length, 0);
});
test('invalid or expired links report an actionable error without opening a socket', async () => {
  const h = harness('active');
  const stop = followPairingLink(h.connection, { currentState: 'active', addEventListener: () => ({ remove() {} }) }, 'thumble://pair?data=invalid', e => h.errors.push(e.message));
  await settle(); assert.equal(h.calls.length, 0); assert.equal(h.errors.length, 1); stop();
});

test('leaving after a successful handshake preserves the connected session', async () => {
  const h = harness('active'); const stop = h.start(); await settle();
  h.connection.update({ phase: 'connected', detail: 'Connected', rtt: null, chat: false });
  stop(); assert.equal(h.connection.snapshot().phase, 'connected');
  assert.equal(h.listeners.size, 0); h.connection.disconnect();
});
test('a foreground event during asynchronous preparation is not lost', async () => {
  const h = harness('active'); let release;
  h.connection.beforeConnect = async () => {
    await new Promise(resolve => release = resolve);
    if (h.connection.attempt === 1) throw Error('App was still becoming active');
  };
  const stop = h.start(); h.phase('inactive'); h.phase('active'); release(); await settle();
  // The foreground event was queued while preparation was pending. Let the retry finish.
  release(); await settle();
  assert.equal(h.calls.length, 1); assert.equal(h.connection.snapshot().phase, 'connecting');
  stop(); h.connection.disconnect();
});
