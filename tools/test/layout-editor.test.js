import assert from 'node:assert/strict';
import test from 'node:test';
import { defaultProfile, validateProfile, validateLayout, controlDisplay } from '@tapping/controller';
import { addControl, availableOutputs, changeOutput, editFrame } from '../../apps/mobile/src/layout-editor.js';

test('adding a button finds a usable unoccupied target without changing existing controls', () => {
  const profile = structuredClone(defaultProfile), viewport = { width: 820, height: 380 };
  const next = addControl(profile, 'added', viewport);
  assert.equal(next.controls.length, profile.controls.length + 1);
  assert.deepEqual(next.controls.slice(0, -1), profile.controls);
  assert.deepEqual(validateProfile(next), []);
  assert.equal(validateLayout(next, viewport).valid, true);
});

test('drag and resize stay inside the canvas and allow independent dimensions', () => {
  const frame = { x: 0.5, y: 0.5, width: 0.2, height: 0.3 };
  assert.deepEqual(editFrame(frame, 1, -2, false), { ...frame, x: 0.8, y: 0 });
  assert.deepEqual(editFrame(frame, 1, -2, true, { width: 820, height: 380 }), { ...frame, width: 0.5, height: 48 / 380 });
});

test('extreme resizing keeps buttons and sticks usable, including tiny legacy controls at an edge', () => {
  const viewport = { width: 820, height: 380 };
  const frame = { x: 0.4, y: 0.4, width: 0.2, height: 0.3 };
  for (const [type, minimum] of [['button', 48], ['trigger', 48], ['stick', 96]]) {
    const resized = editFrame(frame, -2, -2, true, viewport, type);
    assert.equal(resized.width * viewport.width, minimum);
    assert.equal(resized.height * viewport.height, minimum);
  }
  const tiny = editFrame({ x: 0.99, y: 0.99, width: 0.01, height: 0.01 }, -2, -2, true, viewport);
  assert.equal(tiny.width * viewport.width, 48);
  assert.equal(tiny.height * viewport.height, 48);
  assert.ok(tiny.x + tiny.width <= 1 && tiny.y + tiny.height <= 1);
});

test('output changes follow matching spell layers and remove stale artwork for unmapped outputs', () => {
  const profile = structuredClone(defaultProfile);
  const buttons = profile.controls.filter(item => item.type === 'button' && item.id !== 'chat');
  const first = buttons[0], second = buttons[1];
  first.customLabel = 'My button';
  second.icon = 'spell_test'; second.layers = { '': { label: 'Spell', icon: 'spell_test' } };
  const output = profile.mappings.find(item => item.controlId === second.id).outputs;
  const changed = changeOutput(profile, first.id, output);
  assert.deepEqual(validateProfile(changed), []);
  const control = changed.controls.find(item => item.id === first.id);
  assert.deepEqual(control.layers, second.layers);
  assert.equal(control.customLabel, 'My button');
  assert.deepEqual(controlDisplay(control, '', changed), { label: 'My button' });
  const again = changeOutput(changed, first.id, ['guide']);
  assert.equal(again.controls.find(item => item.id === first.id).layers, undefined);
});

test('analog choices exclude another control’s owned axes and triggers', () => {
  const profile = structuredClone(defaultProfile);
  for (const control of profile.controls.filter(item => item.type !== 'button')) {
    const own = profile.mappings.find(item => item.controlId === control.id).outputs;
    assert.deepEqual(availableOutputs(profile, control), [own]);
  }
});

test('new analog controls require an available gamepad output', () => {
  const profile = structuredClone(defaultProfile), viewport = { width: 820, height: 380 };
  assert.equal(addControl(profile, 'third-stick', viewport, 'stick'), profile);
  const withoutRight = {
    ...profile, controls: profile.controls.filter(item => item.id !== 'right-stick'),
    mappings: profile.mappings.filter(item => item.controlId !== 'right-stick'),
  };
  const next = addControl(withoutRight, 'replacement', viewport, 'stick');
  assert.equal(next.controls.at(-1).type, 'stick');
  assert.deepEqual(next.mappings.at(-1).outputs, ['rx', 'ry']);
  assert.equal(validateLayout(next, viewport).valid, true);
});

test('tour presets: left-handed mirrors sticks and buttons, keeps shoulders, and fits every canvas', async () => {
  const { presetProfile, TOUR_PRESETS } = await import('../../apps/mobile/src/layout-editor.js');
  const { xboxProfile, consolePortProfile } = await import('@tapping/controller');
  assert.deepEqual(TOUR_PRESETS.map(item => item.id), ['xbox', 'lefty', 'consoleport']);
  const lefty = presetProfile('lefty', { xbox: xboxProfile, consoleport: consolePortProfile });
  const frame = (profile, id) => profile.controls.find(control => control.id === id).frame;
  assert.ok(frame(lefty, 'left-stick').x > 0.5);
  assert.ok(frame(lefty, 'a').x < 0.5);
  assert.deepEqual(frame(lefty, 'lt'), frame(xboxProfile, 'lt'));
  assert.ok(frame(lefty, 'left').x < frame(lefty, 'right').x && frame(lefty, 'x').x < frame(lefty, 'b').x && frame(lefty, 'back').x < frame(lefty, 'start').x);
  for (const [width, height] of [[568, 300], [740, 380], [900, 420]]) {
    for (const id of ['xbox', 'lefty', 'consoleport']) {
      assert.deepEqual(validateLayout(presetProfile(id, { xbox: xboxProfile, consoleport: consolePortProfile }), { width, height }).errors, [], `${id} ${width}×${height}`);
    }
  }
});

test('remapping a face button takes the donor button colour', async () => {
  const { xboxProfile } = await import('@tapping/controller');
  const a = xboxProfile.controls.find(control => control.id === 'a');
  const b = xboxProfile.controls.find(control => control.id === 'b');
  const changed = changeOutput(xboxProfile, 'a', ['b']);
  const remapped = changed.controls.find(control => control.id === 'a');
  assert.equal(remapped.label, b.label);
  assert.equal(remapped.color, b.color);
  assert.notEqual(remapped.color, a.color);
  const plain = changeOutput(xboxProfile, 'a', ['guide']);
  assert.equal(plain.controls.find(control => control.id === 'a').color, undefined);
});
