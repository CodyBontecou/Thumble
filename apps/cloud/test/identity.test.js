import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import { makeSignature } from 'better-auth/crypto';
import { decodeJwt, exportJWK, exportPKCS8, generateKeyPair, jwtVerify, SignJWT } from 'jose';
import { createIdentity, ensureIdentityClients, handleIdentity, identityConfig, identityOptions, generateAppleClientSecret, IDENTITY_SCOPES, MOBILE_SCOPES, RECEIVER_SCOPES, RECEIVER_REDIRECT_URI, CHATGPT_SCOPES, MOBILE_REDIRECT_URI } from '../src/identity.js';
import { authenticateAccount, getPublicConfig } from '../src/auth.js';
import { handleAuthPage } from '../src/auth-pages.js';

async function fixture(t, overrides = {}) {
  const db = new DatabaseSync(':memory:');
  db.exec('PRAGMA foreign_keys=ON');
  for (const migration of ['0001_cloud.sql', '0002_better_auth.sql', '0003_account_deletion.sql', '0004_provider_data_minimization.sql', '0005_receiver_pairing.sql']) db.exec(readFileSync(new URL(`../migrations/${migration}`, import.meta.url), 'utf8'));
  t.after(() => db.close());
  const env = { DB: db, BETTER_AUTH_URL: 'https://identity.example.test', BETTER_AUTH_SECRET: 'test-only-identity-secret-with-more-than-thirty-two-bytes', CHATGPT_CLIENT_SECRET: 'test-only-confidential-client-secret-with-more-than-thirty-two-bytes', CHATGPT_REDIRECT_URIS: '["https://chatgpt.com/connector_platform_oauth_redirect"]', ...overrides };
  await ensureIdentityClients(env);
  const auth = await createIdentity(env), ctx = await auth.$context;
  // Test-only preexisting verified user/session. There is no production sign-in bypass.
  const user = await ctx.internalAdapter.createUser({ name: 'Test owner', email: 'owner@example.test', emailVerified: true });
  const session = await ctx.internalAdapter.createSession(user.id);
  const cookie = `${ctx.authCookies.sessionToken.name}=${encodeURIComponent(`${session.token}.${await makeSignature(session.token, ctx.secret)}`)}`;
  function request(path, { method = 'GET', body, authenticated = true, form = false, origin = true } = {}) {
    return new Request(`${env.BETTER_AUTH_URL}${path}`, { method, headers: { 'cf-connecting-ip': '203.0.113.4', ...(authenticated ? { cookie } : {}), ...(origin ? { origin: env.BETTER_AUTH_URL } : {}), ...(body ? { 'content-type': form ? 'application/x-www-form-urlencoded' : 'application/json' } : {}) }, ...(body ? { body: form ? new URLSearchParams(body) : JSON.stringify(body) } : {}) });
  }
  async function authorize(clientId = 'thumble-mobile', extra = {}) {
    const verifier = 'a'.repeat(64), challenge = Buffer.from(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier))).toString('base64url');
    const redirectUri = clientId === 'thumble-mobile' ? MOBILE_REDIRECT_URI : clientId === 'thumble-receiver' ? RECEIVER_REDIRECT_URI : 'https://chatgpt.com/connector_platform_oauth_redirect';
    const params = new URLSearchParams({ response_type: 'code', client_id: clientId, redirect_uri: redirectUri, scope: (clientId === 'thumble-chatgpt' ? CHATGPT_SCOPES : clientId === 'thumble-receiver' ? RECEIVER_SCOPES : MOBILE_SCOPES).join(' '), resource: `${env.BETTER_AUTH_URL}/mcp`, state: 'test-state', code_challenge: challenge, code_challenge_method: 'S256', ...extra });
    const result = await auth.handler(request(`/api/auth/oauth2/authorize?${params}`));
    return { result, verifier, redirectUri };
  }
  async function exchange(clientId = 'thumble-mobile', resource = identityConfig(env).resource) {
    const { result, verifier, redirectUri } = await authorize(clientId, { resource });
    assert.equal(result.status, 302);
    const signedQuery = new URL(result.headers.get('location'), env.BETTER_AUTH_URL).search.slice(1);
    const page = await handleAuthPage(request(`/consent?${signedQuery}`), env);
    assert.equal(page.status, 200); assert.match(await page.text(), /Allow .* to connect/);
    const consent = await auth.handler(request('/api/auth/oauth2/consent', { method: 'POST', body: { accept: true, oauth_query: signedQuery } }));
    assert.equal(consent.status, 200); const redirect = new URL((await consent.json()).url);
    assert.equal(redirect.searchParams.get('state'), 'test-state'); assert.equal(redirect.searchParams.get('iss'), `${env.BETTER_AUTH_URL}/api/auth`);
    const tokenBody = { grant_type: 'authorization_code', client_id: clientId, redirect_uri: redirectUri, code: redirect.searchParams.get('code'), code_verifier: verifier, resource, ...(clientId === 'thumble-chatgpt' && env.CHATGPT_CLIENT_SECRET ? { client_secret: env.CHATGPT_CLIENT_SECRET } : {}) };
    const tokenResult = await auth.handler(request('/api/auth/oauth2/token', { method: 'POST', body: tokenBody, form: true, authenticated: false, origin: false }));
    assert.equal(tokenResult.status, 200); return { tokens: await tokenResult.json(), tokenBody, signedQuery };
  }
  return { env, auth, ctx, db, user, request, authorize, exchange };
}

test('Better Auth discovery and fixed persistent clients require consent and PKCE, disable DCR/password/JWT shortcut', async t => {
  const f = await fixture(t);
  const response = await handleIdentity(f.request('/api/auth/.well-known/oauth-authorization-server', { authenticated: false }), f.env);
  assert.equal(response.status, 200); const metadata = await response.json();
  assert.equal(metadata.issuer, `${f.env.BETTER_AUTH_URL}/api/auth`);
  assert.equal(metadata.token_endpoint, `${f.env.BETTER_AUTH_URL}/api/auth/oauth2/token`);
  assert.equal(metadata.registration_endpoint, undefined);
  assert.ok(metadata.token_endpoint_auth_methods_supported.includes('none'));
  assert.equal(metadata.scopes_supported.includes('devices:manage'), false);
  assert.equal(getPublicConfig(f.request('/v1/config'), f.env).auth.scopes.includes('devices:manage'), true);
  assert.equal(metadata.client_id_metadata_document_supported, undefined);
  const oidc = await f.auth.handler(f.request('/api/auth/.well-known/openid-configuration', { authenticated: false }));
  assert.ok((await oidc.json()).token_endpoint_auth_methods_supported.includes('none'));
  const provider = identityOptions(f.env).plugins.find(plugin => plugin.id === 'oauth-provider');
  assert.equal(provider.options.allowDynamicClientRegistration, false);
  assert.equal(provider.options.allowUnauthenticatedClientRegistration, false);
  const clients = f.db.prepare('SELECT clientId,clientSecret,requirePKCE,skipConsent,subjectType FROM oauthClient ORDER BY clientId').all();
  assert.equal(clients.length, 3); assert.ok(clients.every(c => c.requirePKCE === 1 && c.skipConsent === 0 && c.subjectType === 'public'));
  assert.equal(clients.find(c => c.clientId === 'thumble-mobile').clientSecret, null);
  assert.notEqual(clients.find(c => c.clientId === 'thumble-chatgpt').clientSecret, f.env.CHATGPT_CLIENT_SECRET);
  assert.equal(f.db.prepare('SELECT count(*) AS n FROM user').get().n, 1); // Only explicit test user, no bootstrap identity.
  for (const path of ['/api/auth/token', '/api/auth/sign-in/email', '/api/auth/oauth2/register']) assert.ok((await f.auth.handler(f.request(path, { method: 'POST', body: {} }))).status >= 400);
  assert.equal(getPublicConfig(f.request('/v1/config'), f.env).auth.scopes.includes('offline_access'), true);
});

