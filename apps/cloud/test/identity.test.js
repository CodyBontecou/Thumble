import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import { makeSignature } from 'better-auth/crypto';
import { decodeJwt, exportJWK, exportPKCS8, generateKeyPair, jwtVerify, SignJWT } from 'jose';
import { createIdentity, ensureIdentityClients, handleIdentity, identityConfig, identityOptions, generateAppleClientSecret, IDENTITY_SCOPES, CHATGPT_SCOPES, MOBILE_REDIRECT_URI } from '../src/identity.js';
import { authenticateAccount, getPublicConfig } from '../src/auth.js';
import { handleAuthPage } from '../src/auth-pages.js';

async function fixture(t, overrides = {}) {
  const db = new DatabaseSync(':memory:');
  db.exec('PRAGMA foreign_keys=ON');
  for (const migration of ['0001_cloud.sql', '0002_better_auth.sql', '0003_account_deletion.sql', '0004_provider_data_minimization.sql']) db.exec(readFileSync(new URL(`../migrations/${migration}`, import.meta.url), 'utf8'));
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
    const redirectUri = clientId === 'thumble-mobile' ? MOBILE_REDIRECT_URI : 'https://chatgpt.com/connector_platform_oauth_redirect';
    const params = new URLSearchParams({ response_type: 'code', client_id: clientId, redirect_uri: redirectUri, scope: (clientId === 'thumble-chatgpt' ? CHATGPT_SCOPES : IDENTITY_SCOPES).join(' '), resource: `${env.BETTER_AUTH_URL}/mcp`, state: 'test-state', code_challenge: challenge, code_challenge_method: 'S256', ...extra });
    const result = await auth.handler(request(`/api/auth/oauth2/authorize?${params}`));
    return { result, verifier, redirectUri };
  }
  async function exchange(clientId = 'thumble-mobile') {
    const { result, verifier, redirectUri } = await authorize(clientId);
    assert.equal(result.status, 302);
    const signedQuery = new URL(result.headers.get('location'), env.BETTER_AUTH_URL).search.slice(1);
    const page = await handleAuthPage(request(`/consent?${signedQuery}`), env);
    assert.equal(page.status, 200); assert.match(await page.text(), /Allow .* to connect/);
    const consent = await auth.handler(request('/api/auth/oauth2/consent', { method: 'POST', body: { accept: true, oauth_query: signedQuery } }));
    assert.equal(consent.status, 200); const redirect = new URL((await consent.json()).url);
    assert.equal(redirect.searchParams.get('state'), 'test-state'); assert.equal(redirect.searchParams.get('iss'), `${env.BETTER_AUTH_URL}/api/auth`);
    const tokenBody = { grant_type: 'authorization_code', client_id: clientId, redirect_uri: redirectUri, code: redirect.searchParams.get('code'), code_verifier: verifier, resource: `${env.BETTER_AUTH_URL}/mcp`, ...(clientId === 'thumble-chatgpt' && env.CHATGPT_CLIENT_SECRET ? { client_secret: env.CHATGPT_CLIENT_SECRET } : {}) };
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
  assert.equal(clients.length, 2); assert.ok(clients.every(c => c.requirePKCE === 1 && c.skipConsent === 0 && c.subjectType === 'public'));
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
