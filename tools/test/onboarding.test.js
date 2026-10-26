import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createOnboardingStore, firstLayoutDelivered, firstLayoutPrompt, initialSetup, matchesAgentCheck, normalizeSetup, setupComplete } from '../../apps/mobile/src/onboarding-core.js';
function fixture(raw = '', legacy = false) {
  let disk = raw, fail = false;
  const storage = { read: async () => disk, legacyComplete: async () => legacy, write: async value => { if (fail) throw Error('Disk unavailable'); disk = value; } };
  return { storage, store: createOnboardingStore(storage), fail: value => { fail = value; } };
}
test('setup resumes milestones and preferences after restart, without completing skipped steps', async () => {
  const { storage, store } = fixture();
  await store.update({ paired: true, layoutMode: 'character', character: 'Warrior', agentCode: '123456abcdef', profileId: 'first-layout-test' });
  await store.update({ dismissed: true });
  const restarted = createOnboardingStore(storage);
  assert.equal(await restarted.isComplete(), true); // may enter controller
  const state = restarted.snapshot();
  assert.equal(setupComplete(state), false);
  assert.equal(state.paired, true);
  assert.equal(state.controlsTested, false);
  assert.equal(state.wowTested, false);
  assert.equal(state.personalized, false);
  assert.equal(state.character, 'Warrior');
  assert.equal(state.profileId, 'first-layout-test');
});
test('legacy intro completion skips the new funnel without inventing milestones', async () => {
  const { store } = fixture('', true);
  assert.equal(await store.isComplete(), true);
  assert.equal(store.snapshot().paired, false);
  assert.equal(setupComplete(store.snapshot()), false);
});
test('concurrent writes preserve milestones and failed writes can be retried', async () => {
  const f = fixture();
  await Promise.all([f.store.update({ paired: true }), f.store.update({ controlsTested: true }), f.store.update({ character: 'Mage' })]);
  assert.equal(f.store.snapshot().paired, true);
  assert.equal(f.store.snapshot().controlsTested, true);
  f.fail(true);
  await assert.rejects(f.store.update({ wowTested: true }), /Disk unavailable/);
  assert.equal(f.store.snapshot().wowTested, false);
  f.fail(false);
  await f.store.update({ wowTested: true, personalized: true });
  assert.equal(setupComplete(f.store.snapshot()), true);
});
test('invalid persisted data cannot claim verified milestones or inject a profile identifier', () => {
  const state = normalizeSetup({ version: 2, paired: 'true', wowTested: 1, profileId: '../bad', character: 'x'.repeat(1000), movementSide: 'up' });
  assert.equal(state.paired, false);
  assert.equal(state.wowTested, false);
  assert.equal(state.profileId, '');
  assert.equal(state.character.length, 80);
  assert.equal(state.movementSide, 'left');
});
test('agent verification needs matching supported, fresh receiver evidence', () => {
  const code = '123456abcdef';
  const catalog = { agentCheckSupported: true, agentConnection: { code, ageSeconds: 2 } };
  assert.equal(matchesAgentCheck(catalog, code), true);
  assert.equal(matchesAgentCheck(catalog, '111111111111'), false);
  assert.equal(matchesAgentCheck({}, code), false);
  for (const ageSeconds of [-1, 601, NaN, Infinity, '2']) assert.equal(matchesAgentCheck({ ...catalog, agentConnection: { code, ageSeconds } }, code), false);
});
test('layout completion requires the requested rendered profile and completed neutral recovery', () => {
  const state = { ...initialSetup(), profileId: 'first-layout-test' };
  const network = { phase: 'connected' }, layout = { profile: { id: state.profileId }, revision: 3 };
  assert.equal(firstLayoutDelivered(state, network, layout, false, false), true);
  assert.equal(firstLayoutDelivered(state, { phase: 'offline' }, layout, false, false), false);
  assert.equal(firstLayoutDelivered(state, network, { ...layout, profile: { id: 'other' } }, false, false), false);
  assert.equal(firstLayoutDelivered(state, network, layout, true, false), false);
  assert.equal(firstLayoutDelivered(state, network, layout, false, true), false);
  assert.equal(firstLayoutDelivered(state, network, { ...layout, revision: 0 }, false, false), false);
});
test('first-layout request survives restart and preserves the character review and receipt boundaries', async () => {
  const f = fixture();
  await f.store.update({ layoutMode: 'consoleport', movementSide: 'right', profileId: 'first-layout-test', agentCode: '123456abcdef' });
  const state = await createOnboardingStore(f.storage).load();
  const prompt = firstLayoutPrompt(state, 'xbox');
  for (const expected of ['mirror_consoleport', 'first-layout-test', '123456abcdef', 'movement on the right', 'verified result', 'acknowledged']) assert.ok(prompt.includes(expected), expected);
});