test('native PKCE and confidential ChatGPT flows yield signed audience-bound JWTs for the same account', async t => {
  const f = await fixture(t);
  const phone = await f.exchange(), agent = await f.exchange('thumble-chatgpt');
  const claims = decodeJwt(phone.tokens.access_token);
  assert.equal(claims.iss, `${f.env.BETTER_AUTH_URL}/api/auth`); assert.ok([claims.aud].flat().includes(`${f.env.BETTER_AUTH_URL}/mcp`));
  assert.equal(claims.sub, f.user.id); assert.equal(decodeJwt(agent.tokens.access_token).sub, f.user.id);
  const principal = await authenticateAccount(new Request(`${f.env.BETTER_AUTH_URL}/v1/me`, { headers: { authorization: `Bearer ${phone.tokens.access_token}` } }), f.env);
  const other = await authenticateAccount(new Request(`${f.env.BETTER_AUTH_URL}/mcp`, { headers: { authorization: `Bearer ${agent.tokens.access_token}` } }), f.env);
  assert.equal(principal.accountId, other.accountId); assert.ok(principal.scopes.includes('deliveries:write'));
  assert.ok(phone.tokens.refresh_token); assert.ok(phone.tokens.id_token);
  await assert.rejects(authenticateAccount(new Request(`${f.env.BETTER_AUTH_URL}/v1/me`, { headers: { authorization: `Bearer ${phone.tokens.id_token}` } }), f.env), error => error.code === 'unauthorized');
  assert.ok(f.db.prepare('SELECT privateKey FROM jwks').get().privateKey.startsWith('{') === false); // Encrypted at rest.
  const refreshed = await f.auth.handler(f.request('/api/auth/oauth2/token', { method: 'POST', form: true, body: { grant_type: 'refresh_token', client_id: 'thumble-mobile', refresh_token: phone.tokens.refresh_token, resource: `${f.env.BETTER_AUTH_URL}/mcp` }, authenticated: false, origin: false }));
  assert.equal(refreshed.status, 200); assert.equal(decodeJwt((await refreshed.json()).access_token).sub, f.user.id);
  const replay = await f.auth.handler(f.request('/api/auth/oauth2/token', { method: 'POST', form: true, body: phone.tokenBody, authenticated: false, origin: false })); assert.equal(replay.status, 400);

});

test('Mac pairing uses its own consented PKCE client without phone permissions or refresh tokens', async t => {
  const f = await fixture(t), receiver = await f.exchange('thumble-receiver');
  assert.deepEqual(decodeJwt(receiver.tokens.access_token).scope.split(' ').sort(), [...RECEIVER_SCOPES].sort());
  assert.equal(receiver.tokens.refresh_token, undefined);
  assert.equal(getPublicConfig(f.request('/v1/config'), f.env).auth.scopes.includes('pairing:manage'), false);
  assert(CHATGPT_SCOPES.includes('pairing:read'));
  assert(!CHATGPT_SCOPES.includes('pairing:manage'));
  for (const client of ['thumble-mobile', 'thumble-chatgpt']) {
    const rejected = await f.authorize(client, { scope: 'openid pairing:manage' });
    assert.match(rejected.result.headers.get('location') || '', /error=invalid_scope/);
  }
  const invalid = await f.authorize('thumble-receiver', { redirect_uri: 'thumble-receiver://attacker/callback' });
  assert.match(invalid.result.headers.get('location') || '', /error=/);
});

test('login handoff is signed, redirect and resource substitution and forged consent are rejected', async t => {
  const f = await fixture(t);
  const { result, verifier, redirectUri } = await f.authorize();
  const query = new URL(result.headers.get('location'), f.env.BETTER_AUTH_URL).search.slice(1);
  const login = await f.auth.handler(f.request(`/api/auth/oauth2/authorize?${new URLSearchParams(query)}`, { authenticated: false }));
  assert.equal(login.status, 302); assert.equal(new URL(login.headers.get('location'), f.env.BETTER_AUTH_URL).pathname, '/sign-in');
  const tampered = query.replace('test-state', 'stolen-state');
  const rejected = await f.auth.handler(f.request('/api/auth/oauth2/consent', { method: 'POST', body: { accept: true, oauth_query: tampered } })); assert.ok(rejected.status >= 400);
  const foreign = await f.authorize('thumble-mobile', { redirect_uri: 'https://attacker.example/callback' }); assert.ok(foreign.result.status >= 400 || (new URL(foreign.result.headers.get('location'), f.env.BETTER_AUTH_URL).origin === f.env.BETTER_AUTH_URL && new URL(foreign.result.headers.get('location'), f.env.BETTER_AUTH_URL).searchParams.has('error')));
  const invalidResource = await f.authorize('thumble-mobile', { resource: 'https://attacker.example/mcp' });
  assert.ok(invalidResource.result.status >= 400 || new URL(invalidResource.result.headers.get('location'), f.env.BETTER_AUTH_URL).searchParams.has('error'));
  const consent = await f.auth.handler(f.request('/api/auth/oauth2/consent', { method: 'POST', body: { accept: true, oauth_query: query } }));
  const code = new URL((await consent.json()).url).searchParams.get('code');
  const wrongVerifier = await f.auth.handler(f.request('/api/auth/oauth2/token', { method: 'POST', form: true, body: { grant_type: 'authorization_code', client_id: 'thumble-mobile', redirect_uri: redirectUri, code, code_verifier: `${verifier}wrong`, resource: `${f.env.BETTER_AUTH_URL}/mcp` }, authenticated: false, origin: false })); assert.equal(wrongVerifier.status, 400);
});

