import test from 'node:test';
import assert from 'node:assert/strict';
import { initialSetup, normalizeSetup } from '../../apps/mobile/src/onboarding-core.js';

test('players from before the tour skip it once; replaying the tour sticks', () => {
  const legacy = { ...initialSetup(), dismissed: true };
  delete legacy.tourDone;
  assert.equal(normalizeSetup(legacy).tourDone, true);
  const replay = normalizeSetup({ ...normalizeSetup(legacy), tourDone: false, tourStage: '' });
  assert.equal(replay.tourDone, false);
  assert.equal(normalizeSetup({ ...replay, tourStage: 'connect' }).tourStage, 'connect');
  assert.equal(normalizeSetup({ ...replay, tourStage: 'bogus' }).tourStage, '');
  assert.equal(normalizeSetup(initialSetup()).tourDone, false);
});

test('a tour layout shows offline, survives reconnect attempts, and yields to the computer', async () => {
  const { Connection } = await import('../../apps/mobile/src/connection-core.js');
  const { xboxProfile } = await import('@tapping/controller');
  const { presetProfile } = await import('../../apps/mobile/src/layout-editor.js');
  const connection = new Connection({ addListener() {}, disconnect() {}, send: () => true });
  const lefty = presetProfile('lefty', { xbox: xboxProfile, consoleport: xboxProfile });
  assert.equal(connection.previewLayout(lefty), true);
  assert.equal(connection.profileSnapshot().profile.id, lefty.id);
  connection.disconnect('Retrying');
  assert.equal(connection.profileSnapshot().profile.id, lefty.id, 'a failed reconnect keeps the preview');
  connection.view = { ...connection.view, phase: 'connected' };
  assert.equal(connection.previewLayout(xboxProfile), false, 'a connected computer owns the layout');
  connection.receiveLayout({ revision: 1, profile: xboxProfile });
  connection.disconnect('Gone');
  assert.equal(connection.profileSnapshot().profile.id, xboxProfile.id);
});
