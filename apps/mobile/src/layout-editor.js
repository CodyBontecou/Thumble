import { BUTTONS, TRIGGERS, desktopKeys, desktopLabels, keyChordLabel, keyModifiers, keyParts, layoutLimits, validateLayout } from '@tapping/controller';

const names = { back: 'View', start: 'Menu', guide: 'Guide', lb: 'Left bumper', rb: 'Right bumper', lt: 'Left trigger', rt: 'Right trigger', ls: 'Left stick click', rs: 'Right stick click', lx: 'Left stick', rx: 'Right stick', up: 'D-pad up', down: 'D-pad down', left: 'D-pad left', right: 'D-pad right', 'mouse:left': 'Left click', 'mouse:right': 'Right click', 'mouse:middle': 'Middle click', pointer: 'Trackpad' };
export const outputName = output => names[output] ?? desktopLabels[output] ?? output.toUpperCase();

/** "Hold with" toggles, in chord order. */
const modifierLabels = { 'key:ShiftLeft': 'Shift', 'key:ControlLeft': 'Ctrl', 'key:AltLeft': 'Alt / Option', 'key:MetaLeft': 'Win / Command' };
export const KEY_MODIFIERS = Object.freeze(keyModifiers.map(key => ({ key, label: modifierLabels[key] })));
const modifierKeys = keyModifiers;
/** The shared key registry split into pages a phone sheet can show. Every key
 * except the left-hand modifiers (offered as "Hold with" toggles) appears once. */
export const KEY_GROUPS = (() => {
  const pages = [
    { id: 'numbers', name: '1–0', pattern: /^key:Digit/ }, { id: 'letters', name: 'A–Z', pattern: /^key:Key[A-Z]$/ },
    { id: 'function', name: 'F1–F20', pattern: /^key:F\d+$/ }, { id: 'numpad', name: 'Numpad', pattern: /^key:Numpad/ },
  ].map(({ id, name, pattern }) => ({ id, name, keys: desktopKeys.filter(key => pattern.test(key)) }));
  const paged = new Set(pages.flatMap(page => page.keys));
  return Object.freeze([...pages, { id: 'other', name: 'Other', keys: desktopKeys.filter(key => !paged.has(key) && !modifierKeys.includes(key)) }]);
})();

export { keyParts };
export const chordLabel = keyChordLabel;
/** The first number key no other key control uses; number keys are the usual action-bar keys. */
function nextKey(profile) {
  const used = new Set(profile.mappings.flatMap(item => item.outputs));
  return desktopKeys.find(key => key.startsWith('key:Digit') && !used.has(key)) ?? desktopKeys.find(key => !used.has(key) && !modifierKeys.includes(key)) ?? 'key:Digit1';
}

function setKeys(profile, id, outputs) {
  const { modifiers, main } = keyParts(outputs);
  const keys = [...modifiers, ...main];
  if (!keys.length || keys.length > 6 || new Set(keys).size !== keys.length || keys.some(key => !desktopKeys.includes(key))) return profile;
  return {
    ...profile,
    mappings: profile.mappings.map(item => item.controlId === id ? { controlId: id, outputs: keys } : item),
    controls: profile.controls.map(item => item.id === id ? { ...item, label: chordLabel(keys) } : item),
  };
}
/** Makes `key` the key this control presses, keeping any held modifiers. */
export function pickKey(profile, id, key) {
  const control = profile.controls.find(item => item.id === id);
  const mapping = profile.mappings.find(item => item.controlId === id);
  if (control?.type !== 'key' || !mapping || modifierKeys.includes(key)) return profile;
  return setKeys(profile, id, [...keyParts(mapping.outputs).modifiers, key]);
}
/** Adds or removes a held modifier. A control always keeps at least one key. */
export function toggleModifier(profile, id, modifier) {
  const control = profile.controls.find(item => item.id === id);
  const mapping = profile.mappings.find(item => item.controlId === id);
  if (control?.type !== 'key' || !mapping || !modifierKeys.includes(modifier)) return profile;
  return setKeys(profile, id, mapping.outputs.includes(modifier) ? mapping.outputs.filter(key => key !== modifier) : [...mapping.outputs, modifier]);
}
/** Switches a button between sending a gamepad button and a keyboard key.
 * Gamepad artwork and colours belong to gamepad outputs, so a key drops them;
 * a button returning to the gamepad takes its new output's artwork. */
export function setControlKind(profile, id, kind) {
  const control = profile.controls.find(item => item.id === id);
  if (!control || id === 'chat') return profile;
  if (kind === 'keyboard' && control.type === 'button') {
    const outputs = [nextKey(profile)];
    const { icon: _icon, layers: _layers, badge: _badge, color: _color, ...rest } = control;
    return {
      ...profile,
      controls: profile.controls.map(item => item.id === id ? { ...rest, type: 'key', label: chordLabel(outputs) } : item),
      mappings: profile.mappings.map(item => item.controlId === id ? { controlId: id, outputs } : item),
    };
  }
  if (kind === 'gamepad' && control.type === 'key') {
    const owned = new Set(profile.mappings.filter(item => item.controlId !== id).flatMap(item => item.outputs));
    const output = BUTTONS.find(button => !owned.has(button)) ?? BUTTONS[0];
    const asButton = { ...profile, controls: profile.controls.map(item => item.id === id ? { ...item, type: 'button' } : item) };
    return changeOutput(asButton, id, [output]);
  }
  return profile;
}

