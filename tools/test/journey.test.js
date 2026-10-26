import test from 'node:test';
import assert from 'node:assert/strict';
import { cloudJourney, testContext } from '../../apps/mobile/src/journey.js';
import { WOW_CHECKS, initialSetup, normalizeSetup, canCompleteWowSetup, wowSetupStep } from '../../apps/mobile/src/onboarding-core.js';

function fixture() {
  const source = { service: 'https://cloud.example', accountId: 'a'.repeat(64), profileId: 'my-cloud-controller', revision: 3 };
  const selected = { profile: { id: source.profileId, name: 'My controller' }, revision: 3, delivery: { id: 'delivery-1', deviceId: 'phone-1', profileId: source.profileId, profileRevision: 3, state: 'rendered' }, cached: true };
  const state = { cloud: { session: { service: source.service, accountId: source.accountId, device: { id: 'phone-1' } }, selected, macAdoption: { pairing: 'pair-1', source, profileId: 'cloud-local', activationRevision: 8 } }, setup: { ...initialSetup(), wowClient: 'retail' }, network: { phase: 'connected' }, pairing: 'pair-1', layout: { profile: { id: 'cloud-local' }, revision: 8 }, access: { receiverId: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' }, layoutPending: false, recovering: false };
  return state;
}
test('phone sign-in, queued delivery and practice receipt cannot claim Computer readiness or WoW', () => {
  const state = fixture();
  state.cloud.macAdoption = null;
  assert.equal(cloudJourney(state).complete, 2);
  assert.equal(cloudJourney(state).route, '/cloud');
  state.cloud.selected.delivery.state = 'queued';
  assert.equal(cloudJourney(state).complete, 0);
  state.cloud.selected.delivery = null;
  assert.equal(cloudJourney(state).complete, 0);
});
test('Computer-ready requires the exact account, source revision, pairing and acknowledged activation', () => {
  assert.equal(cloudJourney(fixture()).complete, 3);
  for (const mutate of [s => s.pairing = 'other', s => s.layout.revision++, s => s.layout.profile.id = 'different', s => s.cloud.session.accountId = 'different', s => s.cloud.session.service = 'https://different.example', s => s.layoutPending = true, s => s.recovering = true, s => s.network.phase = 'offline']) {
    const state = fixture(); mutate(state); assert.equal(cloudJourney(state).ready, false);
  }
});
test('game confirmations persist for a receiver/activation/game, with retest after changes', () => {
  const state = fixture(), controlKey = testContext(state.access, state.layout), wowKey = testContext(state.access, state.layout, 'retail');
  state.setup = normalizeSetup({ ...state.setup, controlsTested: true, controlsCheckContext: controlKey, consolePortReady: true, wowSyncStatus: 'confirmed', wowSyncContext: wowKey, wowCheckContext: wowKey, wowTested: true, wowChecks: Object.fromEntries(WOW_CHECKS.map(check => [check.id, true])) });
  const context = { controlKey, wowKey };
  assert.equal(canCompleteWowSetup(state.setup, true, context), true);
  assert.equal(wowSetupStep(state.setup, true, context), 'ready');
  assert.equal(cloudJourney(state).complete, 4);
  state.setup.wowClient = 'classic-era';
  assert.equal(cloudJourney(state).tested, false);
  assert.equal(wowSetupStep(state.setup, true, { controlKey, wowKey: testContext(state.access, state.layout, 'classic-era') }), 'sync');
  assert.equal(wowSetupStep(state.setup, true, { controlKey: 'different-activation', wowKey }), 'game');
  assert.equal(cloudJourney({ ...state, network: { phase: 'offline' } }).tested, false);
});
