// Requires a local workerd listener. Seeds a test-only session directly in local D1;
// this script neither contacts Apple/Google nor adds a production sign-in bypass.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFile, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import { makeSignature } from 'better-auth/crypto';
import { decodeJwt } from 'jose';
import { xboxProfile } from '@tapping/controller';
import { IDENTITY_SCOPES, MOBILE_SCOPES, RECEIVER_SCOPES, RECEIVER_REDIRECT_URI, CHATGPT_SCOPES, MOBILE_REDIRECT_URI } from './src/identity.js';

const directory = await mkdtemp(join(tmpdir(), 'thumble-identity-runtime-'));
const cloud = fileURLToPath(new URL('.', import.meta.url)), root = resolve(cloud, '../..');
const origin = 'https://identity.example.test';
const env = { BETTER_AUTH_URL: origin, BETTER_AUTH_SECRET: 'local-runtime-test-only-secret-with-more-than-thirty-two-bytes', CHATGPT_REDIRECT_URIS: '["https://chatgpt.com/connector_platform_oauth_redirect"]' };
let runtime;
try {
  execFileSync(process.execPath, [join(root, 'node_modules/wrangler/bin/wrangler.js'), 'deploy', '--dry-run', '--outdir', directory], { cwd: cloud, env: { ...process.env, WRANGLER_LOG_PATH: join(directory, 'wrangler.log'), WRANGLER_SEND_METRICS: 'false' }, stdio: 'pipe' });
  runtime = new Miniflare(convertV4MiniflareOptions({ modules: true, script: await readFile(join(directory, 'worker.js'), 'utf8'), compatibilityDate: '2026-10-23', compatibilityFlags: ['nodejs_compat'], bindings: env, d1Databases: ['DB'] }));
  const db = await runtime.getD1Database('DB');
  for (const migration of ['0001_cloud.sql', '0002_better_auth.sql', '0003_account_deletion.sql', '0004_provider_data_minimization.sql', '0005_receiver_pairing.sql']) {
    const sql = await readFile(new URL(`migrations/${migration}`, import.meta.url), 'utf8');
    await db.batch(sql.replace(/^--.*$/gm, '').split(/;(?=\s*(?:CREATE|UPDATE|INSERT|ALTER|DROP|PRAGMA|$))/i).map(s => s.trim()).filter(Boolean).map(s => db.prepare(s)));
  }
  const now = new Date().toISOString(), userId = crypto.randomUUID(), sessionToken = crypto.randomUUID();
  await db.batch([
    db.prepare('INSERT INTO user (id,name,email,emailVerified,createdAt,updatedAt) VALUES (?,?,?,1,?,?)').bind(userId, 'Runtime owner', 'runtime@example.test', now, now),
    db.prepare('INSERT INTO session (id,userId,token,expiresAt,createdAt,updatedAt) VALUES (?,?,?,?,?,?)').bind(crypto.randomUUID(), userId, sessionToken, new Date(Date.now() + 3600000).toISOString(), now, now),
  ]);
  const cookie = `__Secure-better-auth.session_token=${encodeURIComponent(`${sessionToken}.${await makeSignature(sessionToken, env.BETTER_AUTH_SECRET)}`)}`;
  async function request(path, { method = 'GET', value, form = false, token, session = false, expectedAccount } = {}) {
    return runtime.dispatchFetch(`${origin}${path}`, { method, redirect: 'manual', headers: { accept: value ? 'application/json' : 'text/html', 'sec-fetch-mode': value ? 'cors' : 'navigate', 'MF-Sec-Fetch-Mode': value ? 'cors' : 'navigate', 'cf-connecting-ip': '203.0.113.5', ...(expectedAccount ? { 'x-thumble-account-id': expectedAccount } : {}), ...(session ? { cookie, origin } : {}), ...(token ? { authorization: `Bearer ${token}` } : {}), ...(value ? { 'content-type': form ? 'application/x-www-form-urlencoded' : 'application/json' } : {}) }, ...(value ? { body: form ? new URLSearchParams(value).toString() : JSON.stringify(value) } : {}) });
  }
  const discovery = await request('/.well-known/oauth-authorization-server/api/auth'); assert.equal(discovery.status, 200); const metadata = await discovery.json(); assert.equal(metadata.issuer, `${origin}/api/auth`); assert.ok(metadata.token_endpoint_auth_methods_supported.includes('none')); assert.equal(metadata.registration_endpoint, undefined); assert.equal(metadata.scopes_supported.includes('devices:manage'), false);
  async function authorize(clientId) {
    const redirectUri = clientId === 'thumble-mobile' ? MOBILE_REDIRECT_URI : clientId === 'thumble-receiver' ? RECEIVER_REDIRECT_URI : 'https://chatgpt.com/connector_platform_oauth_redirect';
    const verifier = 'a'.repeat(64), challenge = Buffer.from(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier))).toString('base64url');
    const params = new URLSearchParams({ response_type: 'code', client_id: clientId, redirect_uri: redirectUri, scope: (clientId === 'thumble-chatgpt' ? CHATGPT_SCOPES : clientId === 'thumble-receiver' ? RECEIVER_SCOPES : MOBILE_SCOPES).join(' '), resource: `${origin}/mcp`, state: 'runtime-state', code_challenge: challenge, code_challenge_method: 'S256' });
    const authorization = await request(`/api/auth/oauth2/authorize?${params}`, { session: true }); assert.equal(authorization.status, 302, `authorize: ${authorization.status} ${await authorization.clone().text()}`);
    const consentPath = authorization.headers.get('location'); const consentPage = await request(consentPath, { session: true }); assert.equal(consentPage.status, 200);
    const signedQuery = new URL(consentPath, origin).search.slice(1);
    const consent = await request('/api/auth/oauth2/consent', { method: 'POST', session: true, value: { accept: true, oauth_query: signedQuery } }); assert.equal(consent.status, 200);
    const code = new URL((await consent.json()).url).searchParams.get('code'); assert.ok(code);
    const exchange = await request('/api/auth/oauth2/token', { method: 'POST', form: true, value: { grant_type: 'authorization_code', client_id: clientId, redirect_uri: redirectUri, code, code_verifier: verifier, resource: `${origin}/mcp`, ...(clientId === 'thumble-chatgpt' && env.CHATGPT_CLIENT_SECRET ? { client_secret: env.CHATGPT_CLIENT_SECRET } : {}) } });
    assert.equal(exchange.status, 200); return exchange.json();
  }
  const phoneTokens = await authorize('thumble-mobile'), agentTokens = await authorize('thumble-chatgpt');
  const receiverTokens = await authorize('thumble-receiver');
  assert.equal(receiverTokens.refresh_token, undefined);
  const receiverResponse = await request('/v1/receiver-pairing', { method: 'POST', token: receiverTokens.access_token, value: { name: 'Runtime Mac' } });
  assert.equal(receiverResponse.status, 201);
  const receiver = await receiverResponse.json();
  const pngBytes = Buffer.alloc(33); Buffer.from('89504e470d0a1a0a0000000d49484452', 'hex').copy(pngBytes); pngBytes.writeUInt32BE(474, 16); pngBytes.writeUInt32BE(474, 20);
  const png = pngBytes.toString('base64');
  const shared = await request(`/v1/receiver-pairing/${receiver.receiverId}`, { method: 'PUT', token: receiver.publisherToken, value: { sequence: 1, connected: false, png, expiresAt: Date.now() + 100_000 } });
  assert.equal(shared.status, 200);
  const codeResponse = await runtime.dispatchFetch(`${origin}/mcp`, { method: 'POST', headers: { authorization: `Bearer ${agentTokens.access_token}`, 'content-type': 'application/json', accept: 'application/json, text/event-stream' }, body: JSON.stringify({ jsonrpc: '2.0', id: 101, method: 'tools/call', params: { name: 'show_pairing_code', arguments: {} } }) });
  const code = (await codeResponse.json()).result;
  assert.equal(code.isError, undefined); assert.equal(code.content[1].type, 'image'); assert.equal(code.content[1].data, png);
  assert.equal(decodeJwt(phoneTokens.access_token).sub, userId); assert.equal(decodeJwt(agentTokens.access_token).sub, userId);
  const me = await request('/v1/me', { token: phoneTokens.access_token }); assert.equal(me.status, 200);
  const phone = await request('/v1/devices', { method: 'POST', token: phoneTokens.access_token, value: { name: 'OAuth runtime phone', platform: 'ios', viewport: { width: 844, height: 390 } } }); assert.equal(phone.status, 201); const registered = await phone.json();
  let id = 0;
  async function tool(name, args) {
    const response = await runtime.dispatchFetch(`${origin}/mcp`, { method: 'POST', headers: { authorization: `Bearer ${agentTokens.access_token}`, 'content-type': 'application/json', accept: 'application/json, text/event-stream', 'mcp-protocol-version': '2025-11-25' }, body: JSON.stringify({ jsonrpc: '2.0', id: ++id, method: 'tools/call', params: { name, arguments: args } }) });
    assert.equal(response.status, 200); const payload = await response.json(); assert.ok(!payload.result.isError, JSON.stringify(payload)); return payload.result.structuredContent;
  }
  assert.equal((await tool('save_profile', { profile: xboxProfile, deviceId: registered.device.id, expectedRevision: 0 })).revision, 1);
  const { delivery } = await tool('deliver_profile', { deviceId: registered.device.id, profileId: xboxProfile.id, profileRevision: 1, requestId: 'better-auth-journey' });
  const pending = await request(`/v1/devices/${registered.device.id}/deliveries`, { token: registered.deviceToken }); assert.equal(pending.status, 200);
  for (const state of ['received', 'rendered']) { const ack = await request(`/v1/devices/${registered.device.id}/deliveries/${delivery.id}/ack`, { method: 'POST', token: registered.deviceToken, value: { profileId: xboxProfile.id, profileRevision: 1, state } }); assert.equal(ack.status, 200); }
  assert.equal((await tool('delivery_status', { deliveryId: delivery.id })).delivery.state, 'rendered');
  const accountId = (await me.json()).accountId;
  const deletion = await request('/api/auth/delete-user', { method: 'POST', session: true, value: {}, expectedAccount: accountId });
  assert.equal(deletion.status, 200); assert.equal((await deletion.json()).success, true);
  const rejected = await request('/v1/me', { token: phoneTokens.access_token }); assert.equal(rejected.status, 401); assert.equal((await rejected.json()).error.code, 'account_deleted');
  for (const table of ['user', 'session', 'devices', 'deliveries', 'profile_revisions', 'oauthConsent', 'oauthRefreshToken', 'receiver_pairing_sessions']) assert.equal((await db.prepare(`SELECT count(*) AS n FROM ${table}`).first()).n, 0);
  assert.equal((await db.prepare('SELECT account_id FROM cloud_deleted_accounts').first()).account_id, accountId);
  await assert.rejects(db.prepare('INSERT INTO profile_revisions (account_id,profile_id,revision,name,profile_json,created_at) VALUES (?,?,?,?,?,?)').bind(accountId, xboxProfile.id, 1, xboxProfile.name, JSON.stringify(xboxProfile), now).run(), /account_deleted/);
  console.log('PASS: bundled Better Auth + D1, native and public ChatGPT PKCE/consent/token flows share account, MCP→device delivery, isolated deletion and JWT/write invalidation. Social login and phone renderer simulated.');
} finally {
  try { await runtime?.dispose(); } finally { await rm(directory, { recursive: true, force: true }); }
}
