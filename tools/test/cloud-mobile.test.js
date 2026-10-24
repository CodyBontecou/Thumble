import test from 'node:test';
import assert from 'node:assert/strict';
import { xboxProfile } from '@tapping/controller';
import { CloudController } from '../../apps/mobile/src/cloud/core.js';

const clone = value => structuredClone(value);
const profile = { ...clone(xboxProfile), id: 'cloud-first', name: 'Cloud first controller' };
const session = { service: 'https://cloud.example', accountId: 'alice', accessToken: 'account-secret', deviceToken: 'device-secret', device: { id: 'phone-1', name: 'Phone' } };
const delivery = { id: 'delivery-1', deviceId: 'phone-1', profileId: profile.id, profileRevision: 3, state: 'queued' };
function fixture() {
  let saved = { session: clone(session), cache: null };
  let item = { delivery: clone(delivery), profile: clone(profile) };
  const requests = [];
  const client = new CloudController({ storage: { load: async () => clone(saved), save: async value => { saved = clone(value); } }, fetch: async (url, options) => {
    const path = new URL(url).pathname;
    const body = options.body ? JSON.parse(options.body) : undefined;
    requests.push({ path, ...options, body });
    if (path.endsWith('/ack')) return Response.json({ delivery: { ...item.delivery, state: body.state } });
    if (path.endsWith('/deliveries')) return Response.json({ deliveries: item ? [item] : [] });
    if (path === '/v1/profiles') return Response.json({ profiles: [{ id: profile.id, name: profile.name, revision: 3 }] });
    if (path.includes('/revisions/')) return Response.json({ profile, revision: 3 });
    if (options.method === 'DELETE') return Response.json({ revoked: true });
    throw Error(`Unexpected route ${path}`);
  } });
  return { client, requests, saved: () => saved, item: value => { item = value; } };
}

test('canvas reporting serializes resize changes and preserves landscape measurements across portrait settings', async () => {
  const { client } = fixture(); await client.load();
  const calls = []; let release;
  client.request = async (url, options) => {
    calls.push({ path: new URL(url).pathname, body: JSON.parse(options.body), token: options.headers.Authorization });
    if (calls.length === 1) await new Promise(resolve => { release = resolve; });
    return Response.json({ viewport: JSON.parse(options.body) });
  };
  client.setViewport({ width: 740, height: 380 });
  const first = client.syncViewport();
  client.setViewport({ width: 780, height: 380 });
  release(); await first;
  assert.deepEqual(calls.map(call => call.body.width), [740, 780]);
  assert.ok(calls.every(call => call.token === `Bearer ${session.deviceToken}`));
  client.setViewport({ width: 380, height: 780 }); await client.syncViewport();
  assert.equal(client.viewport.width, 780); assert.equal(calls.length, 2);
  client.setEnvironment({ foreground: false }); client.setViewport({ width: 800, height: 380 }); await client.syncViewport();
  assert.equal(calls.length, 2);
});

test('late viewport replies after logout cannot overwrite a new account canvas marker', async () => {
  const { client } = fixture(); await client.load();
  let release;
  client.request = async (url, options) => {
    if (url.endsWith('/viewport')) await new Promise(resolve => { release = resolve; });
    return Response.json({ revoked: true });
  };
  client.setViewport({ width: 740, height: 380 }); const syncing = client.syncViewport();
  await client.logout(); release(); await syncing;
  assert.equal(client.viewportKey, ''); assert.equal(client.snapshot().session, null);
});

test('cloud delivery uses device credential and acknowledges rendered only from exact committed selection', async () => {
  const { client, requests, saved } = fixture();
  await client.load();
  await client.poll();
  assert.equal(client.snapshot().pending.id, delivery.id);
  assert.deepEqual(requests.filter(request => request.body?.state).map(request => request.body.state), ['received']);
  assert.equal(saved().cache, null);
  const selected = client.snapshot().selected;
  await client.rendered({ ...selected });
  assert.equal(requests.length, 2, 'a copy or stale selection cannot acknowledge');
  await client.rendered(selected);
  const receipt = requests.find(request => request.body?.state === 'rendered');
  assert.equal(receipt.headers.Authorization, 'Bearer device-secret');
  assert.deepEqual(receipt.body, { profileId: profile.id, profileRevision: 3, state: 'rendered' });
  assert.equal(saved().cache.revision, 3);
  assert.equal(client.snapshot().pending, null);
  await client.rendered(client.snapshot().selected);
  assert.equal(requests.filter(request => request.body?.state === 'rendered').length, 1);
});

