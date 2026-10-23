import { Controller, assertProfile } from './controller.js';

const clamp = (value, min, max) => Math.min(max, Math.max(min, value));
const contains = (frame, x, y) => x >= frame.x && x <= frame.x + frame.width && y >= frame.y && y <= frame.y + frame.height;

/** Captures each touch independently, so moving one finger cannot steal another control. */
export class TouchController {
  #controller;
  #profile;
  #touches = new Map();
  #onState;
  #onVisual;
  /** @type {{width: number, height: number} | null} */
  #viewport = null;

  /**
   * @param {any} profile
   * @param {{onState?: (state: ReturnType<Controller['snapshot']>) => void, onVisual?: (id: string, visual: {pressed: boolean, x: number, y: number}) => void}} [options]
   */
  constructor(profile, { onState = () => {}, onVisual = () => {} } = {}) {
    this.#profile = assertProfile(profile);
    this.#controller = new Controller(profile);
    this.#onState = onState;
    this.#onVisual = onVisual;
  }

  replaceProfile(profile) {
    const checked = assertProfile(profile);
    this.releaseAll();
    this.#controller.replaceProfile(checked);
    this.#profile = checked;
  }

  setViewport(width, height) {
    if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) throw new RangeError('invalid touch viewport');
    this.releaseAll();
    this.#viewport = { width, height };
  }

  #frame(control) {
    const f = control.frame;
    if (control.type !== 'stick' || !this.#viewport) return f;
    const diameter = Math.min(f.width * this.#viewport.width, f.height * this.#viewport.height);
    const width = diameter / this.#viewport.width, height = diameter / this.#viewport.height;
    return { x: f.x + (f.width - width) / 2, y: f.y + (f.height - height) / 2, width, height };
  }

  down(id, x, y) {
    if (!Number.isFinite(x) || !Number.isFinite(y) || this.#touches.has(id)) return;
    const control = [...this.#profile.controls].reverse().find(control => {
      const f = this.#frame(control);
      if (!contains(f, x, y)) return false;
      return control.type !== 'stick' || !this.#viewport || Math.hypot((x - f.x - f.width / 2) / (f.width / 2), (y - f.y - f.height / 2) / (f.height / 2)) <= 1;
    });
    if (!control) return;
    if (control.type !== 'button' && [...this.#touches.values()].some(touch => touch.control.id === control.id)) return;
    this.#touches.set(id, { control, x, y, startY: y });
    this.#refresh(control);
  }

  move(id, x, y) {
    const touch = this.#touches.get(id);
    if (!touch || !Number.isFinite(x) || !Number.isFinite(y)) return;
    touch.x = x;
    touch.y = y;
    this.#refresh(touch.control);
  }

  up(id) {
    const touch = this.#touches.get(id);
    if (!touch) return;
    this.#touches.delete(id);
    this.#refresh(touch.control);
  }

  releaseAll() {
    this.#touches.clear();
    for (const control of this.#profile.controls) this.#onVisual(control.id, { pressed: false, x: 0, y: 0 });
    const state = this.#controller.releaseAll();
    this.#onState(state);
    return state;
  }

  snapshot() { return this.#controller.snapshot(); }

  #refresh(control) {
    const touches = [...this.#touches.values()].filter(touch => touch.control.id === control.id);
    const touch = touches[0];
    let value;
    let x = 0, y = 0;
    if (control.type === 'button') value = touches.some(touch => contains(control.frame, touch.x, touch.y));
    else if (control.type === 'trigger') value = touch ? clamp(1 - (touch.y - touch.startY) / control.frame.height, 0, 1) : 0;
    else {
      if (touch) {
        const f = this.#frame(control);
        x = (touch.x - f.x - f.width / 2) / (f.width / 2);
        y = -(touch.y - f.y - f.height / 2) / (f.height / 2);
        // Keep this finger's ownership outside the circle, preserving its angle.
        const magnitude = Math.max(1, Math.hypot(x, y));
        x /= magnitude;
        y /= magnitude;
      }
      value = [x, y];
    }
    const state = this.#controller.update(control.id, value);
    this.#onVisual(control.id, { pressed: touches.length > 0 && value !== false, x, y });
    this.#onState(state);
  }
}