test('Google login uses configured provider and canonical callback; Apple client secrets are short-lived ES256 JWTs', async t => {
  const f = await fixture(t, { GOOGLE_CLIENT_ID: 'test-google-client', GOOGLE_CLIENT_SECRET: 'test-google-secret' });
  assert.deepEqual(identityConfig(f.env).providers, ['google']);
  const signIn = await f.auth.handler(f.request('/api/auth/sign-in/social', { method: 'POST', authenticated: false, body: { provider: 'google', callbackURL: `${f.env.BETTER_AUTH_URL}/sign-in` } }));
  assert.equal(signIn.status, 200); const googleUrl = new URL((await signIn.json()).url);
  assert.equal(googleUrl.hostname, 'accounts.google.com'); assert.equal(googleUrl.searchParams.get('redirect_uri'), `${f.env.BETTER_AUTH_URL}/api/auth/callback/google`);
  const { privateKey, publicKey } = await generateKeyPair('ES256', { extractable: true });
  const apple = { APPLE_CLIENT_ID: 'com.thumble.signin', APPLE_TEAM_ID: 'TESTTEAM', APPLE_KEY_ID: 'TESTKEY', APPLE_PRIVATE_KEY: await exportPKCS8(privateKey) };
  const secret = await generateAppleClientSecret(apple);
  const verified = await jwtVerify(secret, publicKey, { issuer: apple.APPLE_TEAM_ID, audience: 'https://appleid.apple.com' });
  assert.equal(verified.payload.sub, apple.APPLE_CLIENT_ID); assert.equal(verified.protectedHeader.kid, apple.APPLE_KEY_ID); assert.equal(verified.payload.exp - verified.payload.iat, 300);
  const appleFixture = await fixture(t, apple);
  const appleSignIn = await appleFixture.auth.handler(appleFixture.request('/api/auth/sign-in/social', { method: 'POST', authenticated: false, body: { provider: 'apple', callbackURL: `${appleFixture.env.BETTER_AUTH_URL}/sign-in` } }));
  assert.equal(appleSignIn.status, 200); assert.equal(new URL((await appleSignIn.json()).url).hostname, 'appleid.apple.com');
  assert.match(appleSignIn.headers.get('set-cookie'), /SameSite=None/i);
  assert.match(appleSignIn.headers.get('set-cookie'), /Path=\/api\/auth\/callback/i);
  assert.equal(identityOptions(appleFixture.env).advanced.defaultCookieAttributes, undefined);
  await appleFixture.ctx.adapter.create({ model: 'account', data: { userId: appleFixture.user.id, providerId: 'apple', accountId: 'known-apple-sub', createdAt: new Date(), updatedAt: new Date() } });
  const appleProvider = await identityOptions(appleFixture.env).socialProviders.apple();
  assert.equal((await appleProvider.mapProfileToUser({ sub: 'known-apple-sub' })).email, appleFixture.user.email);
  assert.equal((await appleProvider.mapProfileToUser({ sub: 'different-apple-sub' })).email, undefined);
  assert.throws(() => identityOptions({ ...f.env, BETTER_AUTH_SECRET: '' }), /configured/);
});


test('Google code callback resumes the signed OAuth request into consent', async t => {
  const f = await fixture(t, { GOOGLE_CLIENT_ID: 'test-google-client', GOOGLE_CLIENT_SECRET: 'test-google-secret' });
  const { result } = await f.authorize();
  const signedQuery = new URL(result.headers.get('location'), f.env.BETTER_AUTH_URL).search.slice(1);
  const social = await f.auth.handler(f.request('/api/auth/sign-in/social', { method: 'POST', authenticated: false, body: { provider: 'google', callbackURL: `${f.env.BETTER_AUTH_URL}/sign-in?${signedQuery}`, oauth_query: signedQuery } }));
  assert.equal(social.status, 200);
  const googleUrl = new URL((await social.json()).url);
  const stateCookie = social.headers.getSetCookie().map(cookie => cookie.split(';')[0]).join('; ');
  const { privateKey, publicKey } = await generateKeyPair('RS256');
  const key = { ...await exportJWK(publicKey), alg: 'RS256', use: 'sig', kid: 'test-google-signing-key' };
  let tokenCalls = 0;
  t.mock.method(globalThis, 'fetch', async (input, init) => {
    const url = String(input instanceof Request ? input.url : input);
    if (url === 'https://oauth2.googleapis.com/token') {
      tokenCalls++;
      const params = new URLSearchParams(init.body);
      assert.equal(params.get('code'), 'test-google-code');
      assert.equal(params.get('client_id'), f.env.GOOGLE_CLIENT_ID);
      const actualChallenge = Buffer.from(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(params.get('code_verifier')))).toString('base64url');
      assert.equal(actualChallenge, googleUrl.searchParams.get('code_challenge'));
      const idToken = await new SignJWT({ email: f.user.email, email_verified: true, name: f.user.name, picture: 'https://images.example.test/provider-avatar' }).setProtectedHeader({ alg: 'RS256', kid: key.kid }).setIssuer('https://accounts.google.com').setSubject('test-google-owner').setAudience(f.env.GOOGLE_CLIENT_ID).setIssuedAt().setExpirationTime('5m').sign(privateKey);
      return Response.json({ access_token: 'test-provider-access-token', token_type: 'Bearer', expires_in: 300, id_token: idToken });
    }
    if (url === 'https://www.googleapis.com/oauth2/v3/certs') return Response.json({ keys: [key] });
    throw new Error('Unexpected network request in isolated Google fixture');
  });
  const callback = await f.auth.handler(new Request(`${f.env.BETTER_AUTH_URL}/api/auth/callback/google?code=test-google-code&state=${encodeURIComponent(googleUrl.searchParams.get('state'))}`, { headers: { cookie: stateCookie, accept: 'text/html', 'sec-fetch-mode': 'navigate', 'cf-connecting-ip': '203.0.113.4' } }));
  assert.equal(callback.status, 302);
  const destination = new URL(callback.headers.get('location'), f.env.BETTER_AUTH_URL);
  assert.equal(destination.pathname, '/consent');
  assert.equal(destination.searchParams.get('client_id'), 'thumble-mobile');
  assert.equal(destination.searchParams.get('resource'), `${f.env.BETTER_AUTH_URL}/mcp`);
  assert.equal(tokenCalls, 1);
  const loginCookies = callback.headers.getSetCookie().map(cookie => cookie.split(';')[0]).join('; ');
  const session = await f.auth.api.getSession({ headers: new Headers({ cookie: loginCookies }) });
  assert.equal(session.user.id, f.user.id);
  assert.equal(f.db.prepare('SELECT image FROM user WHERE id = ?').get(f.user.id).image, null);
  assert.notEqual(f.db.prepare('SELECT accessToken FROM account').get().accessToken, 'test-provider-access-token');
  assert.equal(f.db.prepare('SELECT idToken FROM account').get().idToken, null);
});


