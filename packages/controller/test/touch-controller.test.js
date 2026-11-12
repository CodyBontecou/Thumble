import test from 'node:test';
import assert from 'node:assert/strict';
import { BUTTONS, TouchController, neutralState, xboxProfile } from '../src/index.js';

const center = id => {
  const { frame } = xboxProfile.controls.find(control => control.id === id);
  return [frame.x + frame.width / 2, frame.y + frame.height / 2];
};

test('separate fingers can move, hold a modifier, and press an action concurrently', () => {
  const controller = new TouchController(xboxProfile);
  controller.down(1, 0.235, 0.43);
  controller.down(2, ...center('lt'));
  controller.down(3, ...center('a'));
  assert.ok(controller.snapshot().lx > 0.8);
  assert.equal(controller.snapshot().lt, 1);
  assert.equal(controller.snapshot().buttons & (1 << BUTTONS.indexOf('a')), 1);
  controller.up(3);
  assert.equal(controller.snapshot().buttons, 0);
  assert.equal(controller.snapshot().lt, 1);
});

test('moving outside a captured button releases it without pressing a neighboring button', () => {
  const controller = new TouchController(xboxProfile);
  controller.down(1, ...center('a'));
  controller.move(1, ...center('b'));
  assert.equal(controller.snapshot().buttons, 0);
  controller.move(1, ...center('a'));
  assert.equal(controller.snapshot().buttons, 1);
  controller.releaseAll();
  assert.deepEqual(controller.snapshot(), neutralState());
});

test('releasing one finger on the same button preserves the other hold', () => {
  const controller = new TouchController(xboxProfile);
  controller.down(1, ...center('a'));
  controller.down(2, ...center('a'));
  controller.up(1);
  assert.equal(controller.snapshot().buttons, 1);
  controller.up(2);
  assert.equal(controller.snapshot().buttons, 0);
});

test('a second finger cannot steal a stick, and cancellation neutralizes every input', () => {
  const controller = new TouchController(xboxProfile);
  controller.down(1, 0.235, 0.43);
  controller.down(2, ...center('left-stick'));
  assert.ok(controller.snapshot().lx > 0.8);
  controller.up(2);
  assert.ok(controller.snapshot().lx > 0.8);
  controller.releaseAll();
  controller.move(1, 0.235, 0.43);
  assert.deepEqual(controller.snapshot(), neutralState());
});

test('replacing a touched layout releases old touch ownership and uses the new geometry', () => {
  const states = [];
  const controller = new TouchController(xboxProfile, { onState: state => states.push(state) });
  controller.down(1, 0.85, 0.55);
  const candidate = structuredClone(xboxProfile);
  candidate.controls.find(control => control.id === 'a').frame = { x: 0.5, y: 0.5, width: 0.1, height: 0.1 };
  controller.replaceProfile(candidate);
  assert.deepEqual(controller.snapshot(), neutralState());
  controller.move(1, 0.55, 0.55);
  assert.deepEqual(controller.snapshot(), neutralState());
  controller.down(2, 0.55, 0.55);
  assert.equal(controller.snapshot().buttons & 1, 1);
  assert.throws(() => controller.replaceProfile({ ...candidate, code: 'invalid' }));
  assert.equal(controller.snapshot().buttons & 1, 1, 'invalid layout must not interrupt a working profile');
});

test('per-stick inversion reverses both output axes while the cap follows the finger', () => {
  const profile = structuredClone(xboxProfile);
  for (const m of profile.mappings.filter(m => m.outputs.length === 2)) Object.assign(m, { invertX: true, invertY: true });
  const visuals = new Map();
  const controller = new TouchController(profile, { onVisual: (id, visual) => visuals.set(id, visual) });
  for (const [id, axes] of [['left-stick', ['lx', 'ly']], ['right-stick', ['rx', 'ry']]]) {
    const [x, y] = center(id);
    const f = profile.controls.find(c => c.id === id).frame;
    controller.down(id, x, y);
    for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
      controller.move(id, x + dx * f.width / 2, y - dy * f.height / 2);
      assert(Math.abs(controller.snapshot()[axes[0]] + dx) < 1e-12);
      assert(Math.abs(controller.snapshot()[axes[1]] + dy) < 1e-12);
      assert(Math.abs(visuals.get(id).x - dx) < 1e-12);
      assert(Math.abs(visuals.get(id).y - dy) < 1e-12);
    }
    controller.up(id);
    assert.deepEqual(controller.snapshot(), neutralState());
  }
});

test('a stick starts inside its visible circle, captures outside drags and releases only its owner', () => {
  const p = structuredClone(xboxProfile);
  const visuals = new Map();
  const c = new TouchController(p, { onVisual: (id, v) => visuals.set(id, v) });
  c.setViewport(800, 400);
  const stick = p.controls.find(c => c.id === 'left-stick');
  const [x, y] = center('left-stick');
  c.down(1, stick.frame.x + .001, stick.frame.y + .001);
  c.move(1, -1, -1);
  c.move(1, x, y);
  assert.deepEqual(c.snapshot(), neutralState(), 'a touch outside the circle cannot acquire the stick');
  c.down(2, x, y);
  c.down(3, ...center('a'));
  c.move(2, x + .4, y - .3);
  const s = c.snapshot();
  assert(Math.abs(Math.hypot(s.lx, s.ly) - 1) < 1e-12);
  assert(Math.abs(s.lx / s.ly - (800 * .4) / (400 * .3)) < 1e-12, 'outside drags preserve physical direction');
  assert.equal(s.buttons, 1);
  c.up(3);
  assert.equal(c.snapshot().lx, s.lx, 'another finger lifting cannot release movement');
  assert(Math.hypot(visuals.get('left-stick').x, visuals.get('left-stick').y) <= 1.000001);
  c.move(2, -2, 3);
  assert(c.snapshot().lx < 0 && c.snapshot().ly < 0);
  c.up(2);
  assert.deepEqual(c.snapshot(), neutralState());
  c.move(2, x + .4, y);
  assert.deepEqual(c.snapshot(), neutralState());
  c.down(4, x, y);
  c.move(4, x + .4, y);
  c.setViewport(900, 400);
  assert.deepEqual(c.snapshot(), neutralState(), 'resizing releases captured fingers');
});
