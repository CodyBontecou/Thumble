import { assertProfile } from '../../controller/src/index.js';
import { getCharacter } from './character-tools.js';
import { gamepadKeys } from './gamepad-keys.js';

const modifiers = ['', 'SHIFT-', 'CTRL-', 'ALT-', 'CTRL-SHIFT-', 'ALT-SHIFT-', 'ALT-CTRL-', 'ALT-CTRL-SHIFT-'];
const outputs = Object.fromEntries(Object.entries(gamepadKeys).map(([output, key]) => [key, output]));
const plain = value => typeof value === 'string' && value.length <= 512 && !/[\x00-\x1f\x7f|]/.test(value);
export function validateConsolePortLayout(layout) {
  if (!Array.isArray(layout) || !layout.length || layout.length > 17) throw Error('Export a visible ConsolePort layout first');
  const seen = new Set();
  for (const button of layout) {
    if (!button || !outputs[button.key] || seen.has(button.key)) throw Error('Invalid ConsolePort button');
    seen.add(button.key);
    const f = button.frame;
    if (!f || !['x', 'y', 'width', 'height'].every(key => Number.isFinite(f[key]) && f[key] >= 0 && f[key] <= 1) || f.width < .001 || f.height < .001 || f.x + f.width > 1.001 || f.y + f.height > 1.001) throw Error('Invalid ConsolePort frame');
    if (!Array.isArray(button.layers) || button.layers.length !== 8 || new Set(button.layers.map(layer => layer.modifier)).size !== 8) throw Error('Invalid ConsolePort layers');
    for (const layer of button.layers) {
      if (!modifiers.includes(layer.modifier) || !plain(layer.label) || !layer.label || !plain(layer.command) || (layer.kind !== undefined && (!['spell', 'item'].includes(layer.kind) || !Number.isSafeInteger(layer.id) || layer.id < 1 || layer.id > 2147483647))) throw Error('Invalid ConsolePort action');
    }
  }
  return layout;
}

// Preserve each ConsolePort diamond's relative positions independently. Scaling the
// full HUD width squeezed both banks when transferred onto a phone canvas.
export function consolePortFrames(buttons) {
  const frames = new Map();
  for (const [keys, left] of [[['PADDUP', 'PADDDOWN', 'PADDLEFT', 'PADDRIGHT'], .05], [['PAD1', 'PAD2', 'PAD3', 'PAD4'], .75]]) {
    const bank = buttons.filter(b => keys.includes(b.key));
    const centers = bank.map(b => ({ key: b.key, x: b.frame.x + b.frame.width / 2, y: b.frame.y + b.frame.height / 2 }));
    const xs = centers.map(c => c.x), ys = centers.map(c => c.y);
    const minX = Math.min(...xs), minY = Math.min(...ys);
    const dx = Math.max(...xs) - minX, dy = Math.max(...ys) - minY;
    for (const c of centers) frames.set(c.key, { x: left + (dx ? (c.x - minX) / dx : .5) * .20 - .045, y: .16 + (dy ? (c.y - minY) / dy : .5) * .48 - .11, width: .09, height: .22 });
  }
  const inner = { PADLSHOULDER: [.44, .16], PADRSHOULDER: [.56, .16], PADLTRIGGER: [.37, .43], PADRTRIGGER: [.63, .43], PADBACK: [.5, .80], PADFORWARD: [.5, .53], PADLSTICK: [.08, .88], PADRSTICK: [.92, .88], PADSYSTEM: [.5, .29] };
  for (const b of buttons) if (!frames.has(b.key)) {
    const [x, y] = inner[b.key] ?? [.5, .29];
    frames.set(b.key, { x: x - .045, y: y - .11, width: .09, height: .22 });
  }
  return frames;
}

// Fixed public endpoint; addon data never supplies a URL, path or executable code.
export async function resolveWowIcon(kind, id) {
  if (kind === 'spell' && id === 6603) return 'ability_meleedamage';
  const response = await fetch(`https://nether.wowhead.com/classic/tooltip/${kind}/${id}`, { signal: AbortSignal.timeout(7000) });
  if (!response.ok) throw Error(`Icon lookup failed (${response.status})`);
  const body = await response.text();
  if (body.length > 100000) throw Error('Icon response too large');
  const {icon} = JSON.parse(body);
  if (typeof icon !== 'string' || !/^[a-z0-9_]{1,128}$/.test(icon.toLowerCase())) throw Error('No supported icon name');
  return icon.toLowerCase();
}

