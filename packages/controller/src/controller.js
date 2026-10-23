// Portable JavaScript: this module runs in Hermes, Node, and local MCP tools.
export const BUTTONS = Object.freeze([
  'a', 'b', 'x', 'y', 'lb', 'rb', 'back', 'start',
  'ls', 'rs', 'up', 'down', 'left', 'right', 'guide',
]);
export const AXES = Object.freeze(['lx', 'ly', 'rx', 'ry']);
export const TRIGGERS = Object.freeze(['lt', 'rt']);
const OUTPUTS = Object.freeze([...BUTTONS, ...AXES, ...TRIGGERS]);
const TYPES = Object.freeze(['button', 'stick', 'trigger']);

const record = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const finite = (value, min, max) => Number.isFinite(value) && value >= min && value <= max;
const shortText = value => typeof value === 'string' && value.length > 0 && value.length <= 80;
const onlyKeys = (value, keys) => Object.keys(value).every(key => keys.includes(key));

/** Returns field errors without executing code supplied by a controller profile. */
export function validateProfile(profile) {
  const errors = [];
  if (!record(profile)) return ['profile must be an object'];
  if (!onlyKeys(profile, ['schemaVersion', 'id', 'name', 'controls', 'mappings', 'theme', 'modifiers'])) errors.push('profile has unknown fields');
  if (profile.theme !== undefined && profile.theme !== 'consoleport') errors.push('unsupported profile theme');
  if (profile.modifiers !== undefined && (!record(profile.modifiers) || !onlyKeys(profile.modifiers, ['shift', 'ctrl', 'alt']) || Object.values(profile.modifiers).some(value => ![...BUTTONS, ...TRIGGERS, 'none'].includes(value)))) errors.push('invalid modifier outputs');
  if (profile.schemaVersion !== 1) errors.push('schemaVersion must be 1');
  if (typeof profile.id !== 'string' || !/^[a-z0-9][a-z0-9-]{0,63}$/.test(profile.id)) errors.push('id must be a lowercase slug');
  if (!shortText(profile.name)) errors.push('name must contain 1–80 characters');
  if (!Array.isArray(profile.controls) || profile.controls.length < 1 || profile.controls.length > 64) {
    errors.push('controls must contain 1–64 controls');
    return errors;
  }
  const ids = new Map();
  Array.from(profile.controls).forEach((control, index) => {
    const path = `controls[${index}]`;
    if (!record(control)) { errors.push(`${path} must be an object`); return; }
    if (!onlyKeys(control, ['id', 'type', 'label', 'frame', 'color', 'icon', 'badge', 'layers'])) errors.push(`${path} has unknown fields`);
    const icon = value => typeof value === 'string' && /^[a-z0-9_]{1,128}$/.test(value);
    if (control.icon !== undefined && !icon(control.icon)) errors.push(`${path}.icon must be a WoW icon name`);
    if (control.badge !== undefined && !shortText(control.badge)) errors.push(`${path}.badge is invalid`);
    if (control.layers !== undefined) {
      const mods = ['', 'SHIFT-', 'CTRL-', 'ALT-', 'CTRL-SHIFT-', 'ALT-SHIFT-', 'ALT-CTRL-', 'ALT-CTRL-SHIFT-'];
      if (!record(control.layers) || !onlyKeys(control.layers, mods) || Object.values(control.layers).some(layer => !record(layer) || !onlyKeys(layer, ['label', 'icon']) || !shortText(layer.label) || (layer.icon !== undefined && !icon(layer.icon)))) errors.push(`${path}.layers are invalid`);
    }
    if (!shortText(control.id) || ids.has(control.id)) errors.push(`${path}.id must be unique and contain 1–80 characters`);
    else ids.set(control.id, control.type);
    if (!TYPES.includes(control.type)) errors.push(`${path}.type is unsupported`);
    if (!shortText(control.label)) errors.push(`${path}.label must contain 1–80 characters`);
    if (control.color !== undefined && (typeof control.color !== 'string' || !/^#[0-9a-f]{6}$/i.test(control.color))) errors.push(`${path}.color must be a hex RGB color`);
    const frame = control.frame;
    if (!record(frame) || !onlyKeys(frame, ['x', 'y', 'width', 'height']) ||
        !finite(frame.x, 0, 1) || !finite(frame.y, 0, 1) ||
        !finite(frame.width, 0.01, 1) || !finite(frame.height, 0.01, 1) ||
        frame.x + frame.width > 1.000001 || frame.y + frame.height > 1.000001) {
      errors.push(`${path}.frame must fit inside the normalized safe-area canvas`);
    }
  });
  if (!Array.isArray(profile.mappings) || profile.mappings.length > 64) {
    errors.push('mappings must be an array with at most 64 entries');
    return errors;
  }
  const mapped = new Set();
  Array.from(profile.mappings).forEach((mapping, index) => {
    const path = `mappings[${index}]`;
    if (!record(mapping)) { errors.push(`${path} must be an object`); return; }
    if (!onlyKeys(mapping, ['controlId', 'outputs', 'deadzone', 'sensitivity', 'invertX', 'invertY'])) errors.push(`${path} has unknown fields`);
    const type = ids.get(mapping.controlId);
    if (!type || mapped.has(mapping.controlId)) errors.push(`${path}.controlId must reference one previously unmapped control`);
    mapped.add(mapping.controlId);
    const outputs = mapping.outputs;
    if (!Array.isArray(outputs) || !outputs.every(output => OUTPUTS.includes(output))) {
      errors.push(`${path}.outputs must contain supported gamepad outputs`);
      return;
    }
    if (type === 'button' && (outputs.length !== 1 || !BUTTONS.includes(outputs[0]))) errors.push(`${path} must map a button to one gamepad button`);
    if (type === 'trigger' && (outputs.length !== 1 || !TRIGGERS.includes(outputs[0]))) errors.push(`${path} must map a trigger to one gamepad trigger`);
    if (type === 'stick' && !(outputs.length === 2 && ((outputs[0] === 'lx' && outputs[1] === 'ly') || (outputs[0] === 'rx' && outputs[1] === 'ry')))) errors.push(`${path} must map a stick to [lx, ly] or [rx, ry]`);
    if (mapping.deadzone !== undefined && (type !== 'stick' || !finite(mapping.deadzone, 0, 0.5))) errors.push(`${path}.deadzone must be 0–0.5 on a stick`);
    if (mapping.sensitivity !== undefined && (type !== 'stick' || !finite(mapping.sensitivity, 0.1, 3))) errors.push(`${path}.sensitivity must be 0.1–3 on a stick`);
    for (const axis of ['invertX', 'invertY']) if (mapping[axis] !== undefined && (type !== 'stick' || typeof mapping[axis] !== 'boolean')) errors.push(`${path}.${axis} must be a boolean on a stick`);
  });
  for (const id of ids.keys()) if (!mapped.has(id)) errors.push(`control ${id} needs a mapping`);
  // A button may have several physical touch sources. Analog outputs have one owner.
  const analogOwners = new Set();
  for (const mapping of profile.mappings) {
    if (!Array.isArray(mapping?.outputs)) continue;
    for (const output of mapping.outputs) {
      if (!AXES.includes(output) && !TRIGGERS.includes(output)) continue;
      if (analogOwners.has(output)) errors.push(`analog output ${output} has more than one owner`);
      analogOwners.add(output);
    }
  }
  return errors;
}

export function assertProfile(profile) {
  const errors = validateProfile(profile);
  if (errors.length) throw new TypeError(errors.join('; '));
  // Copy on entry so an MCP edit cannot mutate the active profile in place.
  return JSON.parse(JSON.stringify(profile));
}

export function neutralState() {
  return { buttons: 0, lx: 0, ly: 0, rx: 0, ry: 0, lt: 0, rt: 0 };
}

/** Radial deadzone preserves direction; canonical positive Y points upward. */
export function normalizeStick(x, y, deadzone = 0.12, sensitivity = 1) {
  if (!finite(x, -1, 1) || !finite(y, -1, 1) || !finite(deadzone, 0, 0.5) || !finite(sensitivity, 0.1, 3)) throw new RangeError('invalid stick input');
  const magnitude = Math.hypot(x, y);
  if (magnitude <= deadzone) return [0, 0];
  const scale = Math.min(1, ((Math.min(1, magnitude) - deadzone) / (1 - deadzone)) * sensitivity) / magnitude;
  return [x * scale, y * scale];
}

/** Pure mapping engine; no network, UI, or HID dependencies. */
export class Controller {
  #profile;
  #inputs = new Map();
  #mappings;

  constructor(profile) { this.replaceProfile(profile); }

  replaceProfile(profile) {
    const checked = assertProfile(profile);
    this.#profile = checked;
    this.#mappings = new Map(checked.mappings.map(mapping => [mapping.controlId, mapping]));
    this.#inputs.clear();
    // The caller must send this neutral state before activating a new revision.
    return neutralState();
  }

  get profile() { return JSON.parse(JSON.stringify(this.#profile)); }

  update(controlId, value) {
    const mapping = this.#mappings.get(controlId);
    if (!mapping) throw new RangeError(`unknown control: ${controlId}`);
    if (mapping.outputs.length === 2) {
      if (!Array.isArray(value) || value.length !== 2) throw new TypeError('stick input must be [x, y]');
      const [x, y] = normalizeStick(value[0], value[1], mapping.deadzone, mapping.sensitivity);
      this.#inputs.set(controlId, [x && mapping.invertX ? -x : x, y && mapping.invertY ? -y : y]);
    } else if (BUTTONS.includes(mapping.outputs[0])) {
      if (typeof value !== 'boolean') throw new TypeError('button input must be boolean');
      this.#inputs.set(controlId, value);
    } else {
      if (!finite(value, 0, 1)) throw new RangeError('trigger input must be 0–1');
      this.#inputs.set(controlId, value);
    }
    return this.snapshot();
  }

  releaseAll() { this.#inputs.clear(); return neutralState(); }

  snapshot() {
    const state = neutralState();
    for (const [id, value] of this.#inputs) {
      const { outputs } = this.#mappings.get(id);
      if (outputs.length === 2) [state[outputs[0]], state[outputs[1]]] = value;
      else if (BUTTONS.includes(outputs[0])) {
        if (value) state.buttons |= 1 << BUTTONS.indexOf(outputs[0]);
      } else state[outputs[0]] = value;
    }
    return state;
  }
}

/** Authenticated transport must validate session and freshness before calling this. */
export class InputWatchdog {
  #last = null;
  #now;
  #timeout;
  #state = neutralState();

  constructor({ now, timeoutMs = 150 }) {
    if (typeof now !== 'function' || !finite(timeoutMs, 20, 1000)) throw new TypeError('provide a monotonic clock and timeout of 20–1000 ms');
    this.#now = now;
    this.#timeout = timeoutMs;
  }

  accept(state) {
    assertState(state);
    this.#last = this.#now();
    this.#state = { ...state };
  }

  poll() {
    if (this.#last === null || this.#now() - this.#last >= this.#timeout) this.reset();
    return { ...this.#state };
  }

  reset() { this.#last = null; this.#state = neutralState(); return { ...this.#state }; }
}

function assertState(state) {
  if (!record(state) || !onlyKeys(state, ['buttons', ...AXES, ...TRIGGERS]) || !Number.isInteger(state.buttons) || state.buttons < 0 || state.buttons >= (1 << BUTTONS.length) ||
      !AXES.every(axis => finite(state[axis], -1, 1)) || !TRIGGERS.every(axis => finite(state[axis], 0, 1))) {
    throw new RangeError('invalid gamepad state');
  }
}

