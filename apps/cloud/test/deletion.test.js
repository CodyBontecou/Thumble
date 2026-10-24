import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import { makeSignature, symmetricEncrypt } from 'better-auth/crypto';
import { exportPKCS8, generateKeyPair, jwtVerify } from 'jose';
import { xboxProfile } from '@tapping/controller';
import { createIdentity, ensureIdentityClients, identityConfig } from '../src/identity.js';
import { authenticateAccount } from '../src/auth.js';
import { cloudAccountId } from '../src/deletion.js';

async function fixture(t, apple = false) {
  const db = new DatabaseSync(':memory:'); db.exec('PRAGMA foreign_keys=ON');
  for (const migration of ['0001_cloud.sql', '0002_better_auth.sql', '0003_account_deletion.sql', '0004_provider_data_minimization.sql', '0005_receiver_pairing.sql']) db.exec(readFileSync(new URL(`../migrations/${migration}`, import.meta.url), 'utf8'));
  t.after(() => db.close());
  const env = { DB: db, BETTER_AUTH_URL: 'https://deletion.example.test', BETTER_AUTH_SECRET: 'deletion-test-only-long-stable-key-of-at-least-thirty-two-bytes' };
  let applePublicKey;
  if (apple) {
    const pair = await generateKeyPair('ES256', { extractable: true }); applePublicKey = pair.publicKey;
    Object.assign(env, { APPLE_CLIENT_ID: 'com.thumble.signin.test', APPLE_TEAM_ID: 'TESTTEAM', APPLE_KEY_ID: 'TESTKEY', APPLE_PRIVATE_KEY: await exportPKCS8(pair.privateKey) });
  }
  await ensureIdentityClients(env); const auth = await createIdentity(env), context = await auth.$context, config = identityConfig(env);
  async function owner(name) {
    const user = await context.internalAdapter.createUser({ name, email: `${name}@example.test`, emailVerified: true });
    const session = await context.internalAdapter.createSession(user.id);
    const cookie = `${context.authCookies.sessionToken.name}=${encodeURIComponent(`${session.token}.${await makeSignature(session.token, context.secret)}`)}`;
    const accountId = await cloudAccountId(config.issuer, user.id), id = crypto.randomUUID(), now = new Date().toISOString();
    db.prepare('INSERT INTO profile_revisions VALUES (?,?,?,?,?,?)').run(accountId, xboxProfile.id, 1, xboxProfile.name, JSON.stringify(xboxProfile), now);
    db.prepare('INSERT INTO receiver_pairing_sessions (id,account_id,name,publisher_hash,session_expires_at,updated_at) VALUES (?,?,?,?,?,?)').run(crypto.randomUUID(), accountId, name, 'test-publisher-hash', Date.now() + 600_000, Date.now());
    db.prepare('INSERT INTO devices (id,account_id,name,platform,width,height,token_hash,token_expires_at,created_at,last_seen_at) VALUES (?,?,?,\'ios\',844,390,?,?,?,?)').run(id, accountId, name, crypto.randomUUID(), new Date(Date.now() + 3600000).toISOString(), now, now);
    db.prepare('INSERT INTO deliveries (id,account_id,device_id,profile_id,profile_revision,request_id,state,created_at,updated_at) VALUES (?,?,?,?,1,?,\'queued\',?,?)').run(crypto.randomUUID(), accountId, id, xboxProfile.id, crypto.randomUUID(), now, now);
    // Provider's public server-only signing API is used only by this fixture.
    const { token } = await auth.api.signJWT({ body: { payload: { sub: user.id, iat: Math.floor(Date.now() / 1000), scope: 'profiles:read' } } });
    return { user, session, cookie, accountId, token };
  }
  const target = await owner('target'), other = await owner('other');
  if (apple) await context.adapter.create({ model: 'account', data: { userId: target.user.id, accountId: 'test-apple-provider-subject', providerId: 'apple', accessToken: await symmetricEncrypt({ key: context.secretConfig, data: 'apple-test-access-token' }), refreshToken: await symmetricEncrypt({ key: context.secretConfig, data: 'apple-test-refresh-token' }), createdAt: new Date(), updatedAt: new Date() } });
  function deletionRequest(account = target, expected = account.accountId) {
    return new Request(`${env.BETTER_AUTH_URL}/api/auth/delete-user`, { method: 'POST', headers: { cookie: account.cookie, origin: env.BETTER_AUTH_URL, 'content-type': 'application/json', 'x-thumble-account-id': expected, 'cf-connecting-ip': '203.0.113.5' }, body: '{}' });
  }
  const accountRequest = account => new Request(`${env.BETTER_AUTH_URL}/v1/me`, { headers: { authorization: `Bearer ${account.token}` } });
  return { db, env, auth, context, config, target, other, deletionRequest, accountRequest, applePublicKey };
}

