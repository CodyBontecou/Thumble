import { test } from 'node:test';
import assert from 'node:assert/strict';
import { xboxProfile } from '@tapping/controller';
import { CloudController } from '../../apps/mobile/src/cloud/core.js';
import { adoptCloudSelection } from '../../apps/mobile/src/cloud/adoption.js';
function fixture() {
  const selected = { profile: structuredClone(xboxProfile), revision: 7, cached: false, delivery: { id: 'delivery-1' } };
  const source = { service: 'https://pilot.example', accountId: 'a'.repeat(64), profileId: selected.profile.id, revision: 7 };
  const cloud = new CloudController({ storage: { load: async () => null, save: async () => {} }, fetch: async () => Response.json({ delivery: { state: 'rendered' } }) });
  cloud.setViewport({ width: 740, height: 380 });
  cloud.update({ session: { ...source, accessToken: 'fixture', device: { id: 'phone-1', name: 'Phone' }, deviceToken: 'device-fixture' }, selected, pending: selected.delivery, lanOffline: false });
  let adopts = 0;
  const connection = { session: 'pairing-1', snapshot: () => ({ phase: 'connected' }), requestProfiles: async () => ({ activationRevision: 9 }), adoptProfile: async (profile, receivedSource, expected) => {
    adopts++; assert.deepEqual(profile, selected.profile); assert.deepEqual(receivedSource, source); assert.equal(expected, 9);
    return { activationRevision: 10, adoption: { profileId: 'cloud-' + 'b'.repeat(40), profileRevision: 1, source } };
  } };
  return { cloud, connection, selected, adopts: () => adopts };
}
test('adoption is explicit and connects an exact cloud revision to one paired computer activation', async () => {
  const f = fixture();
  assert.equal(f.cloud.snapshot().macAdoption, null);
  await f.cloud.rendered(f.selected); assert.equal(f.cloud.snapshot().pending.id, 'delivery-1');
  const adoption = await adoptCloudSelection(f.cloud, f.connection);
  assert.equal(f.adopts(), 1); assert.equal(adoption.pairing, 'pairing-1'); assert.equal(adoption.source.revision, 7);
  // A random proof, a hidden app, or a different selection cannot acknowledge a render.
  await f.cloud.rendered(f.selected, { ...adoption }); assert.ok(f.cloud.snapshot().pending);
  f.cloud.setEnvironment({ foreground: false }); await f.cloud.rendered(f.selected, adoption); assert.ok(f.cloud.snapshot().pending);
  f.cloud.setEnvironment({ foreground: true }); await f.cloud.rendered(f.selected, adoption);
  assert.equal(f.cloud.snapshot().pending, null); assert.equal(f.cloud.cache.revision, 7);
});
test('switching account, selected revision or pairing while reading catalog cancels before adoption', async () => {
  for (const change of [f => { f.cloud.epoch++; }, f => { f.cloud.update({ selected: { ...f.selected, revision: 8 } }); }, f => { f.connection.session = 'other-pairing'; }]) {
    const f = fixture();
    f.connection.requestProfiles = async () => { change(f); return { activationRevision: 9 }; };
    await assert.rejects(adoptCloudSelection(f.cloud, f.connection), /changed/);
    assert.equal(f.adopts(), 0); assert.equal(f.cloud.snapshot().macAdoption, null);
  }
});
test('disconnection after receiver response does not publish an adoption success', async () => {
  const f = fixture(), perform = f.connection.adoptProfile;
  f.connection.adoptProfile = async (...args) => { const result = await perform(...args); f.connection.session = null; return result; };
  await assert.rejects(adoptCloudSelection(f.cloud, f.connection), /changed before confirmation/);
  assert.equal(f.cloud.snapshot().macAdoption, null);
});