test('fixed public ChatGPT client uses PKCE without a copied secret and preserves redirect/scope boundaries', async t => {
  const f = await fixture(t, { CHATGPT_CLIENT_SECRET: undefined });
  const row = f.db.prepare('SELECT clientSecret,tokenEndpointAuthMethod,requirePKCE FROM oauthClient WHERE clientId = ?').get('thumble-chatgpt');
  assert.equal(row.clientSecret, null); assert.equal(row.tokenEndpointAuthMethod, 'none'); assert.equal(row.requirePKCE, 1);
  const { tokens } = await f.exchange('thumble-chatgpt');
  assert.equal(decodeJwt(tokens.access_token).scope.split(' ').includes('devices:manage'), false);
  const registered = await f.ctx.adapter.findOne({ model: 'oauthClient', where: [{ field: 'clientId', value: 'thumble-chatgpt' }] });
  assert.equal(registered.scopes.includes('devices:manage'), false);
  const native = await f.ctx.adapter.findOne({ model: 'oauthClient', where: [{ field: 'clientId', value: 'thumble-mobile' }] });
  assert.equal(native.scopes.includes('devices:manage'), true);
  const prohibited = await f.authorize('thumble-chatgpt', { scope: 'openid devices:manage' });
  assert.equal(new URL(prohibited.result.headers.get('location'), f.env.BETTER_AUTH_URL).searchParams.get('error'), 'invalid_scope');
  const { token: formerlyIssued } = await f.auth.api.signJWT({ body: { payload: { sub: f.user.id, client_id: 'thumble-chatgpt', iat: Math.floor(Date.now()/1000), scope: 'profiles:read devices:manage' } } });
  await assert.rejects(authenticateAccount(new Request(`${f.env.BETTER_AUTH_URL}/v1/me`, { headers: { authorization: `Bearer ${formerlyIssued}` } }), f.env), error => error.code === 'forbidden');
  assert.equal(decodeJwt(tokens.access_token).sub, f.user.id);
  const narrowed = await f.authorize('thumble-chatgpt', { scope: 'profiles:read' });
  const query = new URL(narrowed.result.headers.get('location'), f.env.BETTER_AUTH_URL).search.slice(1);
  const escalated = await f.auth.handler(f.request('/api/auth/oauth2/consent', { method: 'POST', body: { accept: true, oauth_query: query, scope: 'profiles:read deliveries:write' } }));
  assert.equal(escalated.status, 400);
  const changedResource = query.replace(encodeURIComponent(`${f.env.BETTER_AUTH_URL}/mcp`), encodeURIComponent('https://attacker.example/mcp'));
  const substituted = await f.auth.handler(f.request('/api/auth/oauth2/consent', { method: 'POST', body: { accept: true, oauth_query: changedResource } })); assert.equal(substituted.status, 400);
  assert.throws(() => identityOptions({ ...f.env, BETTER_AUTH_URL: 'https://identity.example.test/path' }), /not configured/);
  await assert.rejects(ensureIdentityClients({ ...f.env, CHATGPT_REDIRECT_URIS: '["https://chatgpt.com.attacker.example/callback"]' }), /exact HTTPS ChatGPT/);
});


test('canonical MCP audience works across hosts while installed pilot clients retain their audience', async t => {
  const f = await fixture(t, { MCP_RESOURCE_URL: 'https://thumble.example.test/mcp', CHATGPT_CLIENT_SECRET: undefined });
  const config = getPublicConfig(f.request('/v1/config'), f.env);
  assert.equal(config.mcpUrl, 'https://thumble.example.test/mcp');
  assert.equal(config.auth.audience, config.mcpUrl);
  assert.equal(config.auth.issuer, `${f.env.BETTER_AUTH_URL}/api/auth`);
  const canonical = await f.exchange('thumble-chatgpt');
  const legacy = await f.exchange('thumble-mobile', `${f.env.BETTER_AUTH_URL}/mcp`);
  assert.ok([decodeJwt(canonical.tokens.access_token).aud].flat().includes(config.mcpUrl));
  assert.ok([decodeJwt(legacy.tokens.access_token).aud].flat().includes(`${f.env.BETTER_AUTH_URL}/mcp`));
  const principals = await Promise.all([canonical, legacy].map(({ tokens }) => authenticateAccount(new Request(config.mcpUrl, { headers: { authorization: `Bearer ${tokens.access_token}` } }), f.env)));
  assert.equal(principals[0].accountId, principals[1].accountId);
  assert.equal(principals[0].scopes.includes('devices:manage'), false);
  const foreign = await f.authorize('thumble-chatgpt', { resource: 'https://attacker.example/mcp' });
  assert.ok(foreign.result.status >= 400 || new URL(foreign.result.headers.get('location'), f.env.BETTER_AUTH_URL).searchParams.has('error'));
  for (const resource of ['http://thumble.example.test/mcp', 'https://thumble.example.test/wrong', 'https://thumble.example.test/mcp?token=bad']) {
    assert.throws(() => identityConfig({ ...f.env, MCP_RESOURCE_URL: resource }), error => error.code === 'not_configured');
  }
});

test('email codes verify inbox ownership, stay hashed, reject wrong/reused codes and preserve existing user identity', async t => {
  const messages = [];
  const f = await fixture(t, { EMAIL_FROM: 'signin@auth.thumble.io', EMAIL: { send: async message => { messages.push(message); return { messageId: 'test-email' }; } } });
  assert.ok(identityConfig(f.env).providers.includes('email'));
  const send = await f.auth.handler(f.request('/api/auth/email-otp/send-verification-otp', { method: 'POST', authenticated: false, body: { email: f.user.email, type: 'sign-in' } }));
  assert.equal(send.status, 200); assert.equal((await send.json()).success, true); assert.equal(send.headers.get('set-cookie'), null);
  assert.equal(messages.length, 1); assert.equal(messages[0].to, f.user.email);
  const otp = messages[0].text.match(/code is (\d{6})/)[1];
  assert.ok(f.db.prepare('SELECT value FROM verification').all().every(row => !row.value.includes(otp)));
  const signIn = code => f.auth.handler(f.request('/api/auth/sign-in/email-otp', { method: 'POST', authenticated: false, body: { email: f.user.email, otp: code } }));
  assert.equal((await signIn(otp === '000000' ? '000001' : '000000')).status, 400);
  const verified = await signIn(otp); assert.equal(verified.status, 200); assert.equal((await verified.json()).user.id, f.user.id); assert.ok(verified.headers.get('set-cookie'));
  assert.equal(f.db.prepare('SELECT count(*) AS n FROM user').get().n, 1);
  assert.equal((await signIn(otp)).status, 400);
  for (const path of ['/email-otp/check-verification-otp', '/email-otp/verify-email', '/email-otp/request-password-reset', '/email-otp/change-email']) assert.equal((await f.auth.handler(f.request(`/api/auth${path}`, { method: 'POST', body: {} }))).status, 404);
});

