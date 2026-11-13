import definitions from './desktop-keys.json' with { type: 'json' };

export const desktopKeys = Object.freeze(definitions.map(key => `key:${key.code}`));
export const desktopLabels = Object.freeze(Object.fromEntries(definitions.map(key => [`key:${key.code}`, key.label])));
export const mouseOutputs = Object.freeze(['mouse:left', 'mouse:right', 'mouse:middle']);
export const desktopTypes = Object.freeze(['key', 'mouse', 'trackpad']);
export const hasDesktopInput = profile => profile?.controls.some(control => desktopTypes.includes(control.type));
export const neutralDesktop = () => ({ keys: [], buttons: 0, x: 0, y: 0, scrollX: 0, scrollY: 0 });
export const isNeutralInput = state => !state.buttons && !state.lx && !state.ly && !state.rx && !state.ry && !state.lt && !state.rt && (!state.desktop || (!state.desktop.keys.length && !state.desktop.buttons && !state.desktop.x && !state.desktop.y && !state.desktop.scrollX && !state.desktop.scrollY));
/** Left-hand modifiers a key control holds with its main key, in label order. */
const modifierNames = { 'key:ShiftLeft': 'Shift', 'key:ControlLeft': 'Ctrl', 'key:AltLeft': 'Alt', 'key:MetaLeft': 'Cmd' };
export const keyModifiers = Object.freeze(Object.keys(modifierNames));
/** Splits a key mapping into held modifiers (label order) and the keys they modify. */
export const keyParts = outputs => ({ modifiers: keyModifiers.filter(key => outputs.includes(key)), main: outputs.filter(key => !keyModifiers.includes(key)) });
/** Short button-face label for a key mapping, such as "Shift+1". */
export function keyChordLabel(outputs) {
  const { modifiers, main } = keyParts(outputs);
  return [...modifiers.map(key => modifierNames[key]), ...main.map(key => desktopLabels[key] ?? key)].join('+');
}