test('LAN-connected and background phone never acknowledge cloud render; foreground polling only', async () => {
  const { client, requests } = fixture();
  await client.load();
  client.setEnvironment({ lanOffline: false });
  await client.poll();
  await client.rendered(client.snapshot().selected);
  assert.equal(requests.filter(request => request.body?.state === 'rendered').length, 0);
  client.setEnvironment({ lanOffline: true, foreground: false });
  await client.poll();
  await client.rendered(client.snapshot().selected);
  assert.equal(requests.length, 2);
  client.setEnvironment({ foreground: true });
  await client.rendered(client.snapshot().selected);
  assert.equal(requests.at(-1).body.state, 'rendered');
});

test('new delivery supersedes old local selection; only new exact revision can acknowledge', async () => {
  const { client, requests, item } = fixture();
  await client.load(); await client.poll();
  const old = client.snapshot().selected;
  item({ profile, delivery: { ...delivery, id: 'delivery-2', profileRevision: 4 } });
  await client.poll();
  await client.rendered(old);
  assert.equal(requests.filter(request => request.body?.state === 'rendered').length, 0);
  await client.rendered(client.snapshot().selected);
  assert.equal(requests.at(-1).body.profileRevision, 4);
});

test('invalid delivered profile cannot select or acknowledge received', async () => {
  const { client, requests, item } = fixture();
  await client.load();
  item({ delivery, profile: { id: profile.id, controls: [] } });
  await client.poll();
  assert.equal(client.snapshot().selected, null);
  assert.equal(requests.length, 1);
  assert.ok(client.snapshot().error);
});

test('logout cancels a delayed download, erases cache and attempts device revocation', async () => {
  const { client, requests, saved } = fixture();
  await client.load();
  const original = client.request;
  let release;
  let started;
  const downloading = new Promise(resolve => { started = resolve; });
  client.request = async (url, options) => {
    if (new URL(url).pathname.endsWith('/deliveries')) await new Promise(resolve => { release = resolve; started(); });
    return original(url, options);
  };
  const polling = client.poll();
  await downloading;
  await client.logout();
  release(); await polling;
  assert.equal(client.snapshot().selected, null);
  assert.equal(client.snapshot().session, null);
  assert.equal(saved(), null);
  assert.equal(requests.filter(request => request.body?.state).length, 0);
  assert.ok(requests.some(request => request.method === 'DELETE'));
});

test('cache restores securely scoped profile for offline practice and never replays old render receipts', async () => {
  const fixture1 = fixture();
  await fixture1.client.load(); await fixture1.client.poll(); await fixture1.client.rendered(fixture1.client.snapshot().selected);
  const client = new CloudController({ storage: { load: async () => fixture1.saved(), save: async () => {} }, fetch: async () => { throw Error('Offline'); } });
  await client.load();
  assert.equal(client.snapshot().selected.profile.id, profile.id);
  assert.equal(client.snapshot().selected.cached, true);
  await client.rendered(client.snapshot().selected);
  assert.equal(client.snapshot().error, '');
});

test('superseded delivery disappears and resets pending preview to last acknowledged cache', async () => {
  const { client, item } = fixture();
  await client.load(); await client.poll();
  item(null); await client.poll();
  assert.equal(client.snapshot().selected, null);
  assert.equal(client.snapshot().pending, null);
});

test('render receipt failure is retried after a fresh pending poll', async () => {
  const { client } = fixture();
  await client.load(); await client.poll();
  const original = client.request;
  let fail = true;
  client.request = async (url, options) => {
    if (JSON.parse(options.body || '{}').state === 'rendered' && fail) throw Error('Offline');
    return original(url, options);
  };
  await client.rendered(client.snapshot().selected);
  assert.equal(client.snapshot().error, 'Offline');
  fail = false;
  await client.poll();
  assert.equal(client.snapshot().renderAttempt, 1);
  await client.rendered(client.snapshot().selected);
  assert.equal(client.snapshot().pending, null);
});