test('new email reviewer signs in through signed OAuth, requires consent and obtains an exact-resource PKCE token', async t => {
  let otp;
  const f = await fixture(t, { CHATGPT_CLIENT_SECRET: undefined, EMAIL_FROM: 'signin@auth.thumble.io', EMAIL: { send: async message => { otp = message.text.match(/code is (\d{6})/)[1]; } } });
  const verifier = 'reviewer-verifier-'.repeat(4), challenge = Buffer.from(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier))).toString('base64url');
  const redirectUri = 'https://chatgpt.com/connector_platform_oauth_redirect', resource = `${f.env.BETTER_AUTH_URL}/mcp`;
  const params = new URLSearchParams({ response_type: 'code', client_id: 'thumble-chatgpt', redirect_uri: redirectUri, scope: CHATGPT_SCOPES.join(' '), resource, state: 'email-reviewer-state', code_challenge: challenge, code_challenge_method: 'S256' });
  const begin = await f.auth.handler(f.request(`/api/auth/oauth2/authorize?${params}`, { authenticated: false })); assert.equal(begin.status, 302);
  const signedQuery = new URL(begin.headers.get('location'), f.env.BETTER_AUTH_URL).search.slice(1);
  const email = 'reviewer@example.test';
  const send = await f.auth.handler(f.request('/api/auth/email-otp/send-verification-otp', { method: 'POST', authenticated: false, body: { email, type: 'sign-in' } })); assert.equal(send.status, 200);
  const loginBody = { email, otp, oauth_query: signedQuery };
  const tampered = await f.auth.handler(f.request('/api/auth/sign-in/email-otp', { method: 'POST', authenticated: false, body: { ...loginBody, oauth_query: `${signedQuery}&scope=devices:manage` } })); assert.equal(tampered.status, 400);
  const login = await f.auth.handler(f.request('/api/auth/sign-in/email-otp', { method: 'POST', authenticated: false, body: loginBody })); assert.equal(login.status, 200);
  const next = await login.json(); assert.match(next.url, /\/consent\?/);
  const sessionCookie = login.headers.get('set-cookie').split(';')[0];
  const consentQuery = new URL(next.url, f.env.BETTER_AUTH_URL).search.slice(1);
  const consent = await f.auth.handler(new Request(`${f.env.BETTER_AUTH_URL}/api/auth/oauth2/consent`, { method: 'POST', headers: { origin: f.env.BETTER_AUTH_URL, cookie: sessionCookie, 'content-type': 'application/json' }, body: JSON.stringify({ accept: true, oauth_query: consentQuery }) })); assert.equal(consent.status, 200);
  const callback = new URL((await consent.json()).url); assert.equal(callback.searchParams.get('state'), 'email-reviewer-state');
  const exchange = await f.auth.handler(f.request('/api/auth/oauth2/token', { method: 'POST', authenticated: false, origin: false, form: true, body: { grant_type: 'authorization_code', client_id: 'thumble-chatgpt', redirect_uri: redirectUri, code: callback.searchParams.get('code'), code_verifier: verifier, resource } })); assert.equal(exchange.status, 200);
  const claims = decodeJwt((await exchange.json()).access_token); assert.ok([claims.aud].flat().includes(resource)); assert.ok(!claims.scope.split(' ').includes('devices:manage'));
  const reviewer = f.db.prepare('SELECT id,emailVerified FROM user WHERE email = ?').get(email); assert.equal(reviewer.id, claims.sub); assert.equal(reviewer.emailVerified, 1); assert.notEqual(reviewer.id, f.user.id);
});

test('email code failures, expiry, exhausted attempts and request throttling fail closed', async t => {
  let otp;
  const f = await fixture(t, { EMAIL_FROM: 'signin@auth.thumble.io', EMAIL: { send: async message => { otp = message.text.match(/code is (\d{6})/)[1]; } } });
  const send = email => f.auth.handler(f.request('/api/auth/email-otp/send-verification-otp', { method: 'POST', authenticated: false, body: { email, type: 'sign-in' } }));
  const verify = (email, code, ip) => f.auth.handler(new Request(`${f.env.BETTER_AUTH_URL}/api/auth/sign-in/email-otp`, { method: 'POST', headers: { origin: f.env.BETTER_AUTH_URL, 'content-type': 'application/json', 'cf-connecting-ip': ip }, body: JSON.stringify({ email, otp: code }) }));
  const email = 'expiry@example.test'; assert.equal((await send(email)).status, 200);
  f.db.prepare('UPDATE verification SET expiresAt = ?').run(new Date(Date.now() - 1000).toISOString());
  assert.equal((await verify(email, otp, '203.0.113.20')).status, 400);
  assert.equal((await send(email)).status, 200);
  const wrong = otp === '000000' ? '000001' : '000000';
  for (let i = 0; i < 3; i++) assert.equal((await verify(email, wrong, `203.0.113.${21 + i}`)).status, 400);
  assert.ok((await verify(email, otp, '203.0.113.24')).status >= 400);
  assert.equal((await send('throttle@example.test')).status, 200);
  assert.equal((await send('throttle@example.test')).status, 429);
  assert.equal(f.db.prepare('SELECT count(*) AS n FROM user').get().n, 1);
  const failed = await fixture(t, { EMAIL_FROM: 'signin@auth.thumble.io', EMAIL: { send: async () => { throw Error('transport-failure'); } } });
  const failure = await failed.auth.handler(failed.request('/api/auth/email-otp/send-verification-otp', { method: 'POST', authenticated: false, body: { email: 'transport@example.test', type: 'sign-in' } })); assert.equal(failure.status, 200); assert.equal(failure.headers.get('set-cookie'), null); assert.equal(failed.db.prepare('SELECT count(*) AS n FROM user').get().n, 1);
});

