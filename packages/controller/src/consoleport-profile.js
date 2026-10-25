import { xboxProfile } from './xbox-profile.js';

// Generic ConsolePort arrangement. Only a character export can supply WoW action labels.
const frames = {
  'left-stick': [.24, .57, .20, .40], 'right-stick': [.56, .57, .20, .40],
  up: [.105, .05, .09, .22], left: [.005, .29, .09, .22],
  right: [.205, .29, .09, .22], down: [.105, .53, .09, .22],
  y: [.805, .05, .09, .22], x: [.705, .29, .09, .22],
  b: [.905, .29, .09, .22], a: [.805, .53, .09, .22],
  lb: [.33, .05, .09, .16], rb: [.58, .05, .09, .16],
  lt: [.33, .30, .09, .18], rt: [.58, .30, .09, .18],
  start: [.455, .40, .09, .16], back: [.455, .73, .09, .16],
  ls: [.035, .77, .09, .16], rs: [.875, .77, .09, .16],
};
const badges = { up: '↑', down: '↓', left: '←', right: '→' };
export const consolePortProfile = Object.freeze({
  schemaVersion: 1,
  id: 'consoleport-standard',
  name: 'ConsolePort controller',
  theme: 'consoleport',
  controls: Object.freeze(xboxProfile.controls.map(control => {
    const [x, y, width, height] = frames[control.id];
    return Object.freeze({ ...control, ...(control.type !== 'stick' ? { badge: badges[control.id] ?? control.label } : {}), frame: Object.freeze({ x, y, width, height }) });
  })),
  // ConsolePort movement uses negative Y for forward.
  mappings: Object.freeze(xboxProfile.mappings.map(mapping => mapping.controlId === 'left-stick'
    ? Object.freeze({ ...mapping, invertY: true }) : mapping)),
});
