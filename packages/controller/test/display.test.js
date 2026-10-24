import test from 'node:test';
import assert from 'node:assert/strict';
import { BUTTONS, TouchController, consolePortProfile, xboxProfile, modifierPrefix, controlDisplay, neutralState } from '../src/index.js';

function harness(profile) {
  let state = neutralState();
  const controller = new TouchController(profile, { onState: next => { state = next; } });
  const control = id => profile.controls.find(control => control.id === id);
  return {
    controller,
    press(id) {
      const { frame } = control(id);
      controller.down(id, frame.x + frame.width / 2, frame.y + frame.height / 2);
    },
    release: id => controller.up(id),
    display: id => controlDisplay(control(id), modifierPrefix(profile, state), profile),
    state: () => state,
  };
}

test('generic ConsolePort follows LT, RT and both, with independent release and unchanged gamepad output', () => {
  for (const first of ['lt', 'rt']) {
    const other = first === 'lt' ? 'rt' : 'lt';
    const h = harness(consolePortProfile);
    assert.equal(h.display('a').label, 'A');
    h.press(first);
    assert.equal(h.display('a').label, `${first.toUpperCase()} + A`);
    assert.equal(h.display('up').label, `${first.toUpperCase()} + ↑`);
    h.press(other);
    assert.equal(h.display('a').label, 'LT + RT + A');
    // Changing presentation never presses an action or interrupts either trigger.
    assert.deepEqual(h.state(), { ...neutralState(), lt: 1, rt: 1 });
    h.press('a');
    assert.equal(h.state().buttons, 1 << BUTTONS.indexOf('a'));
    h.release(first);
    assert.equal(h.display('a').label, `${other.toUpperCase()} + A`);
    assert.equal(h.state().buttons, 1 << BUTTONS.indexOf('a'));
    h.release(other);
    assert.equal(h.display('a').label, 'A');
    h.release('a');
    assert.deepEqual(h.state(), neutralState());
  }
});

test('exported ConsolePort layers respect character modifier assignments, including swapped triggers', () => {
  for (const modifiers of [{ shift: 'lt', ctrl: 'rt' }, { shift: 'rt', ctrl: 'lt' }]) {
    const profile = structuredClone(consolePortProfile);
    profile.modifiers = modifiers;
    profile.controls.find(c => c.id === 'a').layers = {
      '': { label: 'Base action' },
      'SHIFT-': { label: 'Shift action', icon: 'shift_icon' },
      'CTRL-': { label: 'Ctrl action', icon: 'ctrl_icon' },
      'CTRL-SHIFT-': { label: 'Combined action', icon: 'both_icon' },
    };
    const h = harness(profile);
    h.press('lt');
    assert.equal(h.display('a').label, modifiers.shift === 'lt' ? 'Shift action' : 'Ctrl action');
    h.press('rt');
    assert.deepEqual(h.display('a'), { label: 'Combined action', icon: 'both_icon' });
    h.release('lt');
    assert.equal(h.display('a').label, modifiers.shift === 'rt' ? 'Shift action' : 'Ctrl action');
    h.release('rt');
    assert.equal(h.display('a').label, 'Base action');
    h.press('rt');
    h.controller.releaseAll(); // Background, navigation, disconnect and responder cancellation.
    assert.equal(h.display('a').label, 'Base action');
    assert.deepEqual(h.state(), neutralState());
  }
});

test('modifier controls retain the complementary action, and empty layers stay empty', () => {
  const profile = structuredClone(consolePortProfile);
  profile.modifiers = { shift: 'lt', ctrl: 'rt' };
  profile.controls.find(c => c.id === 'lt').layers = {
    '': { label: 'LT' }, 'CTRL-': { label: 'RT + LT' },
  };
  profile.controls.find(c => c.id === 'a').layers = { 'CTRL-SHIFT-': { label: 'Unbound' } };
  const h = harness(profile);
  h.press('lt');
  assert.equal(h.display('lt').label, 'LT');
  h.press('rt');
  assert.equal(h.display('lt').label, 'RT + LT');
  assert.equal(h.display('a').label, 'Unbound');
});

test('generic fallback leaves triggers, sticks and menus stable; explicit disabled modifiers and Xbox stay unchanged', () => {
  for (const profile of [xboxProfile, { ...consolePortProfile, modifiers: { shift: 'none', ctrl: 'none' } }]) {
    const h = harness(profile);
    h.press('lt'); h.press('rt');
    assert.equal(h.display('a').label, 'A');
  }
  const h = harness(consolePortProfile);
  h.press('lt'); h.press('rt');
  for (const id of ['lt', 'rt', 'left-stick', 'right-stick', 'back', 'start', 'ls', 'rs']) {
    assert.equal(h.display(id).label, consolePortProfile.controls.find(c => c.id === id).label);
  }
  assert.equal(modifierPrefix(consolePortProfile, { ...neutralState(), rt: 0.5 }), '');
  assert.equal(modifierPrefix(consolePortProfile, { ...neutralState(), rt: 0.51 }), 'RT-');
});

test('state callbacks carry the input profile across replacements and resets', () => {
  const exported = structuredClone(consolePortProfile);
  exported.id = 'character';
  exported.modifiers = { shift: 'rt' };
  let prefix = '', active;
  const controller = new TouchController(consolePortProfile, {
    onState(state, profile) { active = profile.id; prefix = modifierPrefix(profile, state); },
  });
  const rt = consolePortProfile.controls.find(c => c.id === 'rt').frame;
  controller.down(1, rt.x + rt.width / 2, rt.y + rt.height / 2);
  assert.equal(prefix, 'RT-');
  controller.replaceProfile(exported);
  assert.equal(prefix, '');
  controller.down(1, rt.x + rt.width / 2, rt.y + rt.height / 2);
  assert.equal(active, 'character');
  assert.equal(prefix, 'SHIFT-');
  controller.releaseAll();
  assert.equal(prefix, '');
  assert.equal(active, 'character');
});