test('operator-registered Claude client requires its own secret, exact callback, consent and limited PKCE scopes', async t => {
  const { claudeClientRow, claudeClientSql, CLAUDE_CLIENT_ID, CLAUDE_REDIRECT_URI, CLAUDE_SCOPES } = await import('../../../tools/lib/claude-oauth-client.mjs');
  const f = await fixture(t, { MCP_RESOURCE_URL: 'https://thumble.io/mcp' });
  const claudeScopes = CLAUDE_SCOPES;
  assert.throws(() => claudeClientRow('x'.repeat(64), ['openid', 'pairing:read']), /hosted AI/);
  assert.throws(() => claudeClientSql(claudeClientRow('x'.repeat(64)), 'https://attacker.example/mcp'), /canonical/);
  const secret = 'claude-test-only-secret-with-at-least-thirty-two-characters';
  f.db.exec(claudeClientSql(claudeClientRow(secret, claudeScopes)));
  // Routine provisioning must preserve independently operator-managed clients.
  await ensureIdentityClients(f.env);
  const registered = f.db.prepare('SELECT * FROM oauthClient WHERE clientId=?').get(CLAUDE_CLIENT_ID);
  assert.notEqual(registered.clientSecret, secret);
  assert.equal(registered.requirePKCE, 1); assert.equal(registered.skipConsent, 0);
  for (const extra of [{ scope: 'openid devices:manage' }, { scope: 'openid pairing:manage' }, { redirect_uri: 'https://claude.ai.attacker.example/api/mcp/auth_callback' }]) {
    const { result } = await f.authorize(CLAUDE_CLIENT_ID, { redirect_uri: CLAUDE_REDIRECT_URI, scope: claudeScopes.join(' '), resource: 'https://thumble.io/mcp', ...extra });
    assert.ok(result.status >= 400 || new URL(result.headers.get('location'), f.env.BETTER_AUTH_URL).searchParams.has('error'));
  }
  const { result, verifier } = await f.authorize(CLAUDE_CLIENT_ID, { redirect_uri: CLAUDE_REDIRECT_URI, scope: claudeScopes.join(' '), resource: 'https://thumble.io/mcp' });
  assert.equal(result.status, 302);
  const signedQuery = new URL(result.headers.get('location'), f.env.BETTER_AUTH_URL).search.slice(1);
  const consent = await f.auth.handler(f.request('/api/auth/oauth2/consent', { method: 'POST', body: { accept: true, oauth_query: signedQuery } }));
  assert.equal(consent.status, 200);
  const code = new URL((await consent.json()).url).searchParams.get('code');
  const body = { grant_type: 'authorization_code', client_id: CLAUDE_CLIENT_ID, redirect_uri: CLAUDE_REDIRECT_URI, code, code_verifier: verifier, resource: 'https://thumble.io/mcp' };
  const missingSecret = await f.auth.handler(f.request('/api/auth/oauth2/token', { method: 'POST', form: true, body, authenticated: false, origin: false }));
  assert.ok(missingSecret.status >= 400);
  const exchanged = await f.auth.handler(f.request('/api/auth/oauth2/token', { method: 'POST', form: true, body: { ...body, client_secret: secret }, authenticated: false, origin: false }));
  assert.equal(exchanged.status, 200);
  const tokens = await exchanged.json(); assert.ok(tokens.refresh_token);
  const claims = decodeJwt(tokens.access_token); assert.ok([claims.aud].flat().includes('https://thumble.io/mcp')); assert.equal(claims.sub, f.user.id);
  assert.equal(claims.scope.split(' ').some(scope => ['devices:manage', 'pairing:manage'].includes(scope)), false);
});

test('operator-registered Grok client enforces read-only scopes, exact callback, consent and PKCE', async t => {
  const { grokClientSql, GROK_CLIENT_ID, GROK_REDIRECT_URI, GROK_SCOPES } = await import('../../../tools/lib/grok-oauth-client.mjs');
  const f = await fixture(t, { MCP_RESOURCE_URL: 'https://thumble.io/mcp' });
  f.db.exec(grokClientSql());
  await ensureIdentityClients(f.env);
  const row = f.db.prepare('SELECT * FROM oauthClient WHERE clientId=?').get(GROK_CLIENT_ID);
  assert.equal(row.clientSecret, null); assert.equal(row.requirePKCE, 1); assert.equal(Boolean(row.skipConsent), false);
  const args = { redirect_uri: GROK_REDIRECT_URI, scope: GROK_SCOPES.join(' '), resource: 'https://thumble.io/mcp' };
  for (const extra of [{ scope: 'openid profiles:write' }, { scope: 'openid pairing:read' }, { redirect_uri: 'https://grok.com.attacker.example/connectors-oauth-exchange-code/' }]) {
    const { result } = await f.authorize(GROK_CLIENT_ID, { ...args, ...extra });
    assert.ok(result.status >= 400 || new URL(result.headers.get('location'), f.env.BETTER_AUTH_URL).searchParams.has('error'));
  }
  const { result, verifier } = await f.authorize(GROK_CLIENT_ID, args);
  assert.equal(result.status, 302);
  const signedQuery = new URL(result.headers.get('location'), f.env.BETTER_AUTH_URL).search.slice(1);
  const consent = await f.auth.handler(f.request('/api/auth/oauth2/consent', { method: 'POST', body: { accept: true, oauth_query: signedQuery } }));
  assert.equal(consent.status, 200);
  const body = { grant_type: 'authorization_code', client_id: GROK_CLIENT_ID, redirect_uri: GROK_REDIRECT_URI, code: new URL((await consent.json()).url).searchParams.get('code'), resource: 'https://thumble.io/mcp' };
  const missingVerifier = await f.auth.handler(f.request('/api/auth/oauth2/token', { method: 'POST', form: true, body, authenticated: false, origin: false }));
  assert.ok(missingVerifier.status >= 400);
  const exchanged = await f.auth.handler(f.request('/api/auth/oauth2/token', { method: 'POST', form: true, body: { ...body, code_verifier: verifier }, authenticated: false, origin: false }));
  assert.equal(exchanged.status, 200);
  const tokens = await exchanged.json(); assert.ok(tokens.refresh_token);
  const claims = decodeJwt(tokens.access_token);
  assert.ok([claims.aud].flat().includes('https://thumble.io/mcp'));
  assert.deepEqual(claims.scope.split(' ').sort(), [...GROK_SCOPES].sort());
});

