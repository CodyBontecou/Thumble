import { BUTTONS } from './controller.js';

/** Presentation follows the player's held modifier outputs; it never emits input. */
export function modifierPrefix(profile, state) {
  const held = key => key === 'lt' || key === 'rt' ? state[key] > 0.5 : BUTTONS.includes(key) && !!(state.buttons & (1 << BUTTONS.indexOf(key)));
  // Without a character export we know the physical chord, not WoW's
  // Shift/Ctrl assignments or spells. Keep that fallback explicit.
  if (profile.theme === 'consoleport' && profile.modifiers === undefined) {
    return ['lt', 'rt'].filter(held).map(key => `${key.toUpperCase()}-`).join('');
  }
  return [['alt', 'ALT-'], ['ctrl', 'CTRL-'], ['shift', 'SHIFT-']].filter(([name]) => held(profile.modifiers?.[name])).map(([, prefix]) => prefix).join('');
}
export function controlDisplay(control, prefix, profile) {
  const output = profile?.mappings.find(mapping => mapping.controlId === control.id)?.outputs[0];
  if (prefix && profile?.theme === 'consoleport' && profile.modifiers === undefined &&
      ['a', 'b', 'x', 'y', 'up', 'down', 'left', 'right', 'lb', 'rb'].includes(output)) {
    return { label: `${prefix.replace(/-/g, ' + ')}${control.badge ?? control.label}` };
  }
  for (const [name, key] of Object.entries(profile?.modifiers ?? {})) {
    if (key !== 'none' && key === output) prefix = prefix.replace(`${name.toUpperCase()}-`, '');
  }
  return control.layers?.[prefix] ?? { label: control.label, icon: control.icon };
}
