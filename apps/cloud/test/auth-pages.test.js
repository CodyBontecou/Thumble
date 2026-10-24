import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { runInNewContext } from 'node:vm';
import { handleAuthPage } from '../src/auth-pages.js';

const signed = 'client_id=ai-client&scope=profiles%3Aread+profiles%3Awrite&resource=https%3A%2F%2Fcloud.example%2Fmcp&signature=valid';
const config = { baseURL: 'https://cloud.example', issuer: 'https://cloud.example/api/auth', providers: ['google', 'apple'] };
const user = { id: 'account-1', email: 'player@example.com' };
function dependencies({ providers = config.providers, session = null, client = { client_name: 'My AI' }, verify = query => query === signed } = {}) {
  return {
    identityConfig: () => ({ ...config, providers }),
    createIdentity: async () => ({ $context: Promise.resolve({ secret: 'test-only-secret', sessionConfig: { freshAge: 300 } }), api: {
      getSession: async () => session,
      getOAuthClientPublic: async ({ headers, query }) => { assert.equal(headers.get('cookie'), 'session=test'); assert.equal(query.client_id, 'ai-client'); return client; },
    } }),
    verifyOAuthQueryParams: async (query, secret) => { assert.equal(secret, 'test-only-secret'); return verify(query); },
  };
}
const request = (path, query = '') => new Request(`https://cloud.example${path}${query ? `?${query}` : ''}`, { headers: { cookie: 'session=test' } });

test('login renders only configured social providers and preserves the signed OAuth query', async () => {
  const response = await handleAuthPage(request('/sign-in', signed), {}, dependencies({ providers: ['google'] }));
  const html = await response.text();
  assert.equal(response.status, 200);
  assert.match(html, /Continue with Google/);
  assert.doesNotMatch(html, /Continue with Apple/);
  assert.match(html, /oauth_query:oauthQuery/);
  assert.match(html, /client_id=ai-client/);
  assert.match(html, /credentials:'same-origin'/);
  assert.match(response.headers.get('content-security-policy'), /frame-ancestors 'none'/);
  assert.equal(response.headers.get('referrer-policy'), 'no-referrer');
  assert.equal(response.headers.get('cache-control'), 'no-store');
});

test('login fails closed with no configured provider and invalid signed requests show no buttons', async () => {
  const unavailable = await handleAuthPage(request('/sign-in'), {}, dependencies({ providers: [] }));
  assert.equal(unavailable.status, 503);
  assert.doesNotMatch(await unavailable.text(), /data-provider/);
  const invalid = await handleAuthPage(request('/sign-in', `${signed}&scope=devices%3Amanage`), {}, dependencies());
  assert.equal(invalid.status, 400);
  assert.doesNotMatch(await invalid.text(), /data-provider/);
});

test('consent requires both a valid signed flow and an authenticated session', async () => {
  const invalid = await handleAuthPage(request('/consent', 'client_id=ai-client&scope=devices%3Amanage'), {}, dependencies({ session: { user } }));
  assert.equal(invalid.status, 400);
  const missing = await handleAuthPage(request('/consent'), {}, dependencies({ session: { user } }));
  assert.equal(missing.status, 400);
  const unauthenticated = await handleAuthPage(request('/consent', signed), {}, dependencies());
  assert.equal(unauthenticated.status, 303);
  assert.equal(unauthenticated.headers.get('location'), `https://cloud.example/sign-in?${signed}`);
});

test('consent displays actual client, scopes and resource; grants only the signed request', async () => {
  const response = await handleAuthPage(request('/consent', signed), {}, dependencies({ session: { user } }));
  const html = await response.text();
  assert.match(html, /Allow My AI to connect/);
  assert.match(html, /player@example.com/);
  assert.match(html, /Read your saved controllers/);
  assert.match(html, /Create controller revisions/);
  assert.match(html, /https:\/\/cloud.example\/mcp/);
  assert.match(html, /accept:button.dataset.accept === 'true',oauth_query:oauthQuery/);
  assert.doesNotMatch(html, /scope:|scope =|devices:manage/);
  assert.match(html, /data-accept="false"/);
});

test('consent escapes all application and account text and signed script values', async () => {
  const response = await handleAuthPage(request('/consent', signed), {}, dependencies({ session: { user: { ...user, email: '<script>bad()</script>' } }, client: { client_name: '</h1><script>bad()</script>' } }));
  const html = await response.text();
  assert.doesNotMatch(html, /<script>bad\(\)<\/script>/);
  assert.match(html, /&lt;script&gt;bad\(\)&lt;\/script&gt;/);
});