test('fresh browser session and exact own account assertion are required before deletion', async t => {
  const f = await fixture(t);
  const mismatch = await f.auth.handler(f.deletionRequest(f.target, f.other.accountId)); assert.equal(mismatch.status, 403); assert.equal((await mismatch.json()).code, 'ACCOUNT_MISMATCH');
  f.db.prepare('UPDATE session SET createdAt = ? WHERE id = ?').run(new Date(Date.now() - 301000).toISOString(), f.target.session.id);
  const stale = await f.auth.handler(f.deletionRequest()); assert.equal(stale.status, 400); assert.equal((await stale.json()).code, 'SESSION_EXPIRED');
  assert.equal(f.db.prepare('SELECT count(*) n FROM user').get().n, 2); assert.equal(f.db.prepare('SELECT count(*) n FROM cloud_deleted_accounts').get().n, 0);
});

test('Apple revocation failure retains credentials, account, cloud data and live JWT for retry', async t => {
  const f = await fixture(t, true);
  t.mock.method(globalThis, 'fetch', async input => { assert.equal(String(input), 'https://appleid.apple.com/auth/revoke'); throw new Error('test-only provider outage'); });
  const result = await f.auth.handler(f.deletionRequest()); assert.equal(result.status, 503); assert.equal((await result.json()).code, 'APPLE_REVOCATION_FAILED');
  assert.equal(f.db.prepare('SELECT count(*) n FROM user').get().n, 2); assert.equal(f.db.prepare('SELECT count(*) n FROM devices').get().n, 2);
  assert.equal(f.db.prepare('SELECT count(*) n FROM cloud_deleted_accounts').get().n, 0);
  assert.equal(f.db.prepare('SELECT count(*) n FROM account').get().n, 1);
  assert.equal((await authenticateAccount(f.accountRequest(f.target), f.env)).accountId, f.target.accountId);
});

