import { test } from 'node:test';
import assert from 'node:assert/strict';
import { privateWindowsAcl } from '../src/pairing-permissions.js';

test('Windows QR files require protected ACLs allowing only the current SID and SYSTEM', () => {
  const sid = 'S-1-5-21-123-456-1001';
  const value = { sid, owner: sid, protected: true, rules: [{ sid, type: 'Allow', inherited: false }, { sid: 'S-1-5-18', type: 'Allow', inherited: false }] };
  assert(privateWindowsAcl(value));
  for (const change of [{ owner: 'S-1-1-0' }, { protected: false }, { sid: 'user name' }, { rules: [] },
    { rules: [...value.rules, { sid: 'S-1-1-0', type: 'Allow', inherited: false }] },
    { rules: [{ sid, type: 'Allow', inherited: true }] }]) assert.equal(privateWindowsAcl({ ...value, ...change }), false);
});
