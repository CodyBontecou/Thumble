import test from 'node:test';
import assert from 'node:assert/strict';
import { registerHooks } from 'node:module';
import { TouchController, defaultProfile, neutralState } from '@tapping/controller';

const hooks = registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier === 'expo-modules-core') return { url: 'data:text/javascript,export const requireOptionalNativeModule = () => null;', shortCircuit: true };
    return nextResolve(specifier, context);
  },
});
const { calibration } = await import('../../apps/mobile/src/calibration.js');
hooks.deregister();

test('ConsolePort movement sends negative Y upward, positive Y downward, before and after calibration', () => {
  const mirrored = { ...defaultProfile, id: 'consoleport-0123456789abcdef01234567' };
  const legacy = structuredClone(mirrored);
  delete legacy.mappings.find(mapping => mapping.outputs.includes('ly')).invertY;
  const legacyDefault = { ...legacy, id: defaultProfile.id };
  for (const profile of [defaultProfile, calibration.standard(), calibration.standard(undefined, mirrored), calibration.standard(undefined, legacy), calibration.standard(undefined, legacyDefault)]) {
    const controller = new TouchController(profile);
    controller.setViewport(740, 380);
    const { frame } = profile.controls.find(control => control.id === 'left-stick');
    const x = frame.x + frame.width / 2, y = frame.y + frame.height / 2;
    controller.down(1, x, y);
    controller.move(1, x, y - frame.height / 2);
    assert.equal(controller.snapshot().ly, -1, 'pushing up must move forward');
    controller.move(1, x, y + frame.height / 2);
    assert.equal(controller.snapshot().ly, 1, 'pushing down must move backward');
    controller.move(1, x + frame.width / 2, y);
    assert.ok(Math.abs(controller.snapshot().lx - 1) < 1e-12);
    controller.up(1);
    assert.deepEqual(controller.snapshot(), neutralState());
  }
});

test('vertical calibration toggles the ConsolePort movement direction', () => {
  const settings = structuredClone(calibration.snapshot());
  settings.left.invertY = true;
  const profile = calibration.standard(settings);
  assert.equal(profile.mappings.find(mapping => mapping.controlId === 'left-stick').invertY, false);
  assert.equal(profile.mappings.find(mapping => mapping.controlId === 'right-stick').invertY, false);
});