test('successful Apple revocation precedes isolated deletion; tokens, sessions, grants and pending codes disappear', async t => {
  const f = await fixture(t, true), now = new Date(), expiry = new Date(Date.now() + 3600000);
  await f.context.adapter.create({ model: 'oauthConsent', data: { clientId: 'thumble-mobile', userId: f.target.user.id, scopes: ['profiles:read'], createdAt: now, updatedAt: now } });
  await f.context.adapter.create({ model: 'oauthRefreshToken', data: { token: 'test-hashed-refresh', clientId: 'thumble-mobile', userId: f.target.user.id, scopes: ['profiles:read'], createdAt: now, expiresAt: expiry } });
  await f.context.adapter.create({ model: 'oauthAccessToken', data: { token: 'test-hashed-access', clientId: 'thumble-mobile', userId: f.target.user.id, scopes: ['profiles:read'], createdAt: now, expiresAt: expiry } });
  await f.context.internalAdapter.createVerificationValue({ identifier: 'pending-target-code', value: JSON.stringify({ type: 'authorization_code', userId: f.target.user.id }), expiresAt: expiry });
  await f.context.internalAdapter.createVerificationValue({ identifier: 'pending-other-code', value: JSON.stringify({ type: 'authorization_code', userId: f.other.user.id }), expiresAt: expiry });
  t.mock.method(globalThis, 'fetch', async (input, init) => {
    assert.equal(String(input), 'https://appleid.apple.com/auth/revoke'); assert.equal(init.redirect, 'error');
    const values = new URLSearchParams(init.body); assert.equal(values.get('token'), 'apple-test-refresh-token'); assert.equal(values.get('token_type_hint'), 'refresh_token');
    const secret = await jwtVerify(values.get('client_secret'), f.applePublicKey, { issuer: f.env.APPLE_TEAM_ID, audience: 'https://appleid.apple.com' }); assert.equal(secret.payload.sub, f.env.APPLE_CLIENT_ID);
    assert.equal(f.db.prepare('SELECT count(*) n FROM user').get().n, 2); // Before any erasure.
    return new Response(null, { status: 200 });
  });
  const response = await f.auth.handler(f.deletionRequest()); assert.equal(response.status, 200); assert.equal((await response.json()).success, true);
  assert.equal(f.db.prepare('SELECT count(*) n FROM user').get().n, 1); assert.equal(f.db.prepare('SELECT id FROM user').get().id, f.other.user.id);
  for (const table of ['devices', 'deliveries', 'profile_revisions', 'receiver_pairing_sessions']) { assert.equal(f.db.prepare(`SELECT count(*) n FROM ${table} WHERE account_id = ?`).get(f.target.accountId).n, 0); assert.equal(f.db.prepare(`SELECT count(*) n FROM ${table} WHERE account_id = ?`).get(f.other.accountId).n, 1); }
  for (const table of ['session', 'account', 'oauthConsent', 'oauthRefreshToken', 'oauthAccessToken']) assert.equal(f.db.prepare(`SELECT count(*) n FROM ${table} WHERE userId = ?`).get(f.target.user.id).n, 0);
  assert.equal(f.db.prepare('SELECT count(*) n FROM verification WHERE identifier = ?').get('pending-target-code').n, 0);
  assert.equal(f.db.prepare('SELECT count(*) n FROM verification WHERE identifier = ?').get('pending-other-code').n, 1);
  const marker = f.db.prepare('SELECT * FROM cloud_deleted_accounts').get(); assert.deepEqual(Object.keys(marker).sort(), ['account_id', 'deleted_at']); assert.equal(marker.account_id, f.target.accountId);
  await assert.rejects(authenticateAccount(f.accountRequest(f.target), f.env), error => error.code === 'account_deleted');
  assert.equal((await authenticateAccount(f.accountRequest(f.other), f.env)).accountId, f.other.accountId);
  assert.throws(() => f.db.prepare('INSERT INTO profile_revisions VALUES (?,?,?,?,?,?)').run(f.target.accountId, xboxProfile.id, 2, xboxProfile.name, JSON.stringify(xboxProfile), now.toISOString()), /account_deleted/);
  assert.throws(() => f.db.prepare('INSERT INTO verification (id,identifier,value,expiresAt) VALUES (?,?,?,?)').run(crypto.randomUUID(), 'late-code', JSON.stringify({ userId: f.target.user.id }), expiry.toISOString()), /account_deleted/);
});

test('Google-only users can delete without Apple calls; missing users invalidate otherwise valid signed tokens', async t => {
  const f = await fixture(t);
  t.mock.method(globalThis, 'fetch', async () => assert.fail('No Apple account, no provider revocation request'));
  const result = await f.auth.handler(f.deletionRequest()); assert.equal(result.status, 200);
  await assert.rejects(authenticateAccount(f.accountRequest(f.target), f.env), error => error.code === 'account_deleted');
  f.db.prepare('DELETE FROM user WHERE id = ?').run(f.other.user.id);
  await assert.rejects(authenticateAccount(f.accountRequest(f.other), f.env), error => error.code === 'account_deleted');
});
