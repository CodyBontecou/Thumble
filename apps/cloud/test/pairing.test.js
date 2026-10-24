import test from 'node:test';
import assert from 'node:assert/strict';
import { SCOPES } from '@tapping/cloud-contracts';
import { handleApi } from '../src/api.js';
import { callCloudTool } from '../src/mcp.js';
import { cleanPairingSessions, PAIRING_FRESH_MS } from '../src/pairing.js';
import { createTestAuthority, createTestDb, apiRequest } from './helpers.js';

// The service validates the PNG envelope; exact optical decoding is covered by native tests.
const image = Buffer.alloc(33);
Buffer.from('89504e470d0a1a0a0000000d49484452', 'hex').copy(image);
image.writeUInt32BE(474, 16); image.writeUInt32BE(474, 20);
const png = image.toString('base64');
async function fixture(t) {
  const db = createTestDb(); t.after(() => db.close());
  const authority = await createTestAuthority(), env = { ...authority.env, DB: db };
  const owner = await authority.token({ scope: SCOPES.pairingManage });
  const reader = await authority.token({ scope: SCOPES.pairingRead });
  const other = await authority.token({ sub: 'someone-else', scope: SCOPES.pairingRead });
  async function api(path, token = owner, method = 'GET', body) {
    const response = await handleApi(apiRequest(path, token, { method, body }), env);
    return { status: response.status, value: await response.json(), headers: response.headers };
  }
  async function register(name = 'My Mac') {
    const result = await api('/receiver-pairing', owner, 'POST', { name });
    assert.equal(result.status, 201); return result.value;
  }
  async function upload(session, value = {}) {
    return api(`/receiver-pairing/${session.receiverId}`, session.publisherToken, 'PUT', { sequence: 1, connected: false, png, expiresAt: Date.now() + 100_000, ...value });
  }
  return { db, env, owner, reader, other, api, register, upload };
}

test('hosted MCP returns a private native PNG only to the sharing account', async t => {
  const f = await fixture(t), session = await f.register();
  assert.equal((await f.upload(session)).status, 200);
  const other = await f.api(`/pairing-code?receiverId=${session.receiverId}`, f.other);
  assert.equal(other.status, 404); assert(!JSON.stringify(other.value).includes(png));
  const shown = await f.api('/pairing-code', f.reader);
  assert.equal(shown.status, 200); assert.equal(shown.value.png, png);
  assert.equal(shown.headers.get('cache-control'), 'no-store');
  assert(!JSON.stringify(shown.value).includes('publisher'));
  assert.notEqual(f.db.sqlite.prepare('SELECT publisher_hash FROM receiver_pairing_sessions').get().publisher_hash, session.publisherToken);
  const result = await callCloudTool(new Request('https://cloud.example.test/mcp', { headers: { authorization: `Bearer ${f.reader}` } }), f.env, { kind: 'account', scopes: [SCOPES.pairingRead] }, 'show_pairing_code', {});
  assert.equal(result.isError, undefined);
  assert.deepEqual(result.content[1], { type: 'image', mimeType: 'image/png', data: png });
  assert(!JSON.stringify(result.structuredContent).includes(png));
});

test('sharing needs explicit write permission; account credentials cannot impersonate the publisher', async t => {
  const f = await fixture(t);
  assert.equal((await f.api('/receiver-pairing', f.reader, 'POST', { name: 'Mac' })).status, 403);
  assert.equal((await f.api('/pairing-code', f.owner)).status, 403);
  const session = await f.register();
  assert.equal((await f.api(`/receiver-pairing/${session.receiverId}`, f.owner, 'PUT', {})).status, 401);
  assert.equal((await f.api(`/receiver-pairing/${session.receiverId}`, f.other, 'DELETE')).status, 401);
  assert.equal((await f.api('/receiver-pairing', f.owner, 'POST', { name: 'Mac', accountId: 'other' })).status, 400);
  const reconnect = await callCloudTool(new Request('https://cloud.example.test/mcp'), f.env, { kind: 'account', scopes: [] }, 'show_pairing_code', {});
  assert.match(reconnect._meta['mcp/www_authenticate'], /insufficient_scope/);
  assert.match(reconnect.structuredContent.error.message, /Reconnect ChatGPT/);
});

test('paired, stale, expired and revoked receivers never return a usable QR', async t => {
  const f = await fixture(t), session = await f.register();
  assert.equal((await f.upload(session)).status, 200);
  assert.equal((await f.upload(session, { sequence: 2, connected: true, png: null, expiresAt: null })).status, 200);
  assert.equal((await f.api('/pairing-code', f.reader)).value.error.code, 'already_paired');
  assert.equal(f.db.sqlite.prepare('SELECT png FROM receiver_pairing_sessions').get().png, null);
  assert.equal((await f.upload(session)).status, 409); // Delayed QR cannot restore a consumed one.
  assert.equal((await f.upload(session, { sequence: 3 })).status, 200);
  f.db.sqlite.prepare('UPDATE receiver_pairing_sessions SET updated_at = ?').run(Date.now() - PAIRING_FRESH_MS);
  assert.equal((await f.api('/pairing-code', f.reader)).status, 404);
  await cleanPairingSessions(f.env);
  assert.equal(f.db.sqlite.prepare('SELECT png FROM receiver_pairing_sessions').get().png, null);
  assert.equal((await f.upload(session, { sequence: 4 })).status, 200);
  f.db.sqlite.prepare('UPDATE receiver_pairing_sessions SET code_expires_at = ?').run(Date.now() - 1);
  assert.equal((await f.api('/pairing-code', f.reader)).status, 404);
  f.db.sqlite.prepare('UPDATE receiver_pairing_sessions SET session_expires_at = ?').run(Date.now() - 1);
  assert.equal((await f.upload(session, { sequence: 5 })).status, 401);
  await cleanPairingSessions(f.env);
  assert.equal(f.db.sqlite.prepare('SELECT COUNT(*) AS n FROM receiver_pairing_sessions').get().n, 0);
  const next = await f.register(); await f.upload(next);
  assert.equal((await f.api(`/receiver-pairing/${next.receiverId}`, next.publisherToken, 'DELETE')).status, 200);
  assert.equal((await f.api('/pairing-code', f.reader)).status, 404);
});

test('multiple Macs require explicit selection; invalid images and noncurrent invitations fail closed', async t => {
  const f = await fixture(t), first = await f.register('First'), second = await f.register('Second');
  await f.upload(first); await f.upload(second);
  const choose = await f.api('/pairing-code', f.reader);
  assert.equal(choose.value.error.code, 'choose_receiver');
  assert.deepEqual(new Set(choose.value.error.details.receivers.map(r => r.name)), new Set(['First','Second']));
  assert.equal((await f.api(`/pairing-code?receiverId=${second.receiverId}`, f.reader)).value.name, 'Second');
  for (const value of [{ png: 'no' }, { expiresAt: Date.now() - 1 }, { expiresAt: Date.now() + 180_000 }, { sequence: 0 }, { connected: true }, { url: 'http://192.168.1.1' }]) {
    assert.equal((await f.upload(first, value)).status, 400);
  }
  await f.register('Third'); await f.register('Fourth');
  assert.equal((await f.api('/receiver-pairing', f.owner, 'POST', { name: 'Fifth' })).status, 409);
});
