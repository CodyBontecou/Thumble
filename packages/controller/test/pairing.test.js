import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseInvitation } from '../src/pairing.js';
const now = 1_800_000_000_000;
const payload = {v:1, url:'wss://192.168.1.149:51234/controller',pin:'a'.repeat(64),token:'b'.repeat(64),expires:now/1000+120};
const qr = data => `thumble://pair?data=${Buffer.from(JSON.stringify(data)).toString('base64url')}`;
test('QR retains exact TLS identity and expiring local capability', () => assert.deepEqual(parseInvitation(qr(payload),now),{url:payload.url,pin:payload.pin,token:payload.token,expires:payload.expires}));
test('QR rejects public, cleartext, credentials, stale and malformed invitations', () => {
  for (const change of [{url:'ws://192.168.1.1:1234/controller'},{url:'wss://8.8.8.8:1234/controller'},{url:'wss://user:pass@192.168.1.1:1234/controller'},{expires:now/1000},{pin:'nope'},{v:2}]) assert.throws(()=>parseInvitation(qr({...payload,...change}),now));
  assert.throws(()=>parseInvitation('https://example.com',now));
});

test('legacy pairing links retain compatibility', () => assert.deepEqual(parseInvitation(qr(payload).replace('thumble:', 'tapping:'), now), parseInvitation(qr(payload), now)));