test('auth domain migration preserves cached clients, refresh tokens, sessions and account identity', async t => {
  const { default: worker } = await import('../src/worker.js');
  const { identityEnvironment } = await import('../src/identity.js');
  const oldOrigin = 'https://thumble-cloud-pilot.costream.workers.dev', origin = 'https://thumble.io';
  const f = await fixture(t, { BETTER_AUTH_URL: oldOrigin, MCP_RESOURCE_URL: `${origin}/mcp` });
  const phone = await f.exchange(), agent = await f.exchange('thumble-chatgpt');
  const pending = await f.authorize(); // Authorization started before deployment.
  const oldPrincipal = await authenticateAccount(new Request(`${oldOrigin}/v1/me`, { headers: { authorization: `Bearer ${phone.tokens.access_token}` } }), f.env);
  const env = { ...f.env, BETTER_AUTH_URL: origin, LEGACY_AUTH_URL: oldOrigin, ACCOUNT_ID_ISSUER: `${oldOrigin}/api/auth` };
  await ensureIdentityClients(env);
  const legacy = identityEnvironment(new Request(oldOrigin), env);
  assert.equal(identityEnvironment(new Request(oldOrigin), env), legacy);
  assert.equal(identityEnvironment(new Request('https://attacker.example'), env), env);
  for (const [host, issuer] of [[origin, `${origin}/api/auth`], [oldOrigin, `${oldOrigin}/api/auth`]]) {
    const discovery = await worker.fetch(new Request(`${host}/.well-known/oauth-authorization-server/api/auth`), env);
    assert.equal(discovery.status, 200);
    const metadata = await discovery.json();
    assert.equal(metadata.issuer, issuer); assert.equal(metadata.token_endpoint, `${issuer}/oauth2/token`);
    const oidc = await worker.fetch(new Request(`${host}/.well-known/openid-configuration/api/auth`), env);
    assert.equal(oidc.status, 200); assert.equal((await oidc.json()).issuer, issuer);
    assert.equal(getPublicConfig(new Request(`${host}/v1/config`), identityEnvironment(new Request(host), env)).auth.issuer, issuer);
    for (const tokens of [phone.tokens, agent.tokens]) {
      const principal = await authenticateAccount(new Request(`${host}/v1/me`, { headers: { authorization: `Bearer ${tokens.access_token}` } }), identityEnvironment(new Request(host), env));
      assert.equal(principal.accountId, oldPrincipal.accountId);
    }
  }
  // Browser sessions stay valid on the old domain; no cross-domain cookie forwarding.
  const existingSession = await worker.fetch(f.request('/api/auth/get-session'), env);
  assert.equal((await existingSession.json()).user.id, f.user.id);
  for (const [clientId, tokens] of [['thumble-mobile', phone.tokens], ['thumble-chatgpt', agent.tokens]]) {
    const refreshed = await worker.fetch(f.request('/api/auth/oauth2/token', { method: 'POST', form: true, authenticated: false, origin: false, body: { grant_type: 'refresh_token', client_id: clientId, refresh_token: tokens.refresh_token, resource: `${origin}/mcp`, ...(clientId === 'thumble-chatgpt' ? { client_secret: f.env.CHATGPT_CLIENT_SECRET } : {}) } }), env);
    assert.equal(refreshed.status, 200);
    const next = await refreshed.json(); assert.ok(next.refresh_token);
    assert.equal(decodeJwt(next.access_token).iss, `${oldOrigin}/api/auth`);
    assert.equal(decodeJwt(next.id_token).iss, `${oldOrigin}/api/auth`);
    assert.equal((await authenticateAccount(new Request(`${origin}/mcp`, { headers: { authorization: `Bearer ${next.access_token}` } }), env)).accountId, oldPrincipal.accountId);
  }
  // Complete an in-flight old authorization after migration.
  const query = new URL(pending.result.headers.get('location'), oldOrigin).search.slice(1);
  const accepted = await worker.fetch(f.request('/api/auth/oauth2/consent', { method: 'POST', body: { accept: true, oauth_query: query } }), env);
  assert.equal(accepted.status, 200);
  const callback = new URL((await accepted.json()).url); assert.equal(callback.searchParams.get('iss'), `${oldOrigin}/api/auth`);
  const exchanged = await worker.fetch(f.request('/api/auth/oauth2/token', { method: 'POST', form: true, authenticated: false, origin: false, body: { grant_type: 'authorization_code', client_id: 'thumble-mobile', code: callback.searchParams.get('code'), code_verifier: pending.verifier, redirect_uri: pending.redirectUri, resource: `${oldOrigin}/mcp` } }), env);
  assert.equal(exchanged.status, 200);
  // Fresh canonical authorization issues canonical tokens for the SAME existing account.
  const canonicalRequest = request => new Request(request.url.replace(oldOrigin, origin), { method: request.method, headers: new Headers([...request.headers].map(([key, value]) => [key, key === 'origin' ? origin : value])), ...(request.method === 'POST' ? { body: request.body, duplex: 'half' } : {}) });
  const canonical = await worker.fetch(canonicalRequest(f.request(`/api/auth/oauth2/authorize?${new URLSearchParams({ response_type: 'code', client_id: 'thumble-mobile', redirect_uri: MOBILE_REDIRECT_URI, scope: MOBILE_SCOPES.join(' '), resource: `${origin}/mcp`, state: 'canonical-state', code_challenge: Buffer.from(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(pending.verifier))).toString('base64url'), code_challenge_method: 'S256', prompt: 'consent' })}`)), env);
  assert.equal(canonical.status, 302);
  const canonicalConsent = new URL(canonical.headers.get('location'), origin);
  assert.equal(canonicalConsent.origin, origin);
  const consent = await worker.fetch(canonicalRequest(f.request('/api/auth/oauth2/consent', { method: 'POST', body: { accept: true, oauth_query: canonicalConsent.search.slice(1) } })), env);
  assert.equal(consent.status, 200);
  const redirect = new URL((await consent.json()).url); assert.equal(redirect.searchParams.get('iss'), `${origin}/api/auth`);
  const result = await worker.fetch(canonicalRequest(f.request('/api/auth/oauth2/token', { method: 'POST', form: true, authenticated: false, origin: false, body: { grant_type: 'authorization_code', client_id: 'thumble-mobile', redirect_uri: MOBILE_REDIRECT_URI, code: redirect.searchParams.get('code'), code_verifier: pending.verifier, resource: `${origin}/mcp` } })), env);
  assert.equal(result.status, 200);
  const tokens = await result.json(); assert.equal(decodeJwt(tokens.access_token).iss, `${origin}/api/auth`);
  assert.equal((await authenticateAccount(new Request(`${origin}/v1/me`, { headers: { authorization: `Bearer ${tokens.access_token}` } }), env)).accountId, oldPrincipal.accountId);
  const accountPage = await worker.fetch(canonicalRequest(f.request(`/account?accountId=${oldPrincipal.accountId}`)), env);
  assert.equal(accountPage.status, 200); assert.match(await accountPage.text(), /Delete your Thumble account/);
  // Deletion must use the stable namespace and invalidate tokens from BOTH issuers.
  const deletionRequest = canonicalRequest(f.request('/api/auth/delete-user', { method: 'POST', body: {} }));
  deletionRequest.headers.set('x-thumble-account-id', oldPrincipal.accountId);
  const deletion = await worker.fetch(deletionRequest, env); assert.equal(deletion.status, 200);
  assert.equal(f.db.prepare('SELECT account_id FROM cloud_deleted_accounts').get().account_id, oldPrincipal.accountId);
  for (const accessToken of [phone.tokens.access_token, tokens.access_token]) await assert.rejects(authenticateAccount(new Request(`${origin}/v1/me`, { headers: { authorization: `Bearer ${accessToken}` } }), env), error => error.code === 'account_deleted');
});