test('WoW setup resumes each checkpoint and reconnect takes priority over stale completion', async () => {
  const { WOW_CHECKS, wowSetupStep, canCompleteWowSetup } = await import('../../apps/mobile/src/onboarding-core.js');
  const f = fixture();
  assert.equal(wowSetupStep(f.store.snapshot(), false), 'client');
  await f.store.update({ wowClient: 'classic-era' });
  assert.equal(wowSetupStep(f.store.snapshot(), false), 'connect');
  assert.equal(wowSetupStep(f.store.snapshot(), true), 'addon');
  await f.store.update({ consolePortReady: true });
  assert.equal(wowSetupStep(f.store.snapshot(), true), 'sync');
  await f.store.update({ wowSyncStatus: 'skipped', wowSyncContext: 'receiver:consoleport:1:classic-era' });
  assert.equal(wowSetupStep(f.store.snapshot(), true), 'game');
  assert.equal(canCompleteWowSetup(f.store.snapshot(), true), false);
  await Promise.all(WOW_CHECKS.map(check => f.store.update(previous => ({ wowChecks: { ...previous.wowChecks, [check.id]: true } }))));
  const resumed = await createOnboardingStore(f.storage).load();
  assert.equal(canCompleteWowSetup(resumed, true), true);
  assert.equal(canCompleteWowSetup(resumed, false), false);
  assert.equal(resumed.wowTested, false);
  await f.store.update({ wowTested: true, controlsTested: true });
  assert.equal(wowSetupStep(f.store.snapshot(), true), 'ready');
  assert.equal(wowSetupStep(f.store.snapshot(), false), 'connect');
  await f.store.update({ wowClient: 'retail', consolePortReady: false, wowTested: false, wowChecks: {} });
  assert.equal(wowSetupStep(f.store.snapshot(), true), 'addon');
  assert.equal(canCompleteWowSetup(f.store.snapshot(), true), false);
});

test('old setup saves retain milestones; malformed WoW checkpoints cannot claim completion', async () => {
  const { canCompleteWowSetup } = await import('../../apps/mobile/src/onboarding-core.js');
  const old = normalizeSetup({ version: 2, paired: true, wowTested: true });
  assert.equal(old.wowTested, true);
  assert.equal(old.consolePortReady, false);
  assert.equal(old.wowClient, '');
  const invalid = normalizeSetup({ version: 2, wowClient: 'invented', consolePortReady: 'true', controlsTested: true, wowChecks: { movement: 'true', arbitrary: true } });
  assert.equal(invalid.wowClient, '');
  assert.equal(invalid.wowChecks.movement, false);
  assert.equal('arbitrary' in invalid.wowChecks, false);
  assert.equal(canCompleteWowSetup(invalid, true), false);
});

test('WoW cloud request carries saved preferences and binds preview to exact phone/revision without inventing game state', async () => {
  const { cloudLayoutPrompt } = await import('../../apps/mobile/src/onboarding-core.js');
  const state = { ...initialSetup(), wowClient: 'classic-era', layoutMode: 'consoleport', movementSide: 'right', character: 'Warrior' };
  const prompt = cloudLayoutPrompt(state, { service: 'https://example.test', device: { id: 'phone-a', name: 'My phone' } });
  for (const expected of ['WoW Classic Era', 'ConsolePort', 'both triggers', 'D-pad', 'View and Menu', 'movement on the right', 'phone-a', 'exact saved revision', 'not working computer input', 'separate local agent handoff', 'not a verified export']) assert.ok(prompt.includes(expected), expected);
  assert.equal(cloudLayoutPrompt({ ...initialSetup(), layoutMode: 'familiar' }, { service: 'https://example.test', device: { id: 'phone-a', name: 'My phone' } }).includes('I play'), false);
});


