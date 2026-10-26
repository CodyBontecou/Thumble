import { test } from 'node:test';
import assert from 'node:assert/strict';
import { profileDirectory } from '../src/paths.js';

test('profile defaults match Windows/Linux receiver paths and retain the Mac store', () => {
  assert.equal(profileDirectory({ platform: 'win32', env: { LOCALAPPDATA: 'C:\\Users\\Player\\AppData\\Local' }, home: 'C:\\Users\\Player' }),
    'C:\\Users\\Player\\AppData\\Local\\Thumble\\profiles');
  assert.equal(profileDirectory({ platform: 'win32', env: {}, home: 'C:\\Users\\Player' }),
    'C:\\Users\\Player\\AppData\\Local\\Thumble\\profiles');
  assert.equal(profileDirectory({ platform: 'linux', env: {}, home: '/home/player' }), '/home/player/.local/state/thumble/profiles');
  assert.equal(profileDirectory({ platform: 'linux', env: { XDG_STATE_HOME: '/state' }, home: '/home/player' }), '/state/thumble/profiles');
  assert.equal(profileDirectory({ platform: 'darwin', env: {}, home: '/Users/player' }).replaceAll('\\', '/'), '/Users/player/Library/Application Support/Tapping/profiles');
  assert.equal(profileDirectory({ platform: 'win32', env: { TAPPING_PROFILE_DIR: 'D:\\Gamepad' }, home: 'C:\\Users\\Player' }), 'D:\\Gamepad');
});