test('logout serialization prevents in-flight persistence from restoring credentials', async () => {
  let saved = { session: clone(session), cache: null };
  let release, started;
  const didStart = new Promise(resolve => { started = resolve; });
  let block = true;
  const client = new CloudController({ storage: { load: async () => saved, save: async value => { if (value && block) await new Promise(resolve => { release = resolve; started(); }); saved = value; } }, fetch: async () => Response.json({ revoked: true }) });
  await client.load();
  const writing = client.persist();
  await didStart;
  const loggingOut = client.logout();
  block = false; release();
  await writing; await loggingOut;
  assert.equal(saved, null);
});

test('lost render response reconciles idempotently after server removes committed delivery from queue', async () => {
  const { client, saved, item } = fixture();
  await client.load(); await client.poll();
  const original = client.request;
  const selected = client.snapshot().selected;
  let committed = false;
  client.request = async (url, options) => {
    if (JSON.parse(options.body || '{}').state === 'rendered') {
      if (committed) return Response.json({ delivery: { ...delivery, state: 'rendered' } });
      committed = true;
      item(null);
      throw Error('Response lost after server commit');
    }
    return original(url, options);
  };
  await client.rendered(selected);
  assert.equal(saved().cache, null);
  await client.poll();
  assert.equal(client.snapshot().selected.profile.id, selected.profile.id);
  assert.equal(client.snapshot().selected.cached, true);
  assert.equal(saved().cache.revision, selected.revision);
  assert.equal(client.snapshot().pending, null);
});

test('committed preview with superseded render receipt resets after empty queue reconciliation conflict', async () => {
  const { client, item } = fixture();
  await client.load(); await client.poll();
  const original = client.request;
  let superseded = false;
  client.request = async (url, options) => {
    if (JSON.parse(options.body || '{}').state === 'rendered') {
      if (superseded) return Response.json({ error: { code: 'delivery_conflict', message: 'Superseded' } }, { status: 409 });
      throw Error('Offline');
    }
    return original(url, options);
  };
  await client.rendered(client.snapshot().selected);
  superseded = true; item(null);
  await client.poll();
  assert.equal(client.snapshot().selected, null);
  assert.equal(client.snapshot().pending, null);
});

test('concurrent library and preview requests share one rotating refresh token exchange', async () => {
  const { client, saved, requests } = fixture();
  await client.load();
  client.update({ session: { ...client.snapshot().session, expiresAt: 1, refreshToken: 'rotating-first' } });
  let release, started;
  const didStart = new Promise(resolve => { started = resolve; });
  let exchanges = 0;
  client.refreshToken = async current => {
    assert.equal(current.refreshToken, 'rotating-first'); exchanges++;
    await new Promise(resolve => { release = resolve; started(); });
    return { accessToken: 'renewed-account', refreshToken: 'rotating-second', expiresAt: Date.now() + 60000 };
  };
  const library = client.refreshProfiles();
  const preview = client.preview(profile.id, 3);
  await didStart;
  assert.equal(exchanges, 1);
  release(); await Promise.all([library, preview]);
  assert.equal(exchanges, 1);
  assert.equal(saved().session.refreshToken, 'rotating-second');
  assert.equal(requests.length, 2);
  assert.ok(requests.every(request => request.headers.Authorization === 'Bearer renewed-account'));
});

test('logout shares in-flight rotating refresh for revocation without restoring stale credentials', async () => {
  const { client, saved, requests } = fixture();
  await client.load();
  client.update({ session: { ...client.snapshot().session, expiresAt: 1, refreshToken: 'rotating-first' } });
  let release, started;
  const didStart = new Promise(resolve => { started = resolve; });
  let exchanges = 0;
  client.refreshToken = async () => {
    exchanges++;
    await new Promise(resolve => { release = resolve; started(); });
    return { accessToken: 'renewed-account', refreshToken: 'rotating-second', expiresAt: Date.now() + 60000 };
  };
  const library = client.refreshProfiles();
  await didStart; await client.logout(); release(); await library;
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(exchanges, 1);
  assert.equal(saved(), null);
  assert.equal(client.snapshot().session, null);
  assert.equal(requests.length, 1);
  assert.equal(requests[0].method, 'DELETE');
  assert.equal(requests[0].headers.Authorization, 'Bearer renewed-account');
});