test('WoW setup uses one in-game checklist and keeps confirmations tied to the live controller', async () => {
  const { WOW_CHECKS, wowSetupStep, canCompleteWowSetup } = await import('../../apps/mobile/src/onboarding-core.js');
  const context = { controlKey: 'receiver:consoleport-standard:3', wowKey: 'receiver:consoleport-standard:3:retail' };
  const setup = { ...initialSetup(), wowClient: 'retail' };
  assert.equal(wowSetupStep(setup, true, context), 'addon');
  const prepared = { ...setup, consolePortReady: true, wowSyncStatus: 'confirmed', wowSyncContext: context.wowKey, wowCheckContext: context.wowKey, wowChecks: Object.fromEntries(WOW_CHECKS.map(check => [check.id, true])) };
  assert.equal(wowSetupStep(prepared, true, context), 'game');
  assert.equal(canCompleteWowSetup(prepared, true, context), true); // no separate pre-test
  for (const check of WOW_CHECKS) assert.equal(canCompleteWowSetup({ ...prepared, wowChecks: { ...prepared.wowChecks, [check.id]: false } }, true, context), false);
  assert.equal(canCompleteWowSetup(prepared, false, context), false);
  assert.equal(canCompleteWowSetup(prepared, true, { controlKey: '', wowKey: '' }), false);
  assert.equal(canCompleteWowSetup(prepared, true, { controlKey: 'new-controller', wowKey: 'new-controller:retail' }), false);
  const completed = { ...prepared, controlsTested: true, controlsCheckContext: context.controlKey, wowTested: true };
  assert.equal(wowSetupStep(completed, true, context), 'ready');
  assert.equal(wowSetupStep(completed, false, context), 'connect');
  assert.equal(wowSetupStep(completed, true, { controlKey: 'different', wowKey: context.wowKey }), 'game');
});


test('label sync confirmation and skip persist for the current controller and invalidate on context changes', async () => {
  const { WOW_CHECKS, wowSetupStep, canCompleteWowSetup } = await import('../../apps/mobile/src/onboarding-core.js');
  const context = { controlKey: 'receiver:consoleport:2', wowKey: 'receiver:consoleport:2:classic-era' };
  for (const status of ['confirmed', 'skipped']) {
    const f = fixture();
    await f.store.update({ wowClient: 'classic-era', consolePortReady: true });
    assert.equal(wowSetupStep(f.store.snapshot(), true, context), 'sync');
    await f.store.update({ wowSyncStatus: status, wowSyncContext: context.wowKey });
    const resumed = await createOnboardingStore(f.storage).load();
    assert.equal(resumed.wowSyncStatus, status);
    assert.equal(resumed.wowTested, false);
    assert.equal(resumed.controlsTested, false);
    assert.equal(wowSetupStep(resumed, true, context), 'game');
    assert.equal(wowSetupStep(resumed, false, context), 'connect');
    const checked = { ...resumed, wowCheckContext: context.wowKey, wowChecks: Object.fromEntries(WOW_CHECKS.map(check => [check.id, true])) };
    assert.equal(canCompleteWowSetup(checked, true, context), true);
    for (const wowKey of ['receiver:consoleport:3:classic-era', 'other:consoleport:2:classic-era', 'receiver:consoleport:2:retail']) {
      assert.equal(wowSetupStep(checked, true, { ...context, wowKey }), 'sync');
      assert.equal(canCompleteWowSetup(checked, true, { ...context, wowKey }), false);
    }
    assert.equal(wowSetupStep({ ...checked, wowSyncStatus: '' }, true, context), 'sync');
    assert.equal(canCompleteWowSetup({ ...checked, wowSyncStatus: '' }, true, context), false);
  }
});

test('legacy completed setups stay ready while malformed label confirmations cannot bypass the sync step', async () => {
  const { wowSetupStep } = await import('../../apps/mobile/src/onboarding-core.js');
  const context = { controlKey: 'receiver:consoleport:2', wowKey: 'receiver:consoleport:2:classic-era' };
  const prepared = { ...initialSetup(), wowClient: 'classic-era', consolePortReady: true };
  for (const extra of [{ wowSyncStatus: true }, { wowSyncStatus: 'confirmed' }, { wowSyncStatus: 'unknown', wowSyncContext: context.wowKey }, { wowSyncStatus: 'confirmed', wowSyncContext: '../invalid' }]) {
    assert.equal(wowSetupStep(normalizeSetup({ ...prepared, ...extra }), true, context), 'sync');
  }
  assert.equal(wowSetupStep({ ...prepared, wowTested: true, controlsTested: true, controlsCheckContext: context.controlKey, wowCheckContext: context.wowKey }, true, context), 'ready');
});