export async function mirrorConsolePort(store, {snapshotId, sourceProfileId, sourceProfileRevision, profileId, expectedRevision}, lookup = resolveWowIcon) {
  const snapshot = await getCharacter(store, snapshotId);
  const buttons = validateConsolePortLayout(snapshot.consolePortLayout);
  const source = await store.get(sourceProfileId);
  if (source.revision !== sourceProfileRevision) throw Error('Source profile changed; read again');
  const warnings = [], icons = new Map();
  const refs = [...new Map(buttons.flatMap(button => button.layers).filter(layer => layer.kind).map(layer => [`${layer.kind}:${layer.id}`, layer])).values()];
  for (let i = 0; i < refs.length; i += 6) await Promise.all(refs.slice(i, i + 6).map(async layer => {
    try { icons.set(`${layer.kind}:${layer.id}`, await lookup(layer.kind, layer.id)); }
    catch { warnings.push(`Artwork unavailable for ${layer.label}; the text label is retained.`); }
  }));
  const frames = consolePortFrames(buttons);
  const profile = { schemaVersion: 1, id: profileId, name: `${snapshot.character.name} · ConsolePort`, theme: 'consoleport', modifiers: {}, controls: [], mappings: [] };
  for (const [name, cvar] of Object.entries({shift:'GamePadEmulateShift',ctrl:'GamePadEmulateCtrl',alt:'GamePadEmulateAlt'})) profile.modifiers[name] = outputs[snapshot.modifiers[cvar]] ?? 'none';
  const sticks = source.profile.controls.filter(control => control.type === 'stick');
  for (let i = 0; i < sticks.length; i++) {
    const control = sticks[i];
    profile.controls.push({...control, frame:{x:i === 0 ? .24 : .56, y:.57, width:.20, height:.40}});
    profile.mappings.push(source.profile.mappings.find(mapping => mapping.controlId === control.id));
  }
  const badges = {a:'A',b:'B',x:'X',y:'Y',up:'↑',down:'↓',left:'←',right:'→',lb:'LB',rb:'RB',lt:'LT',rt:'RT',back:'View',start:'Menu',ls:'L3',rs:'R3',guide:'Home'};
  for (const button of buttons) {
    const output = outputs[button.key], layers = {};
    for (const layer of button.layers) {
      const utilityIcons = {JUMP:'cp_jump',INTERACTTARGET:'cp_interact',TARGETNEARESTENEMY:'cp_target',TARGETPREVIOUSENEMY:'cp_target',OPENALLBAGS:'cp_bags',TOGGLEWORLDMAP:'cp_map',TOGGLEGAMEMENU:'cp_menu'};
      const icon = icons.get(`${layer.kind}:${layer.id}`) ?? utilityIcons[layer.command];
      const label = !layer.kind && /^(?:ACTIONBUTTON\d+|MULTIACTIONBAR\d+BUTTON\d+)$/.test(layer.command) ? 'Unbound' : layer.label.slice(0,80);
      layers[layer.modifier] = {label, ...(icon ? {icon} : {})};
    }
    profile.controls.push({ id:`cp-${output}`, type:['lt','rt'].includes(output)?'trigger':'button', label:layers[''].label, ...(layers[''].icon ? {icon:layers[''].icon} : {}), badge:badges[output], layers,
      ...( {a:'#8fc878',b:'#ef7268',x:'#6db0e0',y:'#e4cb65'}[output] ? {color:{a:'#8fc878',b:'#ef7268',x:'#6db0e0',y:'#e4cb65'}[output]} : {}),
      frame:frames.get(button.key) });
    profile.mappings.push({controlId:`cp-${output}`,outputs:[output]});
  }
  // Keep utility controls that have no visible ConsolePort frame (e.g. Chat).
  const used = new Set(profile.mappings.flatMap(mapping => mapping.outputs));
  const extras = source.profile.controls.filter(control => control.type !== 'stick' && !used.has(source.profile.mappings.find(m => m.controlId === control.id).outputs[0]));
  extras.forEach((control, i) => {
    profile.controls.push({...control,frame:{x:.46+i*.09,y:.72,width:.08,height:.18}});
    profile.mappings.push(source.profile.mappings.find(mapping => mapping.controlId === control.id));
  });
  assertProfile(profile);
  if ((await store.get(sourceProfileId)).revision !== sourceProfileRevision) throw Error('Source profile changed during icon lookup');
  const saved = await store.save(profile, expectedRevision);
  return {...saved,warnings,snapshotId,note:'Read-only ConsolePort mirror saved. No game bindings changed. Explicitly activate to deliver; export again after changing game pages, bindings or layout.'};
}