test('Glama registration restricts callbacks, resources, scopes and sample account; PKCE/consent/refresh remain required', async t => {
  const f = await fixture(t, { GLAMA_MONITOR_EMAIL: 'owner@example.test' });
  const register = body => handleIdentity(f.request('/api/auth/oauth2/register', { method: 'POST', body, authenticated: false, origin: false }), f.env);
  for (const redirect of ['https://attacker.example/callback', 'https://glama.ai.attacker.example/callback', 'http://glama.ai/callback', 'https://glama.ai@attacker.example/callback', 'https://glama.ai/callback?next=https://evil.example', 'https://glama.ai:8443/callback', 'https://glama.ai/callback#fragment']) {
    assert.equal((await register({ redirect_uris: [redirect], token_endpoint_auth_method: 'none' })).status, 400);
  }
  const redirectUri = 'https://glama.ai/api/app/mcp/oauth/callback';
  const response = await register({ redirect_uris: [redirectUri, 'http://localhost:6749/callback'], token_endpoint_auth_method: 'none', scope: 'profiles:write pairing:manage devices:manage' });
  assert.equal(response.status, 201, await response.clone().text());
  const client = await response.json();
  assert.match(client.client_id, /^thumble-glama-/);
  assert.deepEqual(client.redirect_uris, [redirectUri]);
  assert.deepEqual(client.scope.split(' ').sort(), ['offline_access', 'profiles:read', 'devices:read', 'deliveries:read'].sort());
  const row = f.db.prepare('SELECT * FROM oauthClient WHERE clientId = ?').get(client.client_id);
  assert.equal(Boolean(row.skipConsent), false);
  const verifier = 'b'.repeat(64), challenge = Buffer.from(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier))).toString('base64url');
  const params = new URLSearchParams({ response_type: 'code', client_id: client.client_id, redirect_uri: redirectUri, scope: 'profiles:read profiles:write devices:read deliveries:read deliveries:write pairing:read', resource: `${f.env.BETTER_AUTH_URL}/mcp`, state: 'glama-test', code_challenge: challenge, code_challenge_method: 'S256' });
  const missingPkce = new URLSearchParams(params); missingPkce.delete('code_challenge'); missingPkce.delete('code_challenge_method');
  const noPkce = await handleIdentity(f.request(`/api/auth/oauth2/authorize?${missingPkce}`), f.env);
  assert(new URL(noPkce.headers.get('location'), f.env.BETTER_AUTH_URL).searchParams.has('error'));
  const authorization = await handleIdentity(f.request(`/api/auth/oauth2/authorize?${params}`), f.env);
  assert.equal(authorization.status, 302, await authorization.clone().text());
  const signedQuery = new URL(authorization.headers.get('location'), f.env.BETTER_AUTH_URL).search.slice(1);
  assert.equal(new URLSearchParams(signedQuery).get('scope').includes('write'), false);
  const consent = await handleIdentity(f.request('/api/auth/oauth2/consent', { method: 'POST', body: { accept: true, oauth_query: signedQuery } }), f.env);
  assert.equal(consent.status, 200, await consent.clone().text());
  const redirect = new URL((await consent.json()).url);
  const tokenResult = await handleIdentity(f.request('/api/auth/oauth2/token', { method: 'POST', form: true, authenticated: false, origin: false, body: { grant_type: 'authorization_code', client_id: client.client_id, redirect_uri: redirectUri, code: redirect.searchParams.get('code'), code_verifier: verifier, resource: `${f.env.BETTER_AUTH_URL}/mcp` } }), f.env);
  assert.equal(tokenResult.status, 200, await tokenResult.clone().text());
  const tokens = await tokenResult.json();
  assert.ok(tokens.refresh_token);
  const claims = decodeJwt(tokens.access_token);
  assert.equal(claims.client_id, client.client_id);
  assert(claims.scope.split(' ').every(scope => ['offline_access', 'profiles:read', 'devices:read', 'deliveries:read'].includes(scope)));
  const resourceRequest = () => new Request(`${f.env.BETTER_AUTH_URL}/mcp`, { headers: { authorization: `Bearer ${tokens.access_token}` } });
  assert.equal((await authenticateAccount(resourceRequest(), f.env)).kind, 'account');
  f.env.GLAMA_MONITOR_EMAIL = 'another@example.test';
  await assert.rejects(authenticateAccount(resourceRequest(), f.env), error => error.code === 'forbidden');
  f.env.GLAMA_MONITOR_EMAIL = 'owner@example.test';
  const refresh = await handleIdentity(f.request('/api/auth/oauth2/token', { method: 'POST', form: true, authenticated: false, origin: false, body: { grant_type: 'refresh_token', client_id: client.client_id, refresh_token: tokens.refresh_token, resource: `${f.env.BETTER_AUTH_URL}/mcp` } }), f.env);
  assert.equal(refresh.status, 200, await refresh.clone().text());
  assert.equal(decodeJwt((await refresh.json()).access_token).scope.includes('write'), false);
});

test('operator-registered Gemini CLI client enforces read-only scopes, exact callback, consent and PKCE', async t => {
  const { geminiClientSql, GEMINI_CLIENT_ID, GEMINI_REDIRECT_URI, GEMINI_SCOPES } = await import('../../../tools/lib/gemini-oauth-client.mjs');
  const f = await fixture(t, { MCP_RESOURCE_URL: 'https://thumble.io/mcp' });
  f.db.exec(geminiClientSql());
  await ensureIdentityClients(f.env);
  const row = f.db.prepare('SELECT * FROM oauthClient WHERE clientId=?').get(GEMINI_CLIENT_ID);
  assert.equal(row.clientSecret, null); assert.equal(row.requirePKCE, 1); assert.equal(Boolean(row.skipConsent), false);
  const args = { redirect_uri: GEMINI_REDIRECT_URI, scope: GEMINI_SCOPES.join(' '), resource: 'https://thumble.io/mcp' };
  for (const extra of [{ scope: 'profiles:write' }, { scope: 'pairing:read' }, { redirect_uri: 'http://localhost:7777/wrong-path' }, { redirect_uri: 'http://attacker.example:7777/oauth/callback' }, { resource: 'https://attacker.example/mcp' }]) {
    const { result } = await f.authorize(GEMINI_CLIENT_ID, { ...args, ...extra });
    assert.ok(result.status >= 400 || new URL(result.headers.get('location'), f.env.BETTER_AUTH_URL).searchParams.has('error'), JSON.stringify(extra));
  }
  const { result, verifier } = await f.authorize(GEMINI_CLIENT_ID, args);
  assert.equal(result.status, 302);
  const signedQuery = new URL(result.headers.get('location'), f.env.BETTER_AUTH_URL).search.slice(1);
  const consent = await f.auth.handler(f.request('/api/auth/oauth2/consent', { method: 'POST', body: { accept: true, oauth_query: signedQuery } }));
  assert.equal(consent.status, 200);
  const body = { grant_type: 'authorization_code', client_id: GEMINI_CLIENT_ID, redirect_uri: GEMINI_REDIRECT_URI, code: new URL((await consent.json()).url).searchParams.get('code'), resource: 'https://thumble.io/mcp' };
  const missingVerifier = await f.auth.handler(f.request('/api/auth/oauth2/token', { method: 'POST', form: true, body, authenticated: false, origin: false }));
  assert.ok(missingVerifier.status >= 400);
  const exchanged = await f.auth.handler(f.request('/api/auth/oauth2/token', { method: 'POST', form: true, body: { ...body, code_verifier: verifier }, authenticated: false, origin: false }));
  assert.equal(exchanged.status, 200);
  const tokens = await exchanged.json(); assert.ok(tokens.refresh_token);
  const claims = decodeJwt(tokens.access_token);
  assert.ok([claims.aud].flat().includes('https://thumble.io/mcp'));
  assert.deepEqual(claims.scope.split(' ').sort(), [...GEMINI_SCOPES].sort());
});
