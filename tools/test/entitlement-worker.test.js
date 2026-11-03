import { test } from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, verify } from 'node:crypto';
import { createWorker } from '../../apps/entitlements/src/worker.js';
import { verifyAppleTransaction } from '../../apps/entitlements/src/stores.js';
import { VerificationException, VerificationStatus } from '@apple/app-store-server-library';
const id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
const body = { platform: 'ios', proof: 'untrusted-proof', receiverId: id, nonce: id, phoneId: id };
const request = value => new Request('https://test.invalid/v1/grants', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(value) });
const keys = generateKeyPairSync('ed25519');
const env = { PURCHASE_LIMITER: { limit: async () => ({ success: true }) }, APPLE_ROOT_CERTIFICATES_BASE64: '[]', GRANT_PRIVATE_KEY: keys.privateKey.export({ type: 'pkcs8', format: 'pem' }) };
test('hosted verifier never grants access when Apple rejects a proof', async () => {
  const worker = createWorker(async () => async () => { throw Error('secret proof or key must not leak'); });
  const response = await worker.fetch(request(body), env);
  assert.equal(response.status, 422);
  assert(!JSON.stringify(await response.json()).includes('secret proof'));
});
test('hosted verifier signs both ownership and confirmed revocation for the current pairing', async () => {
  for (const pro of [true, false]) {
    const response = await createWorker(async () => async () => pro).fetch(request(body), env);
    assert.equal(response.status, 200);
    const grant = await response.json(), payload = Buffer.from(grant.payload, 'base64');
    assert(verify(null, payload, keys.publicKey, Buffer.from(grant.signature, 'base64')));
    assert.equal(JSON.parse(payload).pro, pro);
    assert.equal(JSON.parse(payload).nonce, id);
  }
});
test('hosted verifier bounds streamed bodies and rate limits before verifying purchases', async () => {
  const worker = createWorker(async () => { throw Error('must not verify'); });
  assert.equal((await worker.fetch(request(body), { ...env, PURCHASE_LIMITER: { limit: async () => ({ success: false }) } })).status, 429);
  assert.equal((await worker.fetch(request({ ...body, proof: 'a'.repeat(33000) }), env)).status, 413);
  assert.equal((await worker.fetch(request({ ...body, nonce: null }), env)).status, 400);
  assert.equal((await worker.fetch(request({ ...body, platform: 'android' }), env)).status, 503);
});

test('production verification checks current transaction identity and refunds with Apple', async () => {
  const value = { transactionId: '123', productId: 'thumble_pro_lifetime', type: 'Non-Consumable' };
  let current = value, reads = 0;
  const primary = {
    verifier: { verifyAndDecodeTransaction: async proof => proof === 'original' ? value : current },
    client: { getTransactionInfo: async id => { assert.equal(id, '123'); reads++; return { signedTransactionInfo: 'current' }; } },
  };
  assert.deepEqual(await verifyAppleTransaction('original', primary), { pro: true, until: null });
  current = { ...value, revocationDate: 123 };
  assert.deepEqual(await verifyAppleTransaction('original', primary), { pro: false, until: null });
  current = { ...value, transactionId: '456' };
  await assert.rejects(verifyAppleTransaction('original', primary));
  assert.equal(reads, 3);
});

test('App Review fallback requires a verified environment mismatch and rechecks sandbox proof', async () => {
  let reviewReads = 0;
  const value = { transactionId: '123', productId: 'thumble_pro_lifetime', type: 'Non-Consumable' };
  const review = {
    verifier: { verifyAndDecodeTransaction: async () => { reviewReads++; return value; } },
    client: { getTransactionInfo: async () => ({ signedTransactionInfo: 'sandbox-current' }) },
  };
  const rejecting = status => ({ verifier: { verifyAndDecodeTransaction: async () => { throw new VerificationException(status); } } });
  for (const status of [VerificationStatus.INVALID_CERTIFICATE, VerificationStatus.VERIFICATION_FAILURE, VerificationStatus.INVALID_APP_IDENTIFIER]) await assert.rejects(verifyAppleTransaction('untrusted', rejecting(status), review));
  assert.equal(reviewReads, 0);
  await assert.rejects(verifyAppleTransaction('sandbox', rejecting(VerificationStatus.INVALID_ENVIRONMENT)));
  assert.equal((await verifyAppleTransaction('sandbox', rejecting(VerificationStatus.INVALID_ENVIRONMENT), review)).pro, true);
  assert.equal(reviewReads, 2);
});

test('subscriptions grant access only while current and cap the grant at the plan expiry', async () => {
  const now = 1_800_000_000_000;
  let current = { transactionId: '9', productId: 'thumble_yearly', type: 'Auto-Renewable Subscription', expiresDate: now + 3 * 86400_000 };
  const primary = {
    verifier: { verifyAndDecodeTransaction: async proof => proof === 'original' ? { transactionId: '9', productId: 'thumble_yearly' } : current },
    client: { getTransactionInfo: async () => ({ signedTransactionInfo: 'current' }) },
  };
  assert.deepEqual(await verifyAppleTransaction('original', primary, null, () => now), { pro: true, until: (now + 3 * 86400_000) / 1000 });
  current = { ...current, expiresDate: now - 1000 };
  assert.deepEqual(await verifyAppleTransaction('original', primary, null, () => now), { pro: false, until: null });
  current = { ...current, type: 'Non-Consumable', expiresDate: now + 1000 };
  await assert.rejects(verifyAppleTransaction('original', primary, null, () => now), /Wrong product/);
  const until = Date.now() / 1000 + 3600;
  const response = await createWorker(async () => async (_proof, productId) => { assert.equal(productId, 'thumble_weekly'); return { pro: true, until }; })
    .fetch(request({ ...body, productId: 'thumble_weekly' }), env);
  const payload = JSON.parse(Buffer.from((await response.json()).payload, 'base64'));
  assert.equal(payload.productId, 'thumble_pro_lifetime');
  assert.equal(payload.expiresAt, until);
  assert.equal((await createWorker(async () => async () => true).fetch(request({ ...body, productId: 'thumble_monthly' }), env)).status, 400);
});
