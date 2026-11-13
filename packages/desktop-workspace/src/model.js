import { assertProfile, validateLayout, layoutLimits, BUTTONS, TRIGGERS, defaultProfile, builtInProfiles, desktopKeys, desktopLabels, keyChordLabel, mouseOutputs } from "../../controller/src/index.js";

export const copy = value => JSON.parse(JSON.stringify(value));
export const signature = value => JSON.stringify(value, (_key, item) => item && typeof item === 'object' && !Array.isArray(item) ? Object.fromEntries(Object.keys(item).sort().map(key => [key, item[key]])) : item);
export const canvasSize = { width: 844, height: 390 };
export const outputNames = { ...desktopLabels, 'mouse:left': 'Left click', 'mouse:right': 'Right click', 'mouse:middle': 'Middle click', pointer: 'Trackpad', a: 'A', b: 'B', x: 'X', y: 'Y', lb: 'LB', rb: 'RB', lt: 'LT', rt: 'RT', ls: 'L3', rs: 'R3', start: 'Menu', back: 'View', guide: 'Guide', up: 'D-pad up', down: 'D-pad down', left: 'D-pad left', right: 'D-pad right', lx: 'Move', rx: 'Look' };
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
  return type === 'key' ? [...desktopKeys] : type === 'mouse' ? [...mouseOutputs] : type === 'trackpad' ? ['pointer'] : type === 'stick' ? ['lx', 'rx'] : type === 'trigger' ? [...TRIGGERS] : [...BUTTONS];
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
  if (['stick', 'trigger'].includes(control.type) && profile.mappings.some(m => m.controlId !== id && m.outputs.some(o => target.includes(o)))) throw Error('That analog output is already assigned.');
  return keyLabel({ ...profile, mappings: profile.mappings.map(mapping => mapping.controlId === id ? { ...mapping, ...settings, outputs: target } : mapping) }, id);
}
/** A key control's face names the keys it presses unless the player renamed it. */
function keyLabel(profile, id) {
  const outputs = profile.mappings.find(mapping => mapping.controlId === id)?.outputs ?? [];
  return { ...profile, controls: profile.controls.map(control => control.id === id && control.type === 'key' && control.customLabel === undefined ? { ...control, label: keyChordLabel(outputs) } : control) };
}

export function removeControl(profile, id) {
  if (profile.controls.length <= 1) throw Error('Keep at least one control.');
  return { ...profile, controls: profile.controls.filter(c => c.id !== id), mappings: profile.mappings.filter(m => m.controlId !== id) };
}