test('unknown clients and identity errors never render an approval action', async () => {
  const missing = await handleAuthPage(request('/consent', signed), {}, dependencies({ session: { user }, client: null }));
  assert.equal(missing.status, 400);
  assert.doesNotMatch(await missing.text(), /data-accept/);
  const failed = await handleAuthPage(request('/sign-in'), {}, { identityConfig: () => { throw Error('super-secret-config'); } });
  assert.equal(failed.status, 503);
  assert.doesNotMatch(await failed.text(), /super-secret-config/);
});

test('view routes reject mutations; other routes are left to the worker', async () => {
  assert.equal(await handleAuthPage(request('/other'), {}), null);
  const response = await handleAuthPage(new Request('https://cloud.example/consent', { method: 'POST' }), {});
  assert.equal(response.status, 405);
});

test('real Better Auth signature verification rejects scope tampering and expiry before consent', async () => {
  const { makeSignature } = await import('better-auth/crypto');
  const params = new URLSearchParams({ client_id: 'ai-client', scope: 'profiles:read', resource: 'https://cloud.example/mcp', exp: String(Math.floor(Date.now() / 1000) + 60) });
  const sorted = new URLSearchParams([...params].sort(([a], [b]) => a.localeCompare(b)));
  params.set('sig', await makeSignature(sorted.toString(), 'test-only-secret'));
  const overrides = dependencies({ session: { user } });
  delete overrides.verifyOAuthQueryParams;
  const valid = await handleAuthPage(request('/consent', params.toString()), {}, overrides);
  assert.equal(valid.status, 200);
  params.set('scope', 'devices:manage');
  const tampered = await handleAuthPage(request('/consent', params.toString()), {}, overrides);
  assert.equal(tampered.status, 400);
  params.set('exp', '1');
  params.delete('sig');
  const expiredSorted = new URLSearchParams([...params].sort(([a], [b]) => a.localeCompare(b)));
  params.set('sig', await makeSignature(expiredSorted.toString(), 'test-only-secret'));
  const expired = await handleAuthPage(request('/consent', params.toString()), {}, overrides);
  assert.equal(expired.status, 400);
});

test('signed login flow still permits social reauthentication with an existing session', async () => {
  const response = await handleAuthPage(request('/sign-in', signed), {}, dependencies({ session: { user } }));
  const html = await response.text();
  assert.match(html, /Continue with Google/);
  assert.match(html, /oauth_query:oauthQuery/);
  const standalone = await handleAuthPage(request('/sign-in'), {}, dependencies({ session: { user } }));
  assert.match(await standalone.text(), /You’re signed in/);
});

const accountId = createHash('sha256').update(`${config.issuer}\n${user.id}`).digest('hex');
const fresh = { user, session: { createdAt: new Date() } };
test('account management preserves expected account through social login without an invented OAuth query', async () => {
  const response = await handleAuthPage(request('/account', `accountId=${accountId}`), {}, dependencies());
  const html = await response.text();
  assert.equal(response.status, 200);
  assert.match(html, /Continue with Google/);
  assert.match(html, new RegExp(`/account\\?accountId=${accountId}`));
  assert.doesNotMatch(html, /oauth_query|delete-user|delete-account/);
});

test('account deletion is unavailable for malformed or different expected account identifiers', async () => {
  for (const query of ['accountId=bad', `accountId=${accountId}&accountId=${accountId}`]) {
    const response = await handleAuthPage(request('/account', query), {}, dependencies({ session: fresh }));
    assert.equal(response.status, 400);
    assert.doesNotMatch(await response.text(), /delete-user/);
  }
  const response = await handleAuthPage(request('/account', `accountId=${'f'.repeat(64)}`), {}, dependencies({ session: fresh }));
  assert.equal(response.status, 409);
  const html = await response.text();
  assert.match(html, /This is a different account/);
  assert.doesNotMatch(html, /delete-user|delete-account/);
});

test('account deletion requires a fresh session and never treats query flags as deletion success', async () => {
  const response = await handleAuthPage(request('/account', `accountId=${accountId}&deleted=1`), {}, dependencies({ session: { user, session: { createdAt: new Date(Date.now() - 600000) } } }));
  const html = await response.text();
  assert.match(html, /Sign in again to continue/);
  assert.doesNotMatch(html, /delete-user|Your account is deleted/);
});

