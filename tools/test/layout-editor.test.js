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

test('adding a key presses the next free number key and fits the canvas', async () => {
  const { xboxProfile } = await import('@tapping/controller');
  const viewport = { width: 820, height: 380 };
  const one = addControl(xboxProfile, 'key-one', viewport, 'key');
  const two = addControl(one, 'key-two', viewport, 'key');
  assert.deepEqual(two.mappings.slice(-2).map(item => item.outputs), [['key:Digit1'], ['key:Digit2']]);
  assert.deepEqual(two.controls.slice(-2).map(item => [item.type, item.label]), [['key', '1'], ['key', '2']]);
  assert.deepEqual(validateProfile(two), []);
  assert.equal(validateLayout(two, viewport).valid, true);
});

test('a button switches to a keyboard key and back without stale gamepad artwork', async () => {
  const { setControlKind } = await import('../../apps/mobile/src/layout-editor.js');
  const { consolePortProfile } = await import('@tapping/controller');
  const profile = structuredClone(consolePortProfile);
  const a = profile.controls.find(item => item.id === 'a');
  Object.assign(a, { customLabel: 'Jump', icon: 'spell_test', layers: { '': { label: 'Spell', icon: 'spell_test' } } });
  const keyed = setControlKind(profile, 'a', 'keyboard');
  const key = keyed.controls.find(item => item.id === 'a');
  assert.deepEqual(validateProfile(keyed), []);
  assert.equal(key.type, 'key');
  assert.equal(key.label, '1');
  assert.equal(key.customLabel, 'Jump');
  assert.deepEqual(key.frame, a.frame);
  for (const field of ['icon', 'layers', 'badge', 'color']) assert.equal(key[field], undefined, field);
  assert.deepEqual(keyed.mappings.find(item => item.controlId === 'a'), { controlId: 'a', outputs: ['key:Digit1'] });
  const back = setControlKind(keyed, 'a', 'gamepad');
  const button = back.controls.find(item => item.id === 'a');
  assert.deepEqual(validateProfile(back), []);
  assert.equal(button.type, 'button');
  assert.equal(button.customLabel, 'Jump');
  // The key freed A, so the first free gamepad button is A again, with its ConsolePort badge.
  assert.deepEqual(back.mappings.find(item => item.controlId === 'a').outputs, ['a']);
  assert.equal(button.label, 'A');
  assert.equal(button.badge, 'A');
  // If another control took A meanwhile, the key returns as the first button nobody sends.
  const taken = changeOutput(keyed, 'x', ['a']);
  assert.deepEqual(setControlKind(taken, 'a', 'gamepad').mappings.find(item => item.controlId === 'a').outputs, ['x']);
  assert.equal(setControlKind(back, 'left-stick', 'keyboard'), back, 'sticks stay analog');
  assert.equal(setControlKind(back, 'a', 'gamepad'), back, 'already a gamepad button');
});

test('picking keys keeps held modifiers, labels the chord and always leaves one key', async () => {
  const { setControlKind, pickKey, toggleModifier, chordLabel, keyParts } = await import('../../apps/mobile/src/layout-editor.js');
  const { xboxProfile } = await import('@tapping/controller');
  let profile = setControlKind(xboxProfile, 'x', 'keyboard');
  const outputs = () => profile.mappings.find(item => item.controlId === 'x').outputs;
  const label = () => profile.controls.find(item => item.id === 'x').label;
  profile = toggleModifier(profile, 'x', 'key:ShiftLeft');
  profile = pickKey(profile, 'x', 'key:Digit4');
  assert.deepEqual(outputs(), ['key:ShiftLeft', 'key:Digit4']);
  assert.equal(label(), 'Shift+4');
  profile = toggleModifier(profile, 'x', 'key:ControlLeft');
  assert.deepEqual(outputs(), ['key:ShiftLeft', 'key:ControlLeft', 'key:Digit4']);
  assert.equal(label(), 'Shift+Ctrl+4');
  assert.deepEqual(validateProfile(profile), []);
  profile = toggleModifier(toggleModifier(profile, 'x', 'key:ShiftLeft'), 'x', 'key:ControlLeft');
  assert.deepEqual(outputs(), ['key:Digit4']);
  assert.equal(pickKey(profile, 'x', 'key:ShiftLeft'), profile, 'modifiers are toggles, not main keys');
  assert.equal(pickKey(profile, 'a', 'key:Digit5'), profile, 'gamepad buttons have no key');
  // A chord recorded in the desktop workspace may hold two ordinary keys; picking one replaces both.
  const desktop = { ...profile, mappings: profile.mappings.map(item => item.controlId === 'x' ? { ...item, outputs: ['key:KeyA', 'key:AltLeft', 'key:KeyB'] } : item) };
  assert.deepEqual(keyParts(['key:KeyA', 'key:AltLeft', 'key:KeyB']), { modifiers: ['key:AltLeft'], main: ['key:KeyA', 'key:KeyB'] });
  assert.equal(chordLabel(['key:KeyA', 'key:AltLeft', 'key:KeyB']), 'Alt+A+B');
  assert.deepEqual(pickKey(desktop, 'x', 'key:F1').mappings.find(item => item.controlId === 'x').outputs, ['key:AltLeft', 'key:F1']);
  // Toggling a modifier on and off keeps the rest of the chord, in chord order.
  const roundTrip = toggleModifier(toggleModifier(desktop, 'x', 'key:ShiftLeft'), 'x', 'key:ShiftLeft');
  assert.deepEqual(roundTrip.mappings.find(item => item.controlId === 'x').outputs, ['key:AltLeft', 'key:KeyA', 'key:KeyB']);
  // A modifier-only key (a held Shift) keeps its last key.
  const lone = { ...profile, mappings: profile.mappings.map(item => item.controlId === 'x' ? { ...item, outputs: ['key:ShiftLeft'] } : item) };
  assert.equal(toggleModifier(lone, 'x', 'key:ShiftLeft'), lone);
});

test('the key picker pages list every registry key once and leave modifiers to the toggles', async () => {
  const { KEY_GROUPS, KEY_MODIFIERS } = await import('../../apps/mobile/src/layout-editor.js');
  const { desktopKeys } = await import('@tapping/controller');
  const listed = KEY_GROUPS.flatMap(group => group.keys);
  assert.equal(new Set(listed).size, listed.length);
  assert.deepEqual([...listed, ...KEY_MODIFIERS.map(item => item.key)].sort(), [...desktopKeys].sort());
  assert.deepEqual(KEY_GROUPS[0].keys.map(key => key.slice(-1)).join(''), '1234567890');
  assert.ok(KEY_GROUPS.every(group => group.keys.length > 0));
});