export function addControl(profile, type, id, viewport = canvasSize) {
  if (!['button', 'trigger', 'stick', 'key', 'mouse', 'trackpad'].includes(type)) throw Error('Unknown control type.');
  if (profile.controls.length >= 64) throw Error('A controller can have up to 64 controls.');
  let available = outputs(type);
  const used = new Set(profile.mappings.flatMap(m => m.outputs));
  if (['stick', 'trigger'].includes(type)) available = available.filter(o => !used.has(o));
  const output = available.find(o => !used.has(o)) ?? available[0];
  if (!output) throw Error('Both analog outputs are assigned. Remove or remap one first.');
  const side = ['stick', 'trackpad'].includes(type) ? 104 : 56;
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

export function setChord(profile, id, keys) {
  const next = keyLabel({ ...profile, mappings: profile.mappings.map(m => m.controlId === id ? { controlId: id, outputs: keys } : m) }, id);
  assertProfile(next); return next;
}
export const desktopProfile = {
  schemaVersion: 1, id: 'keyboard-mouse', name: 'Keyboard and mouse',
  controls: [
    { id: 'trackpad', type: 'trackpad', label: 'Trackpad', frame: { x: .35, y: .2, width: .58, height: .64 } },
    { id: 'left-click', type: 'mouse', label: 'Left click', frame: { x: .04, y: .4, width: .13, height: .2 } },
    { id: 'right-click', type: 'mouse', label: 'Right click', frame: { x: .19, y: .4, width: .13, height: .2 } },
    { id: 'space', type: 'key', label: 'Space', frame: { x: .04, y: .67, width: .28, height: .17 } },
  ],
  mappings: [{ controlId: 'trackpad', outputs: ['pointer'] },{ controlId: 'left-click', outputs: ['mouse:left'] },{ controlId: 'right-click', outputs: ['mouse:right'] },{ controlId: 'space', outputs: ['key:Space'] }],
};

/* ---- Studio helpers: grouping, structured layout checks, fixes, resizing ---- */
export const controlName = control => control.customLabel ?? control.label;
export const builtInIds = new Set(builtInProfiles.map(profile => profile.id));
/** Where a saved controller came from. Native entries only say whether they are editable. */
export function profileSource(entry) {
  if (entry.editable) return 'Yours';
  return builtInIds.has(entry.profile.id) ? 'Built in' : 'From your account';
}
export function controlGroup(control, mapping) {
  const output = mapping?.outputs[0];
  if (control.type === 'stick') return 'Sticks';
  if (['key', 'mouse', 'trackpad'].includes(control.type)) return 'Keys and mouse';
  if (control.type === 'trigger' || ['lb', 'rb'].includes(output)) return 'Shoulders';
  if (['a', 'b', 'x', 'y'].includes(output)) return 'Face buttons';
  if (['up', 'down', 'left', 'right'].includes(output)) return 'D-pad';
  return 'Other';
}
export const groupOrder = ['Sticks', 'Face buttons', 'D-pad', 'Shoulders', 'Keys and mouse', 'Other'];
/** Control types that can still be added without displacing an analog output. */
export function canAdd(profile, type) {
  if (profile.controls.length >= 64) return false;
  if (!['stick', 'trigger'].includes(type)) return true;
  const used = new Set(profile.mappings.flatMap(m => m.outputs));
  return outputs(type).some(output => !used.has(output));
}

const pt = (control, viewport) => {
  const f = controlBox(control, viewport);
  return { x: f.x * viewport.width, y: f.y * viewport.height, width: f.width * viewport.width, height: f.height * viewport.height };
};
/** Layout problems in player language, each tied to the controls involved. */
export function layoutProblems(profile, viewport = canvasSize) {
  let result;
  try { assertProfile(profile); result = validateLayout(profile, viewport); }
  catch (error) { return [{ code: 'invalid_profile', controls: [], title: error.message, detail: '' }]; }
  const byId = new Map(profile.controls.map(control => [control.id, control]));
  const problems = [];
  if (!profile.name.trim()) problems.push({ code: 'name', controls: [], title: 'Give this controller a name', detail: 'Names help you pick it on your phone.' });
  for (const error of result.errors) {
    const [first, second] = error.controls.map(id => byId.get(id));
    if (error.code === 'target_too_small' && first) {
      const box = pt(first, viewport), minimum = first.type === 'stick' ? layoutLimits.minimumStick : layoutLimits.minimumTarget;
      problems.push({ ...error, title: `${controlName(first)} is too small to hit`, detail: `${Math.round(box.width)} × ${Math.round(box.height)} pt. Touch areas need at least ${minimum} pt each way.` });
    } else if (error.code === 'overlapping_controls' && first && second) {
      problems.push({ ...error, title: `${controlName(first)} overlaps ${controlName(second)}`, detail: 'A press could hit both. Move one so the touch areas don’t touch.' });
    } else if (error.code === 'obscured_control' && first) {
      const area = /Chat/.test(error.message) ? 'Chat' : 'Thumble menu';
      problems.push({ ...error, area, title: `${controlName(first)} covers the ${area} button`, detail: `The top of the screen keeps space for ${area}.` });
    } else problems.push({ ...error, title: error.message, detail: '' });
  }
  return problems;
}
const problemsFor = (profile, id, viewport) => layoutProblems(profile, viewport).filter(problem => problem.controls.includes(id)).length;
const withFrame = (profile, id, frame) => updateControl(profile, id, { frame });
const fits = f => f.x >= 0 && f.y >= 0 && f.x + f.width <= 1 + 1e-9 && f.y + f.height <= 1 + 1e-9;
/** One-click repair for a problem, or null when only the player can decide. */
export function suggestFix(profile, problem, viewport = canvasSize) {
  const id = problem.controls.at(-1), control = profile.controls.find(c => c.id === id);
  if (!control) return null;
  const f = control.frame, W = viewport.width, H = viewport.height;
  const best = (candidates) => {
    const scored = candidates.filter(c => fits(c.frame)).map(c => ({ ...c, profile: withFrame(profile, id, c.frame) })).map(c => ({ ...c, count: problemsFor(c.profile, id, viewport) }));
    scored.sort((a, b) => a.count - b.count || a.cost - b.cost);
    return scored[0] && scored[0].count < problemsFor(profile, id, viewport) ? { label: scored[0].label, profile: scored[0].profile } : null;
  };
  if (problem.code === 'target_too_small') {
    const minimum = (control.type === 'stick' ? layoutLimits.minimumStick : layoutLimits.minimumTarget) + 0.5;
    const width = Math.max(f.width, minimum / W), height = Math.max(f.height, minimum / H);
    const x = Math.min(Math.max(0, f.x - (width - f.width) / 2), 1 - width), y = Math.min(Math.max(0, f.y - (height - f.height) / 2), 1 - height);
    const frame = { x, y, width, height };
    return { label: `Enlarge to ${Math.round(width * W)} × ${Math.round(height * H)}`, profile: withFrame(profile, id, frame) };
  }
  // Move the control the shortest distance that clears it. Steps are in points.
  const candidates = [];
  for (let step = 4; step <= 240; step += 4) {
    for (const [dx, dy, word] of [[-step, 0, 'left'], [step, 0, 'right'], [0, step, 'down'], [0, -step, 'up']]) {
      candidates.push({ cost: step, label: `Move ${controlName(control)} ${word} ${step} pt`, frame: { ...f, x: f.x + dx / W, y: f.y + dy / H } });
    }
  }
  return best(candidates);
}
/** Resize from any corner while keeping the opposite corner fixed. */
export function resizeControl(profile, id, corner, dx, dy, viewport = canvasSize) {
  const control = profile.controls.find(item => item.id === id);
  if (!control) return profile;
  const f = control.frame, minW = (control.type === 'stick' ? 96 : 48) / viewport.width, minH = (control.type === 'stick' ? 96 : 48) / viewport.height;
  let left = f.x, top = f.y, right = f.x + f.width, bottom = f.y + f.height;
  if (corner.includes('w')) left = clamp(left + dx, 0, right - minW); else right = clamp(right + dx, left + minW, 1);
  if (corner.includes('n')) top = clamp(top + dy, 0, bottom - minH); else bottom = clamp(bottom + dy, top + minH, 1);
  return updateControl(profile, id, { frame: { x: left, y: top, width: right - left, height: bottom - top } });
}
/** Snap a moving frame's edges and centre to other controls; returns guide lines in 0–1 space. */
export function snapFrame(profile, id, frame, viewport = canvasSize, tolerance = 4) {
  const tx = tolerance / viewport.width, ty = tolerance / viewport.height;
  const others = profile.controls.filter(c => c.id !== id).map(c => c.frame);
  const xs = others.flatMap(o => [o.x, o.x + o.width / 2, o.x + o.width]).concat([.5]);
  const ys = others.flatMap(o => [o.y, o.y + o.height / 2, o.y + o.height]);
  const pick = (points, values, limit) => {
    let found = null;
    for (const [offset] of points) for (const value of values) {
      const delta = value - offset;
      if (Math.abs(delta) <= limit && (!found || Math.abs(delta) < Math.abs(found.delta))) found = { delta, value };
    }
    return found;
  };
  const sx = pick([[frame.x], [frame.x + frame.width / 2], [frame.x + frame.width]], xs, tx);
  const sy = pick([[frame.y], [frame.y + frame.height / 2], [frame.y + frame.height]], ys, ty);
  const next = { ...frame, x: clamp(frame.x + (sx?.delta ?? 0), 0, 1 - frame.width), y: clamp(frame.y + (sy?.delta ?? 0), 0, 1 - frame.height) };
  return { frame: next, guides: { x: sx ? sx.value : null, y: sy ? sy.value : null } };
}