test('fresh own-account view gates deletion on confirmation and submits only session-bound assertion', async () => {
  const response = await handleAuthPage(request('/account', `accountId=${accountId}`), {}, dependencies({ session: fresh }));
  const html = await response.text();
  assert.match(html, /every saved revision/);
  assert.match(html, /Offline copies on other devices remain/);
  assert.match(html, /id="delete-account" disabled/);
  assert.match(html, /thumble:\/\/cloud-account\/callback/);
  const script = html.match(/<script nonce="[^"]+">([\s\S]*?)<\/script>/)[1];
  const events = {};
  const checkbox = { checked: false, addEventListener: (type, callback) => { events.confirm = callback; } };
  const remove = { disabled: true, dataset: {}, addEventListener: (type, callback) => { events.remove = callback; } };
  const error = { textContent: '' }, reauth = { hidden: true }, main = { innerHTML: '' };
  const elements = { 'confirm-delete': checkbox, 'delete-account': remove, error, reauth };
  const calls = [];
  runInNewContext(script, { URL, document: { querySelectorAll: () => [remove], getElementById: id => elements[id], querySelector: () => main }, location: { origin: config.baseURL }, fetch: async (path, options) => { calls.push({ path, ...options }); return { ok: true, json: async () => ({ success: true, message: 'User deleted' }) }; } });
  await events.remove();
  assert.equal(calls.length, 0);
  checkbox.checked = true; events.confirm();
  assert.equal(remove.disabled, false);
  await events.remove();
  assert.equal(calls.length, 1);
  assert.equal(calls[0].path, '/api/auth/delete-user');
  assert.equal(calls[0].credentials, 'same-origin');
  assert.equal(calls[0].headers['x-thumble-account-id'], accountId);
  assert.deepEqual(JSON.parse(calls[0].body), {});
  assert.match(main.innerHTML, /Your account is deleted/);
});

test('email-only login renders validated forms and submits a code with the original signed OAuth request', async () => {
  const response = await handleAuthPage(request('/sign-in', signed), {}, dependencies({ providers: ['email'] }));
  const html = await response.text();
  assert.equal(response.status, 200); assert.match(html, /autocomplete="one-time-code"/); assert.match(html, /type="email"/); assert.match(html, /inputmode="numeric"/); assert.doesNotMatch(html, /data-provider=/);
  const script = html.match(/<script nonce="[^"]+">([\s\S]*?)<\/script>/)[1];
  const listeners = {}, buttons = [{ disabled: false, dataset: {} }];
  const emailForm = { hidden: false, reportValidity: () => true, addEventListener: (type, cb) => { listeners.send = cb; } };
  const codeForm = { hidden: true, reportValidity: () => true, addEventListener: (type, cb) => { listeners.verify = cb; } };
  const email = { value: 'reviewer@example.test', focus() {} }, code = { value: '123456', focus() {} }, error = { textContent: '' };
  const elements = { 'email-form': emailForm, 'code-form': codeForm, email, code, error, 'change-email': { addEventListener: (type, cb) => { listeners.change = cb; } } };
  const calls = [], assigned = [];
  runInNewContext(script, { URL, document: { querySelectorAll: () => buttons, getElementById: id => elements[id] }, location: { origin: config.baseURL, assign: url => assigned.push(url) }, fetch: async (path, options) => { calls.push({ path, ...options }); return { ok: true, json: async () => calls.length === 1 ? { success: true } : { url: '/consent?original=signed' } }; } });
  const event = { preventDefault() {} };
  await listeners.send(event); assert.equal(emailForm.hidden, true); assert.equal(codeForm.hidden, false); assert.equal(email.readOnly, true); assert.equal(assigned.length, 0);
  await listeners.verify(event); assert.equal(calls[1].path, '/api/auth/sign-in/email-otp'); assert.deepEqual(JSON.parse(calls[1].body), { email: 'reviewer@example.test', otp: '123456', oauth_query: signed }); assert.equal(calls[1].credentials, 'same-origin'); assert.equal(assigned[0], 'https://cloud.example/consent?original=signed');
  listeners.change(); assert.equal(emailForm.hidden, false); assert.equal(codeForm.hidden, true); assert.equal(code.value, '');
  const account = await handleAuthPage(request('/account'), {}, dependencies({ providers: ['email'] })); assert.match(await account.text(), /id="email-form"/);
  const invalid = await handleAuthPage(request('/sign-in', `${signed}&bad=true`), {}, dependencies({ providers: ['email'] })); assert.equal(invalid.status, 400); assert.doesNotMatch(await invalid.text(), /id="email-form"/);
});
