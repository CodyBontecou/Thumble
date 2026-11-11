import { requireOptionalNativeModule } from 'expo-modules-core';
import { assertProfile, defaultProfile } from '@tapping/controller';
import { usesPhoneCalibration } from './consoleport-sync.js';
const native = requireOptionalNativeModule('TappingPurchases');
const defaults = () => ({ left: { invertX: false, invertY: false, deadzone: 0.12 }, right: { invertX: false, invertY: false, deadzone: 0.12 } });
let current = defaults();
const listeners = new Set();
function validate(value) {
  if (!value || Object.keys(value).sort().join() !== 'left,right') throw Error('Invalid calibration');
  for (const stick of [value.left, value.right]) if (!stick || Object.keys(stick).sort().join() !== 'deadzone,invertX,invertY' || typeof stick.invertX !== 'boolean' || typeof stick.invertY !== 'boolean' || !Number.isFinite(stick.deadzone) || stick.deadzone < 0 || stick.deadzone > 0.5) throw Error('Invalid stick calibration');
  return value;
}
export const calibration = {
  subscribe: listener => { listeners.add(listener); return () => listeners.delete(listener); },
  snapshot: () => current,
  async load() {
    try {
      const json = await native?.getCalibration();
      if (json) { current = validate(JSON.parse(json)); for (const listener of listeners) listener(); }
    } catch { /* Invalid legacy settings retain safe standard defaults. */ }
  },
  async set(value) {
    const next = validate(value);
    if (!native) throw Error('Install the updated app to save calibration.');
    await native.saveCalibration(JSON.stringify(next));
    current = next; for (const listener of listeners) listener();
  },
  standard(value = current, profile = defaultProfile) {
    return assertProfile({ ...profile, mappings: profile.mappings.map(mapping => {
      const stick = mapping.outputs[0] === 'lx' ? value.left : mapping.outputs[0] === 'rx' ? value.right : null;
      if (!stick) return mapping;
      // Existing receiver mirrors can retain mappings from before the movement
      // direction fix. Give all standard/synced movement sticks the same baseline.
      const invertY = usesPhoneCalibration(profile) && mapping.outputs[0] === 'lx' ? true : !!mapping.invertY;
      // Calibration reverses the profile's default direction when enabled.
      return { ...mapping, ...stick, invertX: !!mapping.invertX !== stick.invertX, invertY: invertY !== stick.invertY };
    }) });
  },
};
void calibration.load();
