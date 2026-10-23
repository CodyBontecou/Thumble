import { BUTTONS } from './controller.js';

/** Presentation follows the player's held modifier outputs; it never emits input. */
export function modifierPrefix(profile, state) {
  const held = key => key === 'lt' || key === 'rt' ? state[key] > 0.5 : BUTTONS.includes(key) && !!(state.buttons & (1 << BUTTONS.indexOf(key)));
  return [['alt', 'ALT-'], ['ctrl', 'CTRL-'], ['shift', 'SHIFT-']].filter(([name]) => held(profile.modifiers?.[name])).map(([, prefix]) => prefix).join('');
}
export function controlDisplay(control, prefix, profile) {
  const output = profile?.mappings.find(mapping => mapping.controlId === control.id)?.outputs[0];
  for (const [name, key] of Object.entries(profile?.modifiers ?? {})) {
    if (key !== 'none' && key === output) prefix = prefix.replace(`${name.toUpperCase()}-`, '');
  }
  return control.layers?.[prefix] ?? { label: control.label, icon: control.icon };
}
