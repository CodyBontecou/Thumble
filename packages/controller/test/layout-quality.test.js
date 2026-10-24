import test from 'node:test';
import assert from 'node:assert/strict';
import { validateLayout, xboxProfile } from '../src/index.js';

const viewport = { width: 740, height: 380 };
const candidate = () => structuredClone(xboxProfile);
test('complete default gamepad fits a real landscape safe canvas', () => {
  assert.deepEqual(validateLayout(xboxProfile, viewport).errors, []);
});
test('undersized generated B button and overlapping action targets fail with named corrections', () => {
  const profile = candidate(), b = profile.controls.find(control => control.id === 'b');
  b.frame.width = 0.05;
  assert.ok(validateLayout(profile, viewport).errors.some(error => error.code === 'target_too_small' && error.controls.includes('b')));
  b.frame = { ...profile.controls.find(control => control.id === 'a').frame };
  assert.ok(validateLayout(profile, viewport).errors.some(error => error.code === 'overlapping_controls' && error.controls.includes('a') && error.controls.includes('b')));
});
test('checks actual touch geometry, toolbar occlusion, and both dimensions', () => {
  const profile = candidate(), b = profile.controls.find(control => control.id === 'b');
  b.frame = { x: 0.45, y: 0, width: 0.08, height: 0.15 };
  assert.ok(validateLayout(profile, viewport).errors.some(error => error.code === 'obscured_control' && error.controls.includes('b')));
  b.frame = { x: 0.895, y: 0.34, width: 0.07, height: 0.05 };
  assert.ok(validateLayout(profile, viewport).errors.some(error => error.code === 'target_too_small' && error.controls.includes('b')));
  profile.controls.find(control => control.id === 'left-stick').frame.width = 0.08;
  assert.ok(validateLayout(profile, viewport).errors.some(error => error.code === 'target_too_small' && error.controls.includes('left-stick')));
});
test('malformed profiles and missing/invalid canvas cannot claim a quality pass', () => {
  for (const size of [undefined, { width: 0, height: 400 }, { width: Infinity, height: 400 }, { width: '740', height: 380 }]) assert.equal(validateLayout(xboxProfile, size).valid, false);
  assert.equal(validateLayout({ controls: null }, viewport).valid, false);
  assert.equal(validateLayout(xboxProfile, { width: 340, height: 240 }).valid, false);
});
test('stick capture is a circle, so unoccupied bounding-box corners do not block nearby buttons', () => {
  const profile = { schemaVersion: 1, id: 'circle-test', name: 'Circle test', controls: [
    { id: 'stick', type: 'stick', label: 'Move', frame: { x: 0.1, y: 0.3, width: 0.3, height: 0.4 } },
    { id: 'a', type: 'button', label: 'A', frame: { x: 0.1, y: 0.3, width: 0.065, height: 0.13 } },
  ], mappings: [{ controlId: 'stick', outputs: ['lx', 'ly'] }, { controlId: 'a', outputs: ['a'] }] };
  // With this deliberately wide canvas the circular stick is centered away
  // from the small button, despite overlapping declarative rectangles.
  assert.equal(validateLayout(profile, { width: 1200, height: 400 }).valid, true);
});
