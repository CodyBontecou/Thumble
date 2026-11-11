import { assertProfile, validateLayout, BUTTONS, TRIGGERS, defaultProfile } from '../../controller/src/index.js';

export const copy = value => JSON.parse(JSON.stringify(value));
export const signature = value => JSON.stringify(value, (_key, item) => item && typeof item === 'object' && !Array.isArray(item) ? Object.fromEntries(Object.keys(item).sort().map(key => [key, item[key]])) : item);
export const canvasSize = { width: 844, height: 390 };
export const outputNames = { a: 'A', b: 'B', x: 'X', y: 'Y', lb: 'LB', rb: 'RB', lt: 'LT', rt: 'RT', ls: 'L3', rs: 'R3', start: 'Menu', back: 'View', guide: 'Guide', up: 'D-pad up', down: 'D-pad down', left: 'D-pad left', right: 'D-pad right', lx: 'Move', rx: 'Look' };
export const acknowledged = snapshot => !!snapshot?.receiver.running && !!snapshot.receiver.connected && !!snapshot.receiver.layoutAcknowledged && snapshot.receiver.revision === snapshot.activationRevision;
export function profileState(entry, snapshot) {
  if (snapshot.active?.profile.id !== entry.profile.id) return 'saved';
  return snapshot.active.profileRevision === entry.revision ? 'selected' : 'draft';
}
export function labelColor(color = '#3c473d') {
  const channels = color.slice(1).match(/../g).map(hex => parseInt(hex, 16) / 255).map(value => value <= .04045 ? value / 12.92 : ((value + .055) / 1.055) ** 2.4);
  const luminance = channels[0] * .2126 + channels[1] * .7152 + channels[2] * .0722;
  return luminance > .179 ? '#000000' : '#ffffff';
}
export function controlBox(control, viewport = canvasSize) {
  const f = control.frame;
  if (control.type !== 'stick') return f;
  const side = Math.min(f.width * viewport.width, f.height * viewport.height);
  const width = side / viewport.width, height = side / viewport.height;
  return { x: f.x+(f.width-width)/2, y: f.y+(f.height-height)/2, width, height };
}
const clamp = (n, low, high) => Math.min(high, Math.max(low, n));

export function issues(profile, viewport = canvasSize) {
  try {
    assertProfile(profile);
    if (!profile.name.trim()) return ['Give this controller a name.'];
    return validateLayout(profile, viewport).errors.map(issue => issue.message);
  } catch (error) { return [error.message]; }
}

export function outputs(type) {
  return type === 'stick' ? ['lx', 'rx'] : type === 'trigger' ? [...TRIGGERS] : [...BUTTONS];
}

export function newProfile(id, source = defaultProfile) {
  const profile = copy(source);
  profile.id = id;
  profile.name = `${source.name} copy`.slice(0, 80);
  return profile;
}

export function updateControl(profile, id, patch) {
  return { ...profile, controls: profile.controls.map(control => control.id === id ? { ...control, ...patch } : control) };
}

export function moveControl(profile, id, dx, dy, resize = false, viewport = canvasSize) {
  const control = profile.controls.find(item => item.id === id);
  if (!control) return profile;
  const f = control.frame;
  const minimum = control.type === 'stick' ? 96 : 48;
  const frame = resize
    ? { ...f, width: clamp(f.width + dx, minimum / viewport.width, 1 - f.x), height: clamp(f.height + dy, minimum / viewport.height, 1 - f.y) }
    : { ...f, x: clamp(f.x + dx, 0, 1 - f.width), y: clamp(f.y + dy, 0, 1 - f.height) };
  return updateControl(profile, id, { frame });
}

export function setOutput(profile, id, output, settings = {}) {
  const control = profile.controls.find(item => item.id === id);
  if (!control || !outputs(control.type).includes(output)) throw Error('Choose a compatible gamepad output.');
  const target = control.type === 'stick' ? [output, output === 'lx' ? 'ly' : 'ry'] : [output];
  if (control.type !== 'button' && profile.mappings.some(m => m.controlId !== id && m.outputs.some(o => target.includes(o)))) throw Error('That analog output is already assigned.');
  return { ...profile, mappings: profile.mappings.map(mapping => mapping.controlId === id ? { ...mapping, ...settings, outputs: target } : mapping) };
}

export function removeControl(profile, id) {
  if (profile.controls.length <= 1) throw Error('Keep at least one control.');
  return { ...profile, controls: profile.controls.filter(c => c.id !== id), mappings: profile.mappings.filter(m => m.controlId !== id) };
}

export function addControl(profile, type, id, viewport = canvasSize) {
  if (!['button', 'trigger', 'stick'].includes(type)) throw Error('Unknown control type.');
  if (profile.controls.length >= 64) throw Error('A controller can have up to 64 controls.');
  let available = outputs(type);
  const used = new Set(profile.mappings.flatMap(m => m.outputs));
  if (type !== 'button') available = available.filter(o => !used.has(o));
  const output = available.find(o => !used.has(o)) ?? available[0];
  if (!output) throw Error('Both analog outputs are assigned. Remove or remap one first.');
  const side = type === 'stick' ? 104 : 56;
  for (let y = 56; y + side <= viewport.height; y += 8) {
    for (let x = 0; x + side <= viewport.width; x += 8) {
      const control = { id, type, label: outputNames[output], frame: { x: x / viewport.width, y: y / viewport.height, width: side / viewport.width, height: side / viewport.height } };
      const mapping = { controlId: id, outputs: type === 'stick' ? [output, output === 'lx' ? 'ly' : 'ry'] : [output] };
      const candidate = { ...profile, controls: [...profile.controls, control], mappings: [...profile.mappings, mapping] };
      if (!issues(candidate, viewport).length) return candidate;
    }
  }
  throw Error('No clear space for this control. Move or remove another control first.');
}

export class Editor {
  constructor(profile, revision = 0) { this.load(profile, revision); }
  load(profile, revision) {
    this.profile = copy(profile); this.saved = copy(profile); this.revision = revision;
    this.past = []; this.future = []; this.selected = null;
  }
  get dirty() { return signature(this.profile) !== signature(this.saved); }
  commit(profile) {
    if (signature(profile) === signature(this.profile)) return;
    this.past.push(copy(this.profile)); if (this.past.length > 100) this.past.shift();
    this.profile = copy(profile); this.future = [];
  }
  undo() { if (this.past.length) { this.future.push(this.profile); this.profile = this.past.pop(); } }
  redo() { if (this.future.length) { this.past.push(this.profile); this.profile = this.future.pop(); } }
  markSaved(revision) { this.saved = copy(this.profile); this.revision = revision; }
}