export function availableOutputs(profile, control) {
  if (['key', 'mouse', 'trackpad'].includes(control.type)) return [profile.mappings.find(item => item.controlId === control.id).outputs];
  const options = control.type === 'stick' ? [['lx', 'ly'], ['rx', 'ry']]
    : (control.type === 'trigger' ? TRIGGERS : BUTTONS).map(output => [output]);
  if (control.type === 'button') return options;
  const owned = new Set(profile.mappings.filter(item => item.controlId !== control.id).flatMap(item => item.outputs));
  return options.filter(([output]) => !owned.has(output));
}

export function changeOutput(profile, id, outputs) {
  const previous = profile.mappings.find(item => item.controlId === id);
  if (previous?.outputs[0] === outputs[0]) return profile;
  const donor = profile.mappings.find(item => item.outputs[0] === outputs[0] && item.controlId !== 'chat');
  const artwork = profile.controls.find(item => item.id === donor?.controlId);
  return {
    ...profile,
    mappings: profile.mappings.map(item => item.controlId === id ? { ...item, outputs } : item),
    controls: profile.controls.map(item => {
      if (item.id !== id) return item;
      const { icon: _icon, layers: _layers, badge: _badge, color: _color, ...control } = item;
      return { ...control, label: artwork?.label ?? outputName(outputs[0]),
        ...(artwork?.color && { color: artwork.color }), ...(artwork?.icon && { icon: artwork.icon }), ...(artwork?.layers && { layers: artwork.layers }),
        ...(profile.theme === 'consoleport' && { badge: artwork?.badge ?? outputs[0].toUpperCase() }) };
    }),
  };
}

const clamp = (value, min, max) => Math.min(max, Math.max(min, value));
export function editFrame(frame, dx, dy, resize, viewport, type = 'button') {
  if (resize) {
    const minimum = type === 'stick' ? layoutLimits.minimumStick : layoutLimits.minimumTarget;
    const minWidth = Math.min(1, minimum / viewport.width), minHeight = Math.min(1, minimum / viewport.height);
    const width = clamp(frame.width + dx, minWidth, Math.max(minWidth, 1 - frame.x));
    const height = clamp(frame.height + dy, minHeight, Math.max(minHeight, 1 - frame.y));
    return { ...frame, width, height, x: Math.min(frame.x, 1 - width), y: Math.min(frame.y, 1 - height) };
  }
  return { ...frame, x: clamp(frame.x + dx, 0, 1 - frame.width), y: clamp(frame.y + dy, 0, 1 - frame.height) };
}

export function addControl(profile, id, viewport, type = 'button') {
  const side = (type === 'stick' ? layoutLimits.minimumStick : layoutLimits.minimumTarget) + 8;
  const width = side / viewport.width, height = side / viewport.height;
  if (width > 1 || height > 1 || profile.controls.length >= 64) return profile;
  const options = type === 'key' ? [[nextKey(profile)]] : availableOutputs(profile, { id, type });
  const outputs = options.find(([key]) => !profile.mappings.some(mapping => mapping.outputs.includes(key))) ?? options[0];
  if (!outputs) return profile;
  const donor = profile.controls.find(control => control.id !== 'chat' && profile.mappings.some(mapping => mapping.controlId === control.id && mapping.outputs[0] === outputs[0]));
  const artwork = type === 'button' && donor ? { label: donor.label, ...(donor.icon && { icon: donor.icon }), ...(donor.layers && { layers: donor.layers }), ...(donor.badge && { badge: donor.badge }) } : { label: outputName(outputs[0]) };
  const mappings = [...profile.mappings, { controlId: id, outputs }];
  const place = (x, y) => ({ ...profile, mappings, controls: [...profile.controls, { id, type, ...artwork, frame: { x, y, width, height } }] });
  for (let y = 56; y + side <= viewport.height; y += 8) {
    for (let x = 0; x + side <= viewport.width; x += 8) {
      const candidate = place(x / viewport.width, y / viewport.height);
      if (!validateLayout(candidate, viewport).errors.some(issue => issue.controls.includes(id))) return candidate;
    }
  }
  return profile;
}

const SHOULDERS = new Set(['lt', 'lb', 'rb', 'rt']);
/**
 * Mirror a layout left-to-right so movement sits under the right thumb.
 * Bumpers and triggers stay on their own sides, which also keeps them clear of
 * the menu corner.
 */
const KEEP_ORDER = [['left', 'right'], ['x', 'b'], ['back', 'start']];
export function mirrorProfile(profile, id, name) {
  const mirrored = profile.controls.map(control => SHOULDERS.has(control.id) ? control
    : ({ ...control, frame: { ...control.frame, x: Math.max(0, Math.min(1 - control.frame.width, 1 - control.frame.x - control.frame.width)) } }));
  // Pairs read left-to-right (← →, X B, View Menu) keep that order after mirroring.
  const frames = new Map(mirrored.map(control => [control.id, control.frame]));
  for (const [first, second] of KEEP_ORDER) if (frames.has(first) && frames.has(second)) {
    const a = frames.get(first), b = frames.get(second);
    frames.set(first, b); frames.set(second, a);
  }
  return { ...profile, id, name, controls: mirrored.map(control => ({ ...control, frame: frames.get(control.id) })) };
}
/** Starting points offered by the onboarding tour. */
export const TOUR_PRESETS = [
  { id: 'xbox', name: 'Xbox', detail: 'The default. Works with most controller games.' },
  { id: 'lefty', name: 'Left-handed', detail: 'Sticks and buttons swap sides.' },
  { id: 'consoleport', name: 'ConsolePort', detail: 'For World of Warcraft. Spell labels sync via the addon.' },
];
/** @param {string} id @param {{ xbox: any, consoleport: any }} builtins */
export function presetProfile(id, builtins) {
  if (id === 'lefty') return mirrorProfile(builtins.xbox, 'xbox-left-handed', 'Left-handed');
  if (id === 'consoleport') return builtins.consoleport;
  return builtins.xbox;
}
