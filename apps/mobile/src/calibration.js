import { requireOptionalNativeModule } from 'expo-modules-core';
import { assertProfile, defaultProfile } from '@tapping/controller';
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
    return assertProfile({ ...profile, mappings: profile.mappings.map(mapping => ({ ...mapping, ...(mapping.controlId === 'left-stick' ? value.left : mapping.controlId === 'right-stick' ? value.right : {}) })) });
  },
};
void calibration.load();
