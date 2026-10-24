import { validateProfile } from './controller.js';

export const layoutLimits = Object.freeze({ minimumTarget: 48, minimumStick: 96, units: 'logical points' });
export const validViewport = value => value && Number.isFinite(value.width) && Number.isFinite(value.height) && value.width > 0 && value.height > 0 && value.width <= 10000 && value.height <= 10000;

/** Pixel geometry matches TouchController: sticks capture a centered circle;
 * buttons and triggers capture the whole declarative rectangle. */
function area(control, viewport) {
  const f = control.frame;
  const box = { x: f.x * viewport.width, y: f.y * viewport.height, width: f.width * viewport.width, height: f.height * viewport.height };
  if (control.type !== 'stick') return box;
  const diameter = Math.min(box.width, box.height);
  return { x: box.x + (box.width - diameter) / 2, y: box.y + (box.height - diameter) / 2, width: diameter, height: diameter, radius: diameter / 2 };
}
function overlaps(a, b) {
  const epsilon = 0.001;
  if (a.radius && b.radius) return Math.hypot(a.x + a.radius - b.x - b.radius, a.y + a.radius - b.y - b.radius) < a.radius + b.radius - epsilon;
  if (a.radius || b.radius) {
    const circle = a.radius ? a : b, box = a.radius ? b : a;
    const x = circle.x + circle.radius, y = circle.y + circle.radius;
    const nearX = Math.max(box.x, Math.min(x, box.x + box.width)), nearY = Math.max(box.y, Math.min(y, box.y + box.height));
    return Math.hypot(x - nearX, y - nearY) < circle.radius - epsilon;
  }
  return Math.min(a.x + a.width, b.x + b.width) - Math.max(a.x, b.x) > epsilon && Math.min(a.y + a.height, b.y + b.height) - Math.max(a.y, b.y) > epsilon;
}

/** Evaluate a whole layout against the actual usable controller canvas.
 * This is separate from schema validation so legacy profiles remain readable. */
export function validateLayout(profile, viewport) {
  /** @type {{ code: string, controls: string[], message: string }[]} */
  const errors = validateProfile(profile).map(message => ({ code: 'invalid_profile', controls: [], message }));
  if (!validViewport(viewport)) errors.push({ code: 'invalid_viewport', controls: [], message: 'Supply the phone’s current usable controller canvas in logical points.' });
  if (errors.length) return { valid: false, errors, limits: layoutLimits };
  const areas = profile.controls.map(control => ({ control, box: area(control, viewport) }));
  const reserved = [{ id: 'Thumble menu', x: viewport.width - 44, y: 4, width: 44, height: 44 }];
  if (!profile.controls.some(control => control.id === 'chat')) reserved.push({ id: 'Chat', x: viewport.width / 2 - 26, y: 4, width: 52, height: 44 });
  for (let index = 0; index < areas.length; index++) {
    const { control, box } = areas[index];
    const minimum = control.type === 'stick' ? layoutLimits.minimumStick : layoutLimits.minimumTarget;
    if (Math.min(box.width, box.height) + 0.001 < minimum) errors.push({ code: 'target_too_small', controls: [control.id], message: `${control.id} is ${box.width.toFixed(1)} × ${box.height.toFixed(1)} points; enlarge both dimensions to at least ${minimum}.` });
    for (const other of areas.slice(index + 1)) if (overlaps(box, other.box)) errors.push({ code: 'overlapping_controls', controls: [control.id, other.control.id], message: `Move ${control.id} or ${other.control.id} so their touch areas do not overlap.` });
    for (const chrome of reserved) if (overlaps(box, chrome)) errors.push({ code: 'obscured_control', controls: [control.id], message: `Move ${control.id} away from the ${chrome.id} area at the top of the canvas.` });
  }
  return { valid: errors.length === 0, errors, viewport: { width: viewport.width, height: viewport.height }, limits: layoutLimits };
}
