import { test } from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, verify } from 'node:crypto';
import { handler } from '../../apps/entitlements/src/server.js';
import { createGrant } from '../../apps/entitlements/src/grants.js';
import { googleVerifier } from '../../apps/entitlements/src/stores.js';
import { ProfileStore } from '../../packages/profile-tools/src/store.js';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { xboxProfile } from '@tapping/controller';
const id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
const pair = generateKeyPairSync('ed25519');
const privateKey = pair.privateKey.export({ type: 'pkcs8', format: 'pem' });
const input = { receiverId: id, nonce: id, phoneId: id, pro: true };
test('capability grants are signed, bound, expiring and reject invalid challenges', () => {
  const grant = createGrant(input, privateKey, 100);
  const data = Buffer.from(grant.payload, 'base64');
  assert(verify(null, data, pair.publicKey, Buffer.from(grant.signature, 'base64')));
  assert(!verify(null, Buffer.from(data.toString().replace('true', 'false')), pair.publicKey, Buffer.from(grant.signature, 'base64')));
  const value = JSON.parse(data.toString());
  assert.equal(value.expiresAt - value.issuedAt, 7 * 86400);
  assert.equal(value.phoneId, id);
  assert.throws(() => createGrant({ ...input, phoneId: 'spoof' }, privateKey));
});
async function request(body, verifiers = {}) {
  const req = { method: 'POST', url: '/v1/grants', async *[Symbol.asyncIterator]() { yield Buffer.from(JSON.stringify(body)); } };
  const res = { status: 0, body: '', setHeader() {}, writeHead(status) { this.status = status; return this; }, end(body) { this.body = body; } };
  await handler({ privateKey, ...verifiers })(req, res);
  return res;
}
test('native proof verification must succeed before issuing a Pro grant', async () => {
  const body = { ...input, platform: 'android', proof: 'purchase-token' };
  const missing = await request(body); assert.equal(missing.status, 503);
  const failed = await request(body, { verifyGoogle: async () => { throw Error('Store offline'); } }); assert.equal(failed.status, 422);
  const pending = await request({ ...body, proof: '' }, { verifyGoogle: async () => true }); assert.equal(pending.status, 422);
  const success = await request(body, { verifyGoogle: async proof => { assert.equal(proof, 'purchase-token'); return true; } });
  assert.equal(success.status, 200);
  const revoked = await request(body, { verifyGoogle: async () => false });
  assert.equal(JSON.parse(Buffer.from(JSON.parse(revoked.body).payload, 'base64')).pro, false);
});
test('Google validation acknowledges completed purchases but rejects pending or consumed purchases', async () => {
  const keys = generateKeyPairSync('rsa', { modulusLength: 2048 });
  let purchase = { purchaseState: 0, consumptionState: 0, acknowledgementState: 0 }, acknowledgements = 0;
  const validator = googleVerifier({ packageName: 'test.app', credentials: { client_email: 'test@example.com', private_key: keys.privateKey.export({ type: 'pkcs8', format: 'pem' }) }, fetcher: async (url) => {
    if (url.includes('oauth2')) return { ok: true, json: async () => ({ access_token: 'test', expires_in: 3600 }) };
    if (url.endsWith(':acknowledge')) { acknowledgements++; return { ok: true }; }
    assert(url.includes('/test.app/purchases/products/tapping_pro_lifetime/tokens/'));
    return { ok: true, json: async () => purchase };
  } });
  assert.equal(await validator('token'), true); assert.equal(acknowledgements, 1);
  purchase = { purchaseState: 2 }; await assert.rejects(validator('token'), /pending/);
  purchase = { purchaseState: 0, consumptionState: 1 }; await assert.rejects(validator('token'), /invalid/);
  purchase = { purchaseState: 1 }; assert.equal(await validator('token'), false);
  assert.equal(acknowledgements, 1);
});
test('profile saves and activation do not require a purchase', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'tapping-unpaid-'));
  try {
    const store = new ProfileStore(directory);
    assert((await store.list()).profiles.length > 0);
    assert.equal((await store.save(xboxProfile, 1)).revision, 2);
    assert.equal((await store.activate(xboxProfile.id, 2, 0)).delivery, 'queued');
  } finally { await rm(directory, { recursive: true, force: true }); }
});

const { createPurchaseStore } = await import('../../apps/mobile/src/purchases/core.js');
test('purchase adapter distinguishes pending and cancellation, prevents duplicate purchase calls and retains cached ownership on errors', async () => {
  let finish, calls = 0;
  const native = { status: async () => ({ status: 'owned', proof: 'native-proof', platform: 'ios', price: '$19.99' }), purchase: () => { calls++; return new Promise(resolve => finish = resolve); } };
  const store = createPurchaseStore(native, { entitlementServiceURL: 'https://test.example', entitlementPublicKey: 'public' });
  await store.refresh(); assert.equal(store.snapshot().status, 'owned');
  const pending = store.act('purchase'); await store.act('purchase'); assert.equal(calls, 1);
  finish({ status: 'cancelled' }); await pending; assert.equal(store.snapshot().status, 'owned');
  const approval = store.act('purchase'); finish({ status: 'pending' }); await approval;
  assert.equal(store.snapshot().status, 'pending'); assert.match(store.snapshot().error, /approval/);
  native.status = async () => { throw Error('Store unavailable'); };
  await store.refresh(); assert.equal(store.snapshot().proof, 'native-proof');
});
test('purchase verification cannot deliver a grant to a replacement pairing', async () => {
  let finish, delivered = 0;
  let challenge = { receiverId: id, nonce: id };
  const store = createPurchaseStore({ status: async () => ({ status: 'owned', proof: 'native-proof', platform: 'android' }) }, { entitlementServiceURL: 'https://test.example', entitlementPublicKey: 'public' }, () => new Promise(resolve => finish = resolve));
  store.attach({ phoneId: id, accessSnapshot: () => challenge, sendGrant: () => delivered++ });
  const verifying = store.refresh();
  await new Promise(resolve => setImmediate(resolve));
  challenge = { receiverId: id, nonce: 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' };
  finish({ ok: true, json: async () => ({ payload: 'test', signature: 'test' }) }); await verifying;
  assert.equal(delivered, 0);
});

test('a slow foreground refresh cannot overwrite a completed purchase', async () => {
  let finishRefresh;
  const store = createPurchaseStore({ status: () => new Promise(resolve => finishRefresh = resolve), purchase: async () => ({ status: 'owned', proof: 'new-proof', platform: 'ios' }) }, { entitlementServiceURL: '', entitlementPublicKey: '' });
  const oldRefresh = store.refresh(); await new Promise(resolve => setImmediate(resolve));
  await store.act('purchase');
  finishRefresh({ status: 'free' }); await oldRefresh;
  assert.equal(store.snapshot().status, 'owned');
  assert.equal(store.snapshot().proof, 'new-proof');
});
