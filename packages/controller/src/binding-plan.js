import { gamepadKeys } from './gamepad-keys.js';

export const utilityActions = ['JUMP', 'OPENCHAT', 'TARGETNEARESTENEMY', 'TARGETPREVIOUSENEMY', 'TARGETSELF', 'OPENALLBAGS', 'TOGGLEWORLDMAP', 'TOGGLECHARACTER0', 'TOGGLEGAMEMENU', 'INTERACTTARGET'];

/** Declarative proposal only. The addon rechecks live game context on Apply. */
export function bindingChange(snapshot, profile, intent) {
  const control = profile.controls.find(item => item.id === intent.controlId);
  const mapping = profile.mappings.find(item => item.controlId === intent.controlId);
  if (!control || !['button', 'trigger'].includes(control.type) || !mapping || mapping.outputs.length !== 1) throw Error('Choose a gamepad button or trigger.');
  const key = gamepadKeys[mapping.outputs[0]];
  if (!key || snapshot.reserved[key]) throw Error(`${key ?? 'This output'} is reserved for ${snapshot.reserved[key] ?? 'the controller'}.`);
  const binding = snapshot.bindings.find(item => item.key === key);
  if (!binding) throw Error('Reload WoW to export this button’s binding.');
  const proxy = binding.consolePortProxy === true && binding.effective === `CLICK CPB_${key}:ControllerInput` && /^(?:ACTIONBUTTON\d+|MULTIACTIONBAR\d+BUTTON\d+)$/.test(binding.base);
  if (binding.base !== binding.effective && !proxy) throw Error(`${key} has an override binding. Resolve it in ConsolePort first.`);
  let label;
  if (intent.spellId !== undefined && intent.action === undefined) {
    const spell = snapshot.spells.find(item => item.id === intent.spellId && !item.passive);
    if (!spell || !Number.isSafeInteger(spell.id) || spell.id < 1 || spell.id >= 2147483648) throw Error(`Spell ${intent.spellId} is not an available learned spell.`);
    label = spell.name;
  } else {
    if (intent.spellId !== undefined || !utilityActions.includes(intent.action)) throw Error('Intent must name one learned spellId or supported utility action.');
    label = intent.action === 'JUMP' ? 'Jump' : intent.action === 'OPENCHAT' ? 'Chat' : control.label;
  }
  label = intent.label ?? (label.length <= 80 ? label : control.label);
  if (typeof label !== 'string' || !label.length || label.length > 80 || /[\x00-\x1f\x7f|]/.test(label)) throw Error('Use a plain label of 1–80 characters.');
  return { controlId: control.id, label, key, expectedBase: binding.base, expectedEffective: binding.effective,
    ...(intent.spellId !== undefined ? { spellId: intent.spellId } : { action: intent.action }) };
}
