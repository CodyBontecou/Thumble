import test from 'node:test';
import assert from 'node:assert/strict';
import { xboxProfile } from '@tapping/controller';
import { handleApi } from '../src/api.js';
import { createTestDb, createTestAuthority, apiRequest } from './helpers.js';

async function fixture(t) {
  const authority = await createTestAuthority(), db = createTestDb(); t.after(() => db.close());
  const env = { ...authority.env, DB: db }, token = await authority.token();
  async function call(path, body, access = token, method = body ? 'POST' : 'GET') {
    const response = await handleApi(apiRequest(path, access, { method, body }), env);
    return { status: response.status, value: await response.json(), headers: response.headers };
  }
  return { ...authority, tokenFor: authority.token, token, db, env, call };
}
const phone = { name: 'My phone', platform: 'ios', viewport: { width: 844, height: 390 } };
async function savedAndPhone(f) {
  const registered = await f.call('/devices', phone); assert.equal(registered.status, 201);
  f.deviceId = registered.value.device.id;
  const saved = await f.call('/profiles', { profile: xboxProfile, expectedRevision: 0, deviceId: f.deviceId }); assert.equal(saved.status, 201);
  return { saved: saved.value, ...registered.value };
}
const target = (device, revision = 1, requestId = 'first') => ({ deviceId: device.id, profileId: xboxProfile.id, profileRevision: revision, requestId });
const receipt = state => ({ profileId: xboxProfile.id, profileRevision: 1, state });

test('layout gates use the owned target canvas before saving and delivering; reads preserve legacy layouts', async t => {
  const f = await fixture(t), { device, deviceToken } = await savedAndPhone(f);
  const bad = structuredClone(xboxProfile); bad.id = 'small-generated'; bad.controls.find(control => control.id === 'b').frame.width = 0.03;
  const validation = await f.call('/profiles/validate', { profile: bad, deviceId: device.id });
  assert.equal(validation.value.valid, false);
  assert.ok(validation.value.errors.some(error => error.controls.includes('b')));
  assert.equal((await f.call('/profiles', { profile: bad, expectedRevision: 0, deviceId: device.id })).value.error.code, 'invalid_layout');
  assert.equal((await f.call('/profiles', { profile: xboxProfile, expectedRevision: 0 })).status, 400);
  const stranger = await f.tokenFor({ sub: 'other' });
  assert.equal((await f.call('/profiles/validate', { profile: xboxProfile, deviceId: device.id }, stranger)).status, 404);
  assert.equal(f.db.sqlite.prepare('SELECT COUNT(*) AS n FROM profile_revisions').get().n, 1);
  // Resize between save and delivery: the already-saved revision stays
  // readable, but it cannot be delivered to an unsuitable canvas.
  assert.equal((await f.call(`/devices/${device.id}/viewport`, { width: 340, height: 240 }, deviceToken)).status, 200);
  assert.equal((await f.call('/deliveries', target(device))).value.error.code, 'invalid_layout');
  assert.equal((await f.call(`/profiles/${xboxProfile.id}`)).status, 200);
  assert.equal((await f.call(`/devices/${device.id}/viewport`, { width: 740, height: 380 }, f.token)).status, 401);
  assert.equal((await f.call(`/devices/${device.id}/viewport`, { width: 740, height: 380 }, deviceToken)).status, 200);
  assert.equal((await f.call('/deliveries', target(device))).status, 201);
});

test('fails closed and verifies JWT signatures, expiry, issuer, audience, scopes and tenant', async t => {
  const f = await fixture(t);
  assert.equal((await handleApi(apiRequest('/config'), {})).status, 503);
  assert.equal((await f.call('/devices', undefined, undefined)).status, 200);
  assert.equal((await f.call('/devices', undefined, '')).status, 401);
  for (const options of [{ issuer: 'https://wrong.test/' }, { audience: 'wrong' }, { expires: '-1s' }]) assert.equal((await f.call('/devices', undefined, await f.tokenFor(options))).status, 401);
  const rogue = await createTestAuthority(); assert.equal((await f.call('/devices', undefined, await rogue.token())).status, 401);
  assert.equal((await f.call('/devices', undefined, await f.tokenFor({ scope: 'profiles:read' }))).status, 403);
  const { device, deviceToken } = await savedAndPhone(f);
  assert.equal((await f.call('/profiles', undefined, deviceToken)).status, 401);
  assert.equal((await f.call(`/devices/${device.id}/deliveries`, undefined, f.token)).status, 401);
  const stranger = await f.tokenFor({ sub: 'another-account' });
  assert.equal((await f.call(`/profiles/${xboxProfile.id}`, undefined, stranger)).status, 404);
  assert.equal((await f.call(`/devices/${device.id}`, undefined, stranger, 'DELETE')).status, 404);
  assert.equal((await f.call('/devices')).headers.get('Cache-Control'), 'no-store');
  assert.equal(f.db.sqlite.prepare('SELECT token_hash FROM devices').get().token_hash.includes(deviceToken), false);
});

