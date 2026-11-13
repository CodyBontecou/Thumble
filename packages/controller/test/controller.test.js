import test from 'node:test';
import assert from 'node:assert/strict';
import { BUTTONS, Controller, InputWatchdog, neutralState, normalizeStick, validateProfile, xboxProfile } from '../src/index.js';

const copy = () => JSON.parse(JSON.stringify(xboxProfile));
const bit = button => 1 << BUTTONS.indexOf(button);

test('the shipped controller template has a mapping for every control', () => {
  assert.deepEqual(validateProfile(xboxProfile), []);
  assert.equal(xboxProfile.controls.length, 18);
});

test('concurrent movement, camera, modifier and action remain independent', () => {
  const controller = new Controller(xboxProfile);
  controller.update('left-stick', [1, 0]);
  controller.update('right-stick', [0, -1]);
  controller.update('lt', 0.8);
  controller.update('a', true);
  assert.deepEqual(controller.snapshot(), { ...neutralState(), buttons: bit('a'), lx: 1, ry: -1, lt: 0.8 });
  controller.update('a', false);
  assert.equal(controller.snapshot().lx, 1);
  assert.equal(controller.snapshot().lt, 0.8);
});

test('releasing one of two touch controls mapped to A does not release the other', () => {
  const profile = copy();
  profile.mappings.find(mapping => mapping.controlId === 'b').outputs = ['a'];
  const controller = new Controller(profile);
  controller.update('a', true);
  controller.update('b', true);
  controller.update('a', false);
  assert.equal(controller.snapshot().buttons, bit('a'));
  controller.update('b', false);
  assert.equal(controller.snapshot().buttons, 0);
});

test('stick deadzone is radial and diagonal input cannot exceed unit magnitude', () => {
  assert.deepEqual(normalizeStick(0.05, 0.05), [0, 0]);
  const [x, y] = normalizeStick(1, 1);
  assert.ok(Math.abs(Math.hypot(x, y) - 1) < 1e-12);
  assert.ok(Math.abs(x - y) < 1e-12);
  assert.deepEqual(normalizeStick(0, -1), [0, -1]);
});

test('disconnect or background release clears every held control', () => {
  const controller = new Controller(xboxProfile);
  controller.update('left-stick', [1, 1]);
  controller.update('rt', 1);
  controller.update('a', true);
  assert.deepEqual(controller.releaseAll(), neutralState());
  assert.deepEqual(controller.snapshot(), neutralState());
});

test('profile replacement clears held input and takes an isolated copy', () => {
  const profile = copy();
  const controller = new Controller(xboxProfile);
  controller.update('a', true);
  assert.deepEqual(controller.replaceProfile(profile), neutralState());
  profile.mappings.find(mapping => mapping.controlId === 'a').outputs = ['b'];
  controller.profile.mappings.find(mapping => mapping.controlId === 'a').outputs[0] = 'y';
  assert.equal(controller.update('a', true).buttons, bit('a'));
});

test('an invalid MCP profile edit does not alter the active profile or held state', () => {
  const controller = new Controller(xboxProfile);
  controller.update('a', true);
  const profile = copy();
  profile.mappings[0].outputs = ['launchShell'];
  assert.throws(() => controller.replaceProfile(profile), TypeError);
  assert.equal(controller.snapshot().buttons, bit('a'));
  assert.deepEqual(controller.profile, copy());
});

test('profiles reject duplicate IDs, missing mappings, oversized geometry and code fields', () => {
  const duplicate = copy();
  duplicate.controls[1].id = duplicate.controls[0].id;
  assert.ok(validateProfile(duplicate).some(error => error.includes('unique')));
  const unmapped = copy();
  unmapped.mappings.pop();
  assert.ok(validateProfile(unmapped).some(error => error.includes('needs a mapping')));
  const geometry = copy();
  geometry.controls[0].frame.width = 1;
  assert.ok(validateProfile(geometry).some(error => error.includes('safe-area')));
  const code = copy();
  code.controls[0].onPress = 'fetch(secret)';
  assert.ok(validateProfile(code).some(error => error.includes('unknown fields')));
});

