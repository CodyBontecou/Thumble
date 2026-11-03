import test from 'node:test';
import assert from 'node:assert/strict';
import { consolePortSyncView, usesPhoneCalibration } from '../../apps/mobile/src/consoleport-sync.js';

const profile = { id: 'consoleport-0123456789abcdef01234567', theme: 'consoleport' };
const catalog = { consolePortBridge: { enabled: true, detail: 'ConsolePort: Hero synced after reload' }, consolePortSync: {
  profileId: profile.id, characterName: 'Hero', exportedAt: 1792936000, following: true, modifiers: { shift: 'lt', ctrl: 'rt', alt: 'none' },
} };
const view = changes => consolePortSyncView({ online: true, profile, catalog, ...changes });

test('following status requires a connected Mac, enabled bridge and the matching active character profile', () => {
  assert.equal(view({}).title, 'Following ConsolePort');
  assert.equal(view({ online: false }).title, 'Connect your Mac');
  assert.equal(view({ error: 'Disconnected during refresh' }).following, false);
  assert.equal(view({ profile: { id: 'xbox-standard' } }).title, 'Another controller is active');
  assert.equal(view({ catalog: { ...catalog, consolePortBridge: { enabled: false } } }).title, 'ConsolePort sync is off');
  assert.equal(view({ catalog: {} }).title, 'Update your Mac receiver');
  assert.equal(view({ catalog: null, loading: true }).title, 'Checking ConsolePort…');
  assert.equal(view({ catalog: { consolePortBridge: { enabled: true } } }).title, 'Waiting for ConsolePort');
});

test('sync details remain display-only and malformed optional metadata cannot claim following status', () => {
  assert.deepEqual(view({}).modifiers.map(item => item.value), ['LT', 'RT', 'None']);
  for (const corrupt of [{ exportedAt: Infinity }, { exportedAt: 9e15 }, { characterName: '' }, { following: 'true' }]) {
    assert.equal(view({ catalog: { ...catalog, consolePortSync: { ...catalog.consolePortSync, ...corrupt } } }).following, false);
  }
  assert.equal(view({ catalog: { ...catalog, consolePortSync: { ...catalog.consolePortSync, modifiers: { shift: '<script>' } } } }).modifiers.length, 0);
});

test('phone calibration follows built-in and automatically synced ConsolePort profiles', () => {
  assert.equal(usesPhoneCalibration(profile), true);
  assert.equal(usesPhoneCalibration({ id: 'consoleport-standard' }), true);
  assert.equal(usesPhoneCalibration({ id: 'custom', theme: 'consoleport' }), false);
  assert.equal(usesPhoneCalibration({ ...profile, theme: undefined }), false);
});
