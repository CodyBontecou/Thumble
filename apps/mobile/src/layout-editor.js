import { BUTTONS, TRIGGERS, layoutLimits, validateLayout } from '@tapping/controller';

const names = { back: 'View', start: 'Menu', guide: 'Guide', lb: 'Left bumper', rb: 'Right bumper', lt: 'Left trigger', rt: 'Right trigger', ls: 'Left stick click', rs: 'Right stick click', lx: 'Left stick', rx: 'Right stick', up: 'D-pad up', down: 'D-pad down', left: 'D-pad left', right: 'D-pad right' };
export const outputName = output => names[output] ?? output.toUpperCase();

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
      const { icon: _icon, layers: _layers, badge: _badge, ...control } = item;
      return { ...control, label: artwork?.label ?? outputName(outputs[0]),
        ...(artwork?.icon && { icon: artwork.icon }), ...(artwork?.layers && { layers: artwork.layers }),
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
  const options = availableOutputs(profile, { id, type });
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
