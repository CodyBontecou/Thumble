import test from 'node:test';
import assert from 'node:assert/strict';
import { xboxProfile } from '@tapping/controller';
import worker from '../../apps/cloud/src/worker.js';
import { createTestAuthority, createTestDb, apiRequest } from '../../apps/cloud/test/helpers.js';
import { CloudController } from '../../apps/mobile/src/cloud/core.js';

// Exercise the composed Worker, signed access tokens, real SQL, SDK transport,
// and the same delivery state machine used by the phone. This is not UI proof.
test('signed MCP save → exact delivery → offline phone receipt → revocation', async t => {
  const authority = await createTestAuthority();
  const db = createTestDb();
  const inflight = new Set();
  t.after(async () => { await Promise.allSettled([...inflight]); db.close(); });
  const env = { ...authority.env, DB: db };
  const token = await authority.token();
  const request = (input, options) => {
    const promise = worker.fetch(input instanceof Request ? input : new Request(input, options), env);
    inflight.add(promise); void promise.finally(() => inflight.delete(promise));
    return promise;
  };
  let saved = null;
  const phone = new CloudController({ fetch: request, storage: { async load() { return saved; }, async save(value) { saved = structuredClone(value); } } });
  await phone.connect('https://cloud.example.test', { accessToken: token, expiresAt: Date.now() + 3600000 }, { name: 'QA phone', platform: 'ios', viewport: { width: 852, height: 393 } });
  const deviceId = phone.snapshot().session.device.id;
  const deviceToken = phone.snapshot().session.deviceToken;
  const mcp = async (name, args = {}) => {
    const response = await request(new Request('https://cloud.example.test/mcp', {
      method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json', accept: 'application/json, text/event-stream', 'mcp-protocol-version': '2025-11-25' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name, arguments: args } }),
    }));
    assert.equal(response.status, 200);
    const { result, error } = await response.json(); assert.equal(error, undefined);
    assert.ok(!result.isError, JSON.stringify(result.structuredContent));
    return result.structuredContent;
  };
  const { devices } = await mcp('list_devices'); assert.equal(devices[0].id, deviceId);
  assert.equal(JSON.stringify(devices).includes(deviceToken), false);
  const first = await mcp('save_profile', { profile: xboxProfile, expectedRevision: 0 });
  await mcp('save_profile', { profile: { ...xboxProfile, name: 'Later revision' }, expectedRevision: first.revision });
  const args = { deviceId, profileId: first.profile.id, profileRevision: first.revision, requestId: 'first-journey' };
  const { delivery } = await mcp('deliver_profile', args);
  assert.equal(delivery.state, 'queued');
  await phone.poll();
  const selection = phone.snapshot().selected;
  assert.equal(selection.revision, first.revision);
  assert.equal(selection.profile.name, xboxProfile.name);
  phone.setEnvironment({ lanOffline: false });
  await phone.rendered(selection);
  assert.equal((await mcp('delivery_status', { deliveryId: delivery.id })).delivery.state, 'received');
  // An account-authenticated AI cannot fabricate a phone receipt.
  const spoof = await request(apiRequest(`/devices/${deviceId}/deliveries/${delivery.id}/ack`, token, { method: 'POST', body: { profileId: first.profile.id, profileRevision: first.revision, state: 'rendered' } }));
  assert.equal(spoof.status, 401);
  phone.setEnvironment({ lanOffline: true });
  await phone.rendered(selection);
  const receipt = (await mcp('delivery_status', { deliveryId: delivery.id })).delivery;
  assert.equal(receipt.state, 'rendered'); assert.equal(receipt.profileRevision, first.revision);
  assert.equal(saved.cache.revision, first.revision);
  assert.equal((await mcp('deliver_profile', args)).delivery.id, delivery.id);
  const other = await authority.token({ sub: 'another-account' });
  assert.equal((await request(apiRequest(`/deliveries/${delivery.id}`, other))).status, 404);
  const revoked = await request(apiRequest(`/devices/${deviceId}`, token, { method: 'DELETE' }));
  assert.equal(revoked.status, 200);
  assert.equal((await request(apiRequest(`/devices/${deviceId}/deliveries`, deviceToken))).status, 401);
  await phone.logout(); assert.equal(saved, null); assert.equal(phone.snapshot().selected, null);
});

test('unconfigured composed cloud service exposes no demo account or tools', async () => {
  assert.equal((await worker.fetch(new Request('https://cloud.example.test/v1/config'), {})).status, 503);
  const response = await worker.fetch(new Request('https://cloud.example.test/mcp'), {});
  assert.equal(response.status, 503);
  assert.equal((await response.json()).error.code, 'not_configured');
});