test('Better Auth mobile OAuth requests bind authorization, code exchange and refresh to exact MCP resource', async () => {
  const { authorizationConfig, codeExchangeConfig, refreshConfig, validateCloudConfig } = await import('../../apps/mobile/src/cloud/oauth.js');
  const service = 'https://thumble-cloud-pilot.costream.workers.dev';
  const auth = { issuer: `${service}/api/auth`, authorizationEndpoint: `${service}/api/auth/oauth2/authorize`, tokenEndpoint: `${service}/api/auth/oauth2/token`, mobileClientId: 'thumble-mobile', audience: `${service}/mcp`, scopes: ['openid', 'offline_access', 'profiles:read', 'devices:manage'] };
  assert.equal(validateCloudConfig({ apiVersion: 1, auth, mcpUrl: `${service}/mcp` }, service), auth);
  const canonical = { ...auth, audience: 'https://thumble.io/mcp' };
  assert.equal(validateCloudConfig({ apiVersion: 1, auth: canonical, mcpUrl: canonical.audience }, service), canonical);
  assert.throws(() => validateCloudConfig({ apiVersion: 1, auth: { ...auth, audience: 'http://thumble.io/mcp' }, mcpUrl: 'http://thumble.io/mcp' }, service), /resource/);
  const authorization = authorizationConfig(auth, 'thumble://cloud-auth');
  assert.equal(authorization.usePKCE, true);
  assert.equal(authorization.responseType, 'code');
  assert.deepEqual(authorization.extraParams, { resource: `${service}/mcp` });
  assert.equal(authorization.scopes.filter(scope => scope === 'offline_access').length, 1);
  const code = codeExchangeConfig(auth, 'thumble://cloud-auth', 'authorization-code', 'pkce-verifier');
  assert.deepEqual(code.extraParams, { code_verifier: 'pkce-verifier', resource: `${service}/mcp` });
  assert.throws(() => codeExchangeConfig(auth, 'thumble://cloud-auth', 'authorization-code', 'pkce-verifier', 'https://unrelated.example/auth'), /different identity provider/);
  const refresh = refreshConfig({ auth, refreshToken: 'rotating-refresh-token' });
  assert.deepEqual(refresh, { clientId: 'thumble-mobile', refreshToken: 'rotating-refresh-token', extraParams: { resource: `${service}/mcp` } });
  assert.ok(!('clientSecret' in authorization) && !('clientSecret' in code) && !('clientSecret' in refresh));
  assert.throws(() => validateCloudConfig({ apiVersion: 1, auth: { ...auth, audience: 'https://unrelated.example/mcp' }, mcpUrl: `${service}/mcp` }, service), /resource/);
  assert.throws(() => validateCloudConfig({ apiVersion: 1, auth: { ...auth, tokenEndpoint: 'http://untrusted.example/token' }, mcpUrl: `${service}/mcp` }, service), /HTTPS/);
});

test('OAuth expiry is explicit and refresh rotation retains only returned or current refresh token', async () => {
  const { tokenFields } = await import('../../apps/mobile/src/cloud/oauth.js');
  assert.deepEqual(tokenFields({ accessToken: 'access', refreshToken: 'second', expiresIn: 3600 }, { refreshToken: 'first' }, 1000), { accessToken: 'access', refreshToken: 'second', expiresAt: 3601000 });
  assert.equal(tokenFields({ accessToken: 'access', expiresIn: 300 }, { refreshToken: 'first' }).refreshToken, 'first');
  assert.throws(() => tokenFields({ accessToken: 'access' }), /invalid access token/);
  assert.throws(() => tokenFields({ accessToken: '', expiresIn: 300 }), /invalid access token/);
});