test('immutable revisions use atomic compare-and-swap with concurrent writers', async t => {
  const f = await fixture(t); await savedAndPhone(f);
  const results = await Promise.all(['First edit', 'Second edit'].map(name => f.call('/profiles', { profile: { ...xboxProfile, name }, expectedRevision: 1, deviceId: f.deviceId })));
  assert.deepEqual(results.map(r => r.status).sort(), [201, 409]);
  assert.deepEqual((await f.call(`/profiles/${xboxProfile.id}/revisions/1`)).value.profile, xboxProfile);
  assert.equal((await f.call(`/profiles/${xboxProfile.id}`)).value.revision, 2);
  assert.equal((await f.call('/profiles')).value.profiles.length, 1);
  assert.equal((await f.call('/profiles', { profile: { bad: true }, expectedRevision: 2 })).status, 400);
  assert.equal((await f.call('/profiles', { profile: xboxProfile, deviceId: f.deviceId, expectedRevision: Number.MAX_SAFE_INTEGER })).status, 400);
});

test('delivery idempotency, explicit revisions, supersession and exact render receipts', async t => {
  const f = await fixture(t), { device, deviceToken } = await savedAndPhone(f);
  const results = await Promise.all([f.call('/deliveries', target(device)), f.call('/deliveries', target(device))]);
  assert.equal(results[0].status, 201); assert.equal(results[1].status, 201);
  const id = results[0].value.delivery.id; assert.equal(id, results[1].value.delivery.id);
  assert.equal((await f.call('/deliveries', target(device, 2))).status, 409);
  assert.equal((await f.call('/deliveries', target(device, 999, 'missing'))).status, 404);
  const pending = await f.call(`/devices/${device.id}/deliveries`, undefined, deviceToken);
  assert.equal(pending.value.deliveries[0].profile.id, xboxProfile.id);
  const ack = `/devices/${device.id}/deliveries/${id}/ack`;
  assert.equal((await f.call(ack, { ...receipt('received'), profileRevision: 2 }, deviceToken)).status, 409);
  assert.equal((await f.call(ack, receipt('rendered'), deviceToken)).status, 409);
  const repeats = await Promise.all([f.call(ack, receipt('received'), deviceToken), f.call(ack, receipt('received'), deviceToken)]);
  assert.deepEqual(repeats.map(r => r.status), [200, 200]);
  assert.equal((await f.call(ack, receipt('rendered'), deviceToken)).value.delivery.state, 'rendered');
  assert.equal((await f.call(ack, receipt('received'), deviceToken)).status, 409);
  assert.equal((await f.call(`/deliveries/${id}`)).value.delivery.state, 'rendered');
  const next = await f.call('/deliveries', target(device, 1, 'second'));
  const third = await f.call('/deliveries', target(device, 1, 'third'));
  assert.equal((await f.call(`/deliveries/${next.value.delivery.id}`)).value.delivery.state, 'superseded');
  assert.equal((await f.call(`/devices/${device.id}/deliveries/${next.value.delivery.id}/ack`, receipt('received'), deviceToken)).status, 409);
  assert.equal((await f.call(`/devices/${device.id}/deliveries`, undefined, deviceToken)).value.deliveries[0].delivery.id, third.value.delivery.id);
});

test('device receipts are isolated, revoked/expired credentials cannot poll or acknowledge', async t => {
  const f = await fixture(t), { device, deviceToken } = await savedAndPhone(f);
  const second = (await f.call('/devices', phone)).value;
  const delivery = (await f.call('/deliveries', target(device))).value.delivery;
  const path = `/devices/${device.id}/deliveries/${delivery.id}/ack`;
  assert.equal((await f.call(path, receipt('received'), second.deviceToken)).status, 401);
  f.db.sqlite.prepare('UPDATE devices SET token_expires_at = ? WHERE id = ?').run('2000-01-01T00:00:00.000Z', device.id);
  assert.equal((await f.call(path, receipt('received'), deviceToken)).status, 401);
  assert.equal((await f.call('/deliveries', target(device, 1, 'expired-device'))).status, 404);
  assert.equal((await f.call('/devices')).value.devices.some(value => value.id === device.id), false);
  assert.equal((await f.call(`/devices/${second.device.id}`, undefined, f.token, 'DELETE')).status, 200);
  assert.equal((await f.call(`/devices/${second.device.id}/deliveries`, undefined, second.deviceToken)).status, 401);
});

test('bounded JSON bodies and public config contain no credentials', async t => {
  const f = await fixture(t);
  const config = await f.call('/config'); assert.equal(config.status, 200); assert.equal(config.value.mcpUrl, 'https://cloud.example.test/mcp');
  assert.equal(JSON.stringify(config.value).includes('keys'), false);
  assert.equal((await f.call('/profiles', { payload: 'a'.repeat(262145) })).status, 413);
});