test('profiles reject ambiguous analog ownership and mismatched control types', () => {
  const analog = copy();
  analog.mappings[1].outputs = ['lx', 'ly'];
  assert.ok(validateProfile(analog).some(error => error.includes('more than one owner')));
  const type = copy();
  type.mappings.find(mapping => mapping.controlId === 'a').outputs = ['lt'];
  assert.ok(validateProfile(type).some(error => error.includes('one gamepad button')));
});

test('malformed profile payloads produce validation errors without throwing', () => {
  for (const value of [null, undefined, [], 1, 'x', {}, { controls: [null], mappings: [null] }]) {
    assert.ok(validateProfile(value).length > 0);
  }
});

test('non-finite inputs never enter controller state', () => {
  const controller = new Controller(xboxProfile);
  assert.throws(() => controller.update('left-stick', [NaN, 0]), RangeError);
  assert.throws(() => controller.update('right-stick', [Infinity, 0]), RangeError);
  assert.throws(() => controller.update('lt', -0.1), RangeError);
  assert.throws(() => controller.update('a', 1), TypeError);
  assert.throws(() => controller.update('unknown', true), RangeError);
  assert.deepEqual(controller.snapshot(), neutralState());
});

test('receiver watchdog releases movement and buttons after 150ms without valid input', () => {
  let now = 0;
  const watchdog = new InputWatchdog({ now: () => now });
  assert.deepEqual(watchdog.poll(), neutralState());
  watchdog.accept({ ...neutralState(), buttons: bit('a'), lx: 1 });
  now = 149;
  assert.equal(watchdog.poll().lx, 1);
  now = 150;
  assert.deepEqual(watchdog.poll(), neutralState());
  now = 200;
  watchdog.accept({ ...neutralState(), rt: 1 });
  assert.equal(watchdog.poll().rt, 1);
  assert.deepEqual(watchdog.reset(), neutralState());
});

test('invalid packets cannot refresh the receiver watchdog', () => {
  let now = 0;
  const watchdog = new InputWatchdog({ now: () => now });
  const state = { ...neutralState(), buttons: bit('a') };
  watchdog.accept(state);
  state.buttons = bit('b');
  now = 149;
  assert.throws(() => watchdog.accept({ ...neutralState(), lx: NaN }), RangeError);
  assert.equal(watchdog.poll().buttons, bit('a'));
  now = 150;
  assert.deepEqual(watchdog.poll(), neutralState());
});

test('axis calibration accepts booleans only on sticks', () => {
  const p = copy();
  p.mappings.find(m => m.controlId === 'a').invertX = true;
  assert(validateProfile(p).some(e => e.includes('invertX must be a boolean on a stick')));
  delete p.mappings.find(m => m.controlId === 'a').invertX;
  p.mappings[0].invertY = -1;
  assert(validateProfile(p).some(e => e.includes('invertY must be a boolean on a stick')));
});

test('WoW binding proposals refuse keyboard keys with a clear reason', async () => {
  const { bindingChange, xboxProfile, validateProfile } = await import('../src/index.js');
  const profile = { ...xboxProfile,
    controls: [...xboxProfile.controls, { id: 'key-1', type: 'key', label: '1', frame: { x: 0.45, y: 0.6, width: 0.07, height: 0.15 } }],
    mappings: [...xboxProfile.mappings, { controlId: 'key-1', outputs: ['key:Digit1'] }] };
  assert.deepEqual(validateProfile(profile), []);
  const snapshot = { reserved: {}, bindings: [], spells: [{ id: 100, name: 'Charge', passive: false }] };
  assert.throws(() => bindingChange(snapshot, profile, { controlId: 'key-1', spellId: 100 }), /Choose a gamepad button or trigger/);
});