test('Better Auth native callback includes host and path and stays exact across authorize and exchange', async () => {
  const { CLOUD_REDIRECT_PATH, CLOUD_REDIRECT_URI } = await import('../../apps/mobile/src/cloud/redirect.js');
  const { authorizationConfig, codeExchangeConfig } = await import('../../apps/mobile/src/cloud/oauth.js');
  assert.equal(CLOUD_REDIRECT_PATH, 'cloud-auth/callback');
  assert.equal(CLOUD_REDIRECT_URI, 'thumble://cloud-auth/callback');
  const parsed = new URL(CLOUD_REDIRECT_URI);
  assert.equal(parsed.hostname, 'cloud-auth');
  assert.equal(parsed.pathname, '/callback');
  const auth = { mobileClientId: 'thumble-mobile', audience: 'https://thumble.io/mcp', scopes: [] };
  assert.equal(authorizationConfig(auth, CLOUD_REDIRECT_URI).redirectUri, CLOUD_REDIRECT_URI);
  assert.equal(codeExchangeConfig(auth, CLOUD_REDIRECT_URI, 'code', 'verifier').redirectUri, CLOUD_REDIRECT_URI);
});

test('confirmed account_deleted erases credentials, pending delivery and acknowledged profile cache', async () => {
  const { client, saved } = fixture();
  await client.load(); await client.poll(); await client.rendered(client.snapshot().selected);
  assert.ok(saved().cache);
  client.request = async () => Response.json({ error: { code: 'account_deleted', message: 'Account deleted' } }, { status: 401 });
  assert.equal(await client.verifyAccountDeletion(), true);
  assert.equal(client.snapshot().session, null);
  assert.equal(client.snapshot().selected, null);
  assert.equal(client.snapshot().pending, null);
  assert.deepEqual(client.snapshot().profiles, []);
  assert.equal(saved(), null);
});

test('offline, generic unauthorized and callback return do not clear account or cached profile', async () => {
  const { client, saved } = fixture();
  await client.load(); await client.poll(); await client.rendered(client.snapshot().selected);
  const original = saved();
  client.request = async () => { throw Error('Offline'); };
  await assert.rejects(client.verifyAccountDeletion(), /Offline/);
  assert.deepEqual(saved(), original);
  assert.equal(client.snapshot().session.accountId, session.accountId);
  client.request = async () => Response.json({ error: { code: 'unauthorized', message: 'Expired access token' } }, { status: 401 });
  await assert.rejects(client.verifyAccountDeletion(), /Expired access token/);
  assert.deepEqual(saved(), original);
  client.request = async () => Response.json({ accountId: session.accountId });
  assert.equal(await client.verifyAccountDeletion(), false);
  assert.deepEqual(saved(), original);
});

test('delayed deletion response for previous account cannot erase new account data', async () => {
  const { client, saved } = fixture();
  await client.load();
  let release, started;
  const didStart = new Promise(resolve => { started = resolve; });
  client.request = async () => {
    await new Promise(resolve => { release = resolve; started(); });
    return Response.json({ error: { code: 'account_deleted', message: 'Old account deleted' } }, { status: 401 });
  };
  const verifying = client.verifyAccountDeletion();
  await didStart;
  ++client.epoch;
  const newSession = { ...clone(session), accountId: 'different-account', device: { id: 'different-phone', name: 'Phone' } };
  client.update({ session: newSession });
  await client.persist();
  release();
  await assert.rejects(verifying, /Old account deleted/);
  assert.equal(client.snapshot().session.accountId, newSession.accountId);
  assert.equal(saved().session.accountId, newSession.accountId);
});

test('account management URL carries only expected account ID and return URL is a separate native callback', async () => {
  const { accountDeletionUrl, ACCOUNT_RETURN_URI } = await import('../../apps/mobile/src/cloud/account.js');
  const url = new URL(accountDeletionUrl(session));
  assert.equal(url.origin, session.service);
  assert.equal(url.pathname, '/account');
  assert.deepEqual([...url.searchParams.entries()], [['accountId', session.accountId]]);
  assert.ok(!url.href.includes(session.accessToken));
  assert.ok(!url.href.includes(session.deviceToken));
  assert.equal(ACCOUNT_RETURN_URI, 'thumble://cloud-account/callback');
});
