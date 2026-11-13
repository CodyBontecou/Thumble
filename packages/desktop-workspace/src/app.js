import {
  Editor, copy, newProfile, canvasSize, outputNames, outputs, moveControl, updateControl, setOutput, addControl, removeControl,
  acknowledged, signature, controlBox, labelColor, profileState, setChord, desktopProfile, controlName, controlGroup, groupOrder,
  canAdd, layoutProblems, suggestFix, resizeControl, snapFrame, profileSource,
} from './model.js';
import { defaultProfile, builtInProfiles, keyChordLabel } from '../../controller/src/index.js';
import { request } from './bridge.js';

const root = document.querySelector('#app');
let snapshot, editor, page = 'design', message = '', failure = false, busy = false, dragging = false;
let viewport = { ...canvasSize };
let mutationEpoch = 0, showAreas = true, filter = 'All', query = '', libraryId = null, sheet = null, recording = false, conflictSeen = null;
const uid = prefix => `${prefix}-${crypto.randomUUID().replaceAll('-', '')}`;
window.thumbleHasUnsavedChanges = () => !!editor?.dirty;

/* ---------- DOM helpers. Profile text only ever becomes text nodes. ---------- */
const el = (tag, attrs = {}, ...children) => {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs)) {
    if (value === undefined || value === null || value === false && !['checked', 'disabled'].includes(key)) continue;
    if (key.startsWith('on')) node.addEventListener(key.slice(2).toLowerCase(), value);
    else if (key === 'class') node.className = value;
    else if (key === 'value') node.value = value;
    else if (key === 'checked' || key === 'disabled') node[key] = !!value;
    else if (key === 'style') Object.assign(node.style, value);
    else node.setAttribute(key, value === true ? '' : value);
  }
  for (const child of children.flat(Infinity)) if (child !== undefined && child !== null && child !== false) node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  return node;
};
const SVG = {
  plus: '<path d="M12 5v14M5 12h14"/>', undo: '<path d="M9 14L4 9l5-5"/><path d="M4 9h11a5 5 0 0 1 0 10h-3"/>', redo: '<path d="M15 14l5-5-5-5"/><path d="M20 9H9a5 5 0 0 0 0 10h3"/>',
  check: '<path d="M5 12.5l4.5 4.5L19 7"/>', warn: '<path d="M12 4l9 16H3z"/><path d="M12 10v4M12 17v.5"/>', dash: '<path d="M7 12h10"/>', search: '<circle cx="11" cy="11" r="7"/><path d="M20 20l-4-4"/>',
  tag: '<path d="M20.6 13.4l-7.2 7.2a2 2 0 0 1-2.8 0L3 13V3h10l7.6 7.6a2 2 0 0 1 0 2.8z"/><circle cx="7.5" cy="7.5" r="1.3"/>', power: '<path d="M12 3v8"/><path d="M6.3 7.2a8 8 0 1 0 11.4 0"/>',
  restart: '<path d="M20 12a8 8 0 1 1-2.3-5.6"/><path d="M20 4v5h-5"/>', shield: '<path d="M12 3l8 3v6c0 4.5-3.4 8-8 9-4.6-1-8-4.5-8-9V6z"/>', flask: '<path d="M9 3h6M10 3v6l-5 9a2 2 0 0 0 1.8 3h10.4a2 2 0 0 0 1.8-3l-5-9V3"/>',
};
const icon = (name, width = 2) => {
  const node = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  node.setAttribute('viewBox', '0 0 24 24'); node.setAttribute('fill', 'none'); node.setAttribute('stroke', 'currentColor');
  node.setAttribute('stroke-width', width); node.setAttribute('stroke-linecap', 'round'); node.setAttribute('stroke-linejoin', 'round'); node.setAttribute('aria-hidden', 'true');
  node.innerHTML = SVG[name]; return node;
};
const btn = (text, action, attrs = {}) => el('button', { type: 'button', class: 'btn', onClick: () => action(), ...attrs }, text);
const link = (text, action, attrs = {}) => el('button', { type: 'button', class: 'link', onClick: () => action(), ...attrs }, text);
const toggle = (checked, action, label, attrs = {}) => el('button', { type: 'button', class: 'tog', role: 'switch', 'aria-checked': String(!!checked), 'aria-label': label, onClick: () => action(!checked), ...attrs });
const row = (label, ...value) => el('div', { class: 'fr' }, el('span', {}, label), ...value);
const note = text => el('p', { class: 'note' }, text);
const plural = (n, word) => `${n} ${word}${n === 1 ? '' : 's'}`;
const currentEntry = () => snapshot?.profiles.find(entry => entry.profile.id === editor?.profile.id);
const mappingOf = (profile, id) => profile.mappings.find(m => m.controlId === id);
const isMac = () => /mac/i.test(snapshot?.platform ?? navigator.platform);
const phoneOnline = () => !!snapshot?.receiver.running && !!snapshot.receiver.connected;

/* ---------- control visuals ---------- */
const abxy = { a: '#30D158', b: '#FF6961', x: '#64A8FF', y: '#FFD60A' };
function faceKind(control, mapping) {
  const output = mapping?.outputs[0];
  if (control.type === 'stick') return 'stick';
  if (control.type === 'trackpad') return 'pad';
  if (control.type === 'button' && ['a', 'b', 'x', 'y'].includes(output)) return 'round';
  if (control.type === 'button' && ['start', 'back', 'guide', 'ls', 'rs'].includes(output)) return 'small';
  return 'rect';
}
function glyph(control, mapping) {
  const output = mapping?.outputs[0];
  const kind = control.type === 'stick' ? 'stk' : control.type === 'trigger' || ['lb', 'rb'].includes(output) ? 'bar' : control.type === 'key' ? 'key' : control.type === 'mouse' ? 'mouse' : control.type === 'trackpad' ? 'pad' : ['up', 'down', 'left', 'right'].includes(output) ? 'dpad' : 'bt';
  return el('span', { class: `g ${kind}`, 'aria-hidden': 'true' });
}
const typeNames = { button: 'Button', trigger: 'Trigger', stick: 'Stick', key: 'Keyboard key', mouse: 'Mouse button', trackpad: 'Trackpad' };
const sendsLabel = mapping => !mapping ? '' : mapping.outputs[0]?.startsWith('key:') ? keyChordLabel(mapping.outputs) : outputNames[mapping.outputs[0]] ?? mapping.outputs[0];
/** Face geometry inside a control's touch area, as percentages of that area. */
function faceBox(control, kind, view) {
  const f = controlBox(control, view), w = f.width * view.width, h = f.height * view.height;
  if (kind === 'stick') return { left: 0, top: 0, width: 100, height: 100, radius: '50%' };
  if (kind === 'round' || kind === 'small') {
    const d = Math.min(w, h) * (kind === 'small' ? .72 : 1);
    return { left: (w - d) / 2 / w * 100, top: (h - d) / 2 / h * 100, width: d / w * 100, height: d / h * 100, radius: '50%' };
  }
  const inset = Math.min(5, w / 6, h / 6);
  return { left: inset / w * 100, top: inset / h * 100, width: (w - inset * 2) / w * 100, height: (h - inset * 2) / h * 100, radius: kind === 'pad' ? '1.6cqw' : '1.1cqw' };
}
const fontFor = (kind, control) => kind === 'round' ? '2.3cqw' : kind === 'small' ? '1.25cqw' : kind === 'pad' ? '1.5cqw' : control.type === 'key' || control.type === 'mouse' ? '1.6cqw' : '1.7cqw';
function miniPreview(profile, hot = new Set(), view = viewport, attrs = {}) {
  return el('span', { class: 'mini', 'aria-hidden': 'true', style: { aspectRatio: `${view.width}/${view.height}` }, ...attrs }, profile.controls.map(control => {
    const f = controlBox(control, view), kind = faceKind(control, mappingOf(profile, control.id)), face = faceBox(control, kind, view);
    const left = f.x + f.width * face.left / 100, top = f.y + f.height * face.top / 100;
    return el('i', { class: hot.has(control.id) ? 'hot' : undefined, style: { left: `${left * 100}%`, top: `${top * 100}%`, width: `${f.width * face.width}%`, height: `${f.height * face.height}%`, borderRadius: face.radius === '50%' ? '50%' : '3px' } });
  }));
}

/* ---------- status, requests, sheets ---------- */
function status(text, error = false) { message = text; failure = error; document.querySelector('#statusbar')?.replaceWith(statusbar()); }
async function perform(operation, payload = {}, success) {
  if (busy) return;
  mutationEpoch++;
  busy = true; root.inert = true;
  let ok = false;
  try {
    const result = await request(operation, payload);
    if (result?.profiles) snapshot = result;
    ok = true;
    if (success) await success(result);
    return result;
  } catch (error) { status(error.message, true); }
  finally { busy = false; root.inert = false; render(); if (!ok) afterFailure(operation); }
}
function afterFailure(operation) {
  const entry = currentEntry();
  if (operation === 'save' && entry && entry.revision !== editor.revision && editor.dirty) openConflict(entry);
}
function openSheet(next) { sheet = next; render(); }
function closeSheet() { sheet = null; render(); }
function confirmSheet(title, detail, confirm, action, danger = false) { openSheet({ kind: 'confirm', title, detail, confirm, action, danger }); }
const dirtyConfirm = action => editor?.dirty ? confirmSheet('Discard unsaved changes?', 'Your last saved version of this controller stays available.', 'Discard changes', action, true) : action();
function openConflict(entry) { conflictSeen = entry.revision; openSheet({ kind: 'conflict' }); }

/* ---------- editing ---------- */
function loadEntry(entry, keepSelection = false) {
  const selected = editor?.selected;
  editor = new Editor(entry.profile, entry.revision);
  if (keepSelection && entry.profile.controls.some(c => c.id === selected)) editor.selected = selected;
  conflictSeen = null; message = ''; failure = false;
}
function edit(profile) { editor.commit(profile); message = 'Unsaved changes'; failure = false; render(); }
function tryEdit(change) { try { edit(change()); } catch (error) { status(error.message, true); } }
function withoutProp(profile, id, key) { return { ...profile, controls: profile.controls.map(c => { if (c.id !== id) return c; const next = { ...c }; delete next[key]; return next; }) }; }
function select(id) { editor.selected = id; recording = false; render(); }
function add(type) { tryEdit(() => { const profile = addControl(editor.profile, type, uid(type), viewport); editor.selected = profile.controls.at(-1).id; return profile; }); }
function remove(id) { tryEdit(() => { const profile = removeControl(editor.profile, id); editor.selected = null; return profile; }); }
function createController(source = defaultProfile, name) {
  dirtyConfirm(() => {
    const profile = newProfile(uid('desktop'), source);
    if (name) profile.name = name;
    editor = new Editor(profile, 0); editor.saved = null; page = 'design'; sheet = null;
    message = 'Unsaved changes · new controller'; failure = false; render();
  });
}
function save() {
  const problems = layoutProblems(editor.profile, viewport);
  if (problems.length) { editor.selected = null; status(`Fix ${plural(problems.length, 'layout problem')} before saving.`, true); render(); return; }
  if (currentEntry() && !currentEntry().editable) {
    confirmSheet('Save your own copy?', 'Built-in and account controllers stay as they are. Your changes are saved as a new controller.', 'Save copy', () => {
      const next = newProfile(uid('desktop'), editor.profile);
      next.name = editor.profile.name.endsWith(' copy') ? editor.profile.name : `${editor.profile.name} copy`.slice(0, 80);
      editor.profile = next; editor.revision = 0; persist();
    });
  } else persist();
}
function persist() {
  const profile = copy(editor.profile), selected = editor.selected;
  sheet = null;
  perform('save', { profile, expectedProfileRevision: editor.revision, viewport }, () => {
    const entry = snapshot.profiles.find(item => item.profile.id === profile.id);
    editor.load(profile, entry.revision);
    if (profile.controls.some(c => c.id === selected)) editor.selected = selected;
    status('Saved on this computer. Send to phone when you’re ready.');
  });
}
function exportProfile(profile) { perform('export', { profile }, result => status(result.exported ? 'Controller exported.' : 'Export cancelled.')); }
function send(entry = currentEntry()) {
  if (!entry) return status('Save this controller before sending it to your phone.', true);
  if (entry.profile.id === editor.profile.id && editor.dirty) return status('Save this controller before sending it to your phone.', true);
  const problems = layoutProblems(entry.profile, viewport);
  if (problems.length) return status(`${entry.profile.name} has ${plural(problems.length, 'layout problem')}. Open it in Design to fix them.`, true);
  openSheet({ kind: 'send', entryId: entry.profile.id, revision: entry.revision, online: phoneOnline(), stage: 'review' });
}
function confirmSend() {
  const entry = snapshot.profiles.find(e => e.profile.id === sheet.entryId && e.revision === sheet.revision);
  if (!entry) { sheet = null; return status('That controller changed. Open it again before sending.', true); }
  const online = phoneOnline();
  perform('activate', { profileId: entry.profile.id, profileRevision: entry.revision, expectedActivationRevision: snapshot.activationRevision, viewport }, () => {
    if (sheet?.kind === 'send') Object.assign(sheet, { stage: 'progress', online, startedAt: Date.now(), activation: snapshot.activationRevision });
    status(online ? 'Sent. Waiting for the phone to acknowledge this layout.' : 'Selected. This controller will be sent when your phone connects.');
  });
}

/* ---------- rendering ---------- */
function render() {
  if (!snapshot || !editor) return;
  const active = document.activeElement, key = active?.dataset?.key;
  const blocked = !!sheet;
  const body = page === 'design' ? designPage() : page === 'controllers' ? libraryPage() : connectionsPage();
  root.replaceChildren(toolbar(), el('div', { class: 'body', inert: blocked || undefined }, body), statusbar(), sheet ? sheetView() : '');
  const target = key && root.querySelector(`[data-key="${CSS.escape(key)}"]`);
  if (target) target.focus(); else if (sheet) root.querySelector('.sheet [data-autofocus]')?.focus();
}
function toolbar() {
  const tabs = el('nav', { class: 'tabs', 'aria-label': 'Studio' }, [['design', 'Design'], ['controllers', 'Controllers'], ['connections', 'Connections']].map(([id, title]) =>
    el('button', { type: 'button', 'aria-current': page === id ? 'page' : undefined, onClick: () => { page = id; recording = false; render(); } }, title)));
  let doc, right;
  if (page === 'design') {
    const entry = currentEntry();
    const sub = editor.dirty ? (editor.revision ? `Unsaved changes · based on revision ${editor.revision}` : 'Unsaved changes · not saved yet') : `Saved · revision ${editor.revision}${entry && !entry.editable ? ' · edits save as your own copy' : ''}`;
    doc = [el('b', {}, editor.profile.name), el('span', {}, sub)];
    const problems = layoutProblems(editor.profile, viewport).length;
    right = [btn(icon('undo'), () => { editor.undo(); render(); }, { class: 'btn ic', disabled: busy || !editor.past.length, 'aria-label': 'Undo', title: 'Undo (⌘/Ctrl Z)' }),
      btn(icon('redo'), () => { editor.redo(); render(); }, { class: 'btn ic', disabled: busy || !editor.future.length, 'aria-label': 'Redo', title: 'Redo (⌘/Ctrl Shift Z)' }),
      btn('Save', save, { disabled: busy || !editor.dirty || problems > 0, title: problems ? 'Fix the layout problems first' : 'Save (⌘/Ctrl S)' }),
      btn('Send to phone', () => send(), { class: 'btn pri', disabled: busy || editor.dirty || !entry })];
  } else if (page === 'controllers') {
    doc = [el('b', {}, 'Thumble Studio'), el('span', {}, `${plural(snapshot.profiles.length, 'controller')} on this computer`)];
    const file = el('input', { type: 'file', accept: '.json,application/json', class: 'vh', 'aria-label': 'Import controller JSON', tabIndex: -1, onChange: importFile });
    right = [file, btn('Import…', () => file.click()), btn([icon('plus'), 'New controller'], () => openSheet({ kind: 'new' }), { class: 'btn pri' })];
  } else {
    doc = [el('b', {}, 'Thumble Studio'), el('span', {}, phoneOnline() ? 'Phone connected' : snapshot.receiver.running ? 'Waiting for a phone' : 'Receiver needs attention')];
    right = [];
  }
  return el('header', { class: 'tbar', inert: sheet ? true : undefined }, el('div', { class: 'doc' }, doc), tabs,
    el('div', { class: 'tright' }, el('div', { class: 'tgroup' }, snapshot.simulated && el('span', { class: 'sim', title: 'Preview only. No real receiver is connected.' }, 'SIMULATED'), right)));
}
function statusbar() {
  const r = snapshot?.receiver, active = snapshot?.active;
  const light = failure ? 'lt bad' : !r?.running ? 'lt bad' : phoneOnline() ? (acknowledged(snapshot) || !active ? 'lt ok' : 'lt wait') : 'lt';
  return el('footer', { id: 'statusbar', class: `sbar ${failure ? 'error' : ''}`, role: 'status', 'aria-live': 'polite' },
    el('span', {}, el('i', { class: light }), message || r?.detail || 'Opening receiver…'),
    el('span', { class: 'push' }, active ? `Phone uses ${active.profile.name} · revision ${active.profileRevision}` : 'Phone uses the built-in controller'),
    el('span', {}, snapshot?.platform ?? 'Desktop'));
}

/* ---------- Design ---------- */
function designPage() {
  const problems = layoutProblems(editor.profile, viewport);
  return [layersPanel(problems), stage(problems), inspector(problems)];
}
function layersPanel(problems) {
  const bad = new Map();
  problems.forEach((p, i) => p.controls.forEach(id => { if (!bad.has(id)) bad.set(id, i + 1); }));
  const groups = new Map(groupOrder.map(g => [g, []]));
  for (const control of editor.profile.controls) groups.get(controlGroup(control, mappingOf(editor.profile, control.id))).push(control);
  const lists = [...groups].filter(([, items]) => items.length).map(([group, items]) => [el('h3', {}, group, el('span', {}, items.length)),
    items.map(control => {
      const mapping = mappingOf(editor.profile, control.id), name = controlName(control), sends = sendsLabel(mapping);
      return el('button', { type: 'button', class: 'layer', 'aria-pressed': String(editor.selected === control.id), 'data-key': `layer-${control.id}`, onClick: () => select(control.id) },
        glyph(control, mapping), el('span', { class: 'nm' }, name), sends !== name && el('span', { class: 'out' }, sends), bad.has(control.id) && el('span', { class: 'bad', 'aria-label': `Problem ${bad.get(control.id)}` }, bad.get(control.id)));
    })]);
  const types = [['button', 'Button', 'bt'], ['trigger', 'Trigger', 'bar'], ['stick', 'Stick', 'stk'], ['key', 'Key', 'key'], ['mouse', 'Mouse button', 'mouse'], ['trackpad', 'Trackpad', 'pad']];
  return el('aside', { class: 'side', 'aria-label': 'Controls' }, el('h3', {}, 'Controls', el('span', {}, `${editor.profile.controls.length} of 64`)), lists,
    el('h3', {}, 'Add'), el('div', { class: 'palette' }, types.map(([type, title, kind]) => {
      const allowed = canAdd(editor.profile, type);
      return el('button', { type: 'button', disabled: !allowed || busy, title: allowed ? `Add a ${title.toLowerCase()}` : type === 'stick' || type === 'trigger' ? `Both ${type} outputs are already used` : 'This controller is full', onClick: () => add(type) }, el('span', { class: `g ${kind}`, 'aria-hidden': 'true' }), title);
    })), note('Keys, mouse buttons and trackpads need the latest Thumble on your phone.'));
}
function stage(problems) {
  const reserved = [{ id: 'Menu', x: viewport.width - 44, y: 4, width: 44, height: 44 }];
  if (!editor.profile.controls.some(c => c.id === 'chat')) reserved.push({ id: 'Chat', x: viewport.width / 2 - 26, y: 4, width: 52, height: 44 });
  const pct = (n, of) => `${n / of * 100}%`;
  const sizes = [[844, 390], [852, 393], [874, 402], [932, 430], [780, 360]];
  const check = problems.length
    ? el('button', { type: 'button', class: 'chip bad', onClick: () => select(null) }, icon('warn'), plural(problems.length, 'layout problem'))
    : el('span', { class: 'chip ok' }, icon('check', 2.6), 'Layout check passed');
  const canvas = el('div', { id: 'canvas', class: 'canvas', role: 'group', 'aria-label': `${editor.profile.name} layout`, tabIndex: 0, 'data-key': 'canvas', style: { aspectRatio: `${viewport.width}/${viewport.height}`, containerType: 'inline-size' },
    onPointerdown: event => { if (event.target === event.currentTarget) { select(null); } } },
  el('div', { class: 'clip' }, reserved.map(r => el('span', { class: 'res', style: { left: pct(r.x, viewport.width), top: pct(r.y, viewport.height), width: pct(r.width, viewport.width), height: pct(r.height, viewport.height) } }, r.id.toUpperCase()))),
  editor.profile.controls.map(control => controlNode(control, problems)),
  problems.map((p, i) => {
    const target = editor.profile.controls.find(c => c.id === p.controls.at(-1)); if (!target) return null;
    const f = controlBox(target, viewport);
    return el('span', { class: 'pin', 'aria-hidden': 'true', style: { left: `${(f.x + f.width) * 100}%`, top: `${f.y * 100}%` } }, i + 1);
  }));
  return el('main', { class: 'stage', 'aria-label': 'Layout canvas' },
    el('div', { class: 'cbar' },
      el('select', { class: 'sel', 'aria-label': 'Phone screen size', onChange: e => { const [width, height] = e.target.value.split('x').map(Number); viewport = { width, height }; render(); } },
        sizes.map(([w, h]) => el('option', { value: `${w}x${h}`, selected: viewport.width === w && viewport.height === h || undefined }, `Landscape · ${w} × ${h} pt`))),
      el('button', { type: 'button', class: 'chip', role: 'switch', 'aria-checked': String(showAreas), onClick: () => { showAreas = !showAreas; render(); } }, 'Touch areas'),
      el('span', { class: 'push' }), check),
    el('div', { class: 'cwrap' }, el('div', { class: 'device' }, canvas)),
    el('p', { class: 'hint' }, 'Drag to move, drag a corner to resize. Arrow keys nudge, Shift moves 10 pt, Alt skips snapping. Delete removes.'));
}
function controlNode(control, problems) {
  const mapping = mappingOf(editor.profile, control.id), kind = faceKind(control, mapping), f = controlBox(control, viewport), face = faceBox(control, kind, viewport);
  const selected = editor.selected === control.id, bad = problems.some(p => p.controls.includes(control.id));
  const output = mapping?.outputs[0], name = controlName(control);
  const textColor = control.color ? labelColor(control.color) : abxy[output] ?? undefined;
  const node = el('button', { type: 'button', class: `pad-control${showAreas ? ' areas' : ''}${selected ? ' selected' : ''}${bad ? ' bad' : ''}`, 'data-id': control.id, 'data-type': control.type, 'data-key': `control-${control.id}`,
    'aria-label': `${name}, ${typeNames[control.type]}, sends ${sendsLabel(mapping)}`, 'aria-pressed': String(selected),
    style: { left: `${f.x * 100}%`, top: `${f.y * 100}%`, width: `${f.width * 100}%`, height: `${f.height * 100}%` },
    onPointerdown: event => beginDrag(event, control.id), onKeydown: event => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); select(control.id); } } },
  el('span', { class: 'face', style: { left: `${face.left}%`, top: `${face.top}%`, width: `${face.width}%`, height: `${face.height}%`, borderRadius: face.radius, fontSize: fontFor(kind, control), ...(control.color ? { background: control.color } : {}), ...(textColor ? { color: textColor } : {}) } },
    kind === 'stick' ? el('span', { class: 'knob' }) : name));
  if (selected) {
    node.append(...['nw', 'ne', 'sw', 'se'].map(corner => el('span', { class: `hd ${corner}`, 'data-corner': corner, 'aria-hidden': 'true' })),
      el('span', { class: 'sz', 'aria-hidden': 'true' }, sizeText(control)));
  }
  return node;
}
const sizeText = control => `${Math.round(control.frame.width * viewport.width)} × ${Math.round(control.frame.height * viewport.height)} pt`;
function beginDrag(event, id) {
  if (event.button !== 0 || dragging || busy) return;
  event.preventDefault();
  const corner = event.target.dataset?.corner;
  if (editor.selected !== id) { editor.selected = id; recording = false; render(); }
  const canvas = document.querySelector('#canvas'), node = canvas.querySelector(`[data-id="${CSS.escape(id)}"]`);
  const bounds = canvas.getBoundingClientRect(), original = copy(editor.profile), startX = event.clientX, startY = event.clientY;
  let moved = false;
  dragging = true; node.setPointerCapture(event.pointerId);
  const guides = [el('span', { class: 'guide v', hidden: true }), el('span', { class: 'guide h', hidden: true })];
  canvas.append(...guides);
  const move = e => {
    if (e.pointerId !== event.pointerId) return;
    const dx = (e.clientX - startX) / bounds.width, dy = (e.clientY - startY) / bounds.height;
    if (!moved && Math.hypot(e.clientX - startX, e.clientY - startY) < 3) return;
    moved = true;
    let profile;
    if (corner) { profile = resizeControl(original, id, corner, dx, dy, viewport); guides.forEach(g => { g.hidden = true; }); }
    else {
      profile = moveControl(original, id, dx, dy, false, viewport);
      if (!e.altKey) {
        const snapped = snapFrame(original, id, profile.controls.find(c => c.id === id).frame, viewport);
        profile = updateControl(profile, id, { frame: snapped.frame });
        guides[0].hidden = snapped.guides.x === null; guides[1].hidden = snapped.guides.y === null;
        if (snapped.guides.x !== null) guides[0].style.left = `${snapped.guides.x * 100}%`;
        if (snapped.guides.y !== null) guides[1].style.top = `${snapped.guides.y * 100}%`;
      } else guides.forEach(g => { g.hidden = true; });
    }
    const control = profile.controls.find(c => c.id === id), f = controlBox(control, viewport);
    Object.assign(node.style, { left: `${f.x * 100}%`, top: `${f.y * 100}%`, width: `${f.width * 100}%`, height: `${f.height * 100}%` });
    const face = faceBox(control, faceKind(control, mappingOf(profile, id)), viewport), faceNode = node.querySelector('.face');
    Object.assign(faceNode.style, { left: `${face.left}%`, top: `${face.top}%`, width: `${face.width}%`, height: `${face.height}%` });
    const badge = node.querySelector('.sz'); if (badge) badge.textContent = sizeText(control);
    editor.profile = profile;
  };
  const finish = commit => e => {
    if (e && e.pointerId !== event.pointerId) return;
    for (const [name, fn] of handlers) node.removeEventListener(name, fn);
    guides.forEach(g => g.remove());
    const next = editor.profile; editor.profile = original; dragging = false;
    if (commit && moved) edit(next); else render();
  };
  const handlers = [['pointermove', move], ['pointerup', finish(true)], ['pointercancel', finish(false)], ['lostpointercapture', finish(true)]];
  for (const [name, fn] of handlers) node.addEventListener(name, fn);
}

function inspector(problems) {
  const control = editor.profile.controls.find(c => c.id === editor.selected);
  return el('aside', { class: 'insp', 'aria-label': 'Inspector' }, control ? controlInspector(control, problems) : controllerInspector(problems));
}
function problemList(problems) {
  if (!problems.length) return el('div', { class: 'callout ok' }, icon('check', 2.2), el('div', {}, el('b', {}, 'Layout check passed'), 'Touch sizes, spacing and the reserved top areas are clear.'));
  return el('div', { class: 'issues' }, problems.map((problem, i) => {
    const fix = suggestFix(editor.profile, problem, viewport), target = problem.controls.at(-1);
    return el('div', { class: 'issue' }, el('span', { class: 'n' }, i + 1), el('div', {}, el('b', {}, problem.title), problem.detail && el('span', { class: 'note' }, problem.detail),
      el('span', { class: 'acts' }, fix && link(fix.label, () => edit(fix.profile)), target && link('Select', () => select(target)))));
  }));
}
function controllerInspector(problems) {
  const entry = currentEntry(), active = snapshot.active;
  const onPhone = !entry ? 'Not saved yet' : active?.profile.id !== entry.profile.id ? 'No' : active.profileRevision === entry.revision ? `Yes · revision ${entry.revision}` : `Revision ${active.profileRevision} (older)`;
  const counts = Object.entries(editor.profile.controls.reduce((all, c) => ({ ...all, [c.type]: (all[c.type] ?? 0) + 1 }), {})).map(([t, n]) => `${n} ${typeNames[t].toLowerCase()}${n === 1 ? '' : 's'}`).join(', ');
  return [el('div', { class: 'ihead' }, el('div', {}, el('b', {}, 'Controller'), el('span', {}, 'Select a control to edit it'))),
    el('div', { class: 'sec' }, el('h4', {}, 'Details'), el('div', { class: 'box' },
      row('Name', el('input', { value: editor.profile.name, maxlength: 80, 'aria-label': 'Controller name', 'data-key': 'name', onChange: e => edit({ ...editor.profile, name: e.target.value.slice(0, 80) }) })),
      row('Controls', el('span', { class: 'v' }, counts)), row('On your phone', el('span', { class: 'v' }, onPhone)),
      row('Source', el('span', { class: 'v' }, entry ? profileSource(entry) : 'New')))),
    el('div', { class: 'sec' }, el('h4', {}, 'Layout check', el('span', {}, `${viewport.width} × ${viewport.height} pt`)), problemList(problems)),
    el('div', { class: 'sec' }, el('h4', {}, 'Rules'), note('Touch areas at least 48 pt, sticks 96 pt. Touch areas can’t overlap. The Chat and Thumble menu buttons at the top stay clear.')),
    el('div', { class: 'tgroup' }, btn(editor.dirty ? 'Export draft…' : 'Export…', () => exportProfile(editor.profile), { disabled: busy }))];
}
function controlInspector(control, problems) {
  const profile = editor.profile, mapping = mappingOf(profile, control.id), output = mapping.outputs[0], id = control.id;
  const mine = problems.filter(p => p.controls.includes(id));
  const sections = [el('div', { class: 'ihead' }, glyph(control, mapping), el('div', {}, el('b', {}, controlName(control)), el('span', {}, `${typeNames[control.type]} · sends ${sendsLabel(mapping)}`)))];
  if (mine.length) sections.push(problemList(mine));
  const seg = (options, current, pick) => el('div', { class: 'seg', role: 'group' }, options.map(([value, title]) => el('button', { type: 'button', 'aria-pressed': String(value === current), onClick: () => pick(value) }, title)));
  const sends = el('div', { class: 'sec' }, el('h4', {}, 'Sends'));
  if (control.type === 'stick') sends.append(seg([['lx', 'Left stick (Move)'], ['rx', 'Right stick (Look)']], output, v => tryEdit(() => setOutput(profile, id, v))));
  else if (control.type === 'trigger') sends.append(seg([['lt', 'LT'], ['rt', 'RT']], output, v => tryEdit(() => setOutput(profile, id, v))));
  else if (control.type === 'mouse') sends.append(seg([['mouse:left', 'Left'], ['mouse:right', 'Right'], ['mouse:middle', 'Middle']], output, v => tryEdit(() => setOutput(profile, id, v))));
  else if (control.type === 'trackpad') sends.append(note('One finger moves the pointer. Two fingers scroll. Hold a mouse button while moving to drag.'));
  else if (control.type === 'button') sends.append(el('div', { class: 'box' }, row('Gamepad button', el('select', { 'aria-label': 'Gamepad button', 'data-key': 'output', onChange: e => tryEdit(() => setOutput(profile, id, e.target.value)) },
    outputs('button').map(o => el('option', { value: o, selected: o === output || undefined }, outputNames[o] ?? o))))));
  else if (control.type === 'key') {
    const mods = [['key:ShiftLeft', 'Shift'], ['key:ControlLeft', 'Ctrl'], ['key:AltLeft', isMac() ? 'Option' : 'Alt'], ['key:MetaLeft', isMac() ? 'Cmd' : 'Win']];
    const isMod = o => /^key:(Control|Shift|Alt|Meta)/.test(o);
    const base = mapping.outputs.filter(o => !isMod(o));
    sends.append(el('div', { class: 'chord', 'aria-live': 'polite' }, keyChordLabel(mapping.outputs)),
      el('div', { class: 'mods', role: 'group', 'aria-label': 'Hold with' }, mods.map(([key, title]) => el('button', { type: 'button', 'aria-pressed': String(mapping.outputs.includes(key)), onClick: () => {
        const next = mapping.outputs.includes(key) ? mapping.outputs.filter(o => o !== key) : [key, ...mapping.outputs];
        tryEdit(() => setChord(profile, id, next.length ? next : ['key:Space']));
      } }, title))),
      el('div', { class: 'box' }, row('Key', el('select', { 'aria-label': 'Key', 'data-key': 'base-key', onChange: e => tryEdit(() => setChord(profile, id, [...mapping.outputs.filter(isMod), e.target.value])) },
        outputs('key').filter(o => !isMod(o)).map(o => el('option', { value: o, selected: o === base[0] || undefined }, outputNames[o] ?? o))))),
      el('button', { type: 'button', class: `rec${recording ? ' on' : ''}`, 'data-key': 'record', onClick: () => { recording = !recording; render(); } }, recording ? 'Press a shortcut… (Esc cancels)' : 'Record shortcut'));
  }
  sections.push(sends);
  if (control.type === 'stick' || control.type === 'trackpad') {
    const range = (label, key, min, max, step, fallback, format) => {
      const value = mapping[key] ?? fallback;
      return row(label, el('input', { type: 'range', min, max, step, value, 'aria-label': label, 'data-key': key, onInput: e => { e.target.nextSibling.textContent = format(Number(e.target.value)); }, onChange: e => tryEdit(() => setOutput(profile, id, output, { [key]: Number(e.target.value) })) }), el('span', { class: 'num' }, format(value)));
    };
    const feel = el('div', { class: 'sec' }, el('h4', {}, 'Feel'));
    if (control.type === 'stick') feel.append(el('div', { class: 'box' }, range('Deadzone', 'deadzone', 0, .5, .01, .1, v => `${Math.round(v * 100)}%`), range('Sensitivity', 'sensitivity', .1, 3, .05, 1, v => `${v.toFixed(2)}×`),
      row('Invert left/right', toggle(mapping.invertX, v => tryEdit(() => setOutput(profile, id, output, { invertX: v })), 'Invert left/right')),
      row('Invert up/down', toggle(mapping.invertY, v => tryEdit(() => setOutput(profile, id, output, { invertY: v })), 'Invert up/down'))));
    else feel.append(el('div', { class: 'box' }, range('Pointer speed', 'sensitivity', .1, 3, .05, 1, v => `${v.toFixed(2)}×`)));
    sections.push(feel);
  }
  sections.push(el('div', { class: 'sec' }, el('h4', {}, 'Appearance'), el('div', { class: 'box' },
    row('Label', el('input', { value: control.customLabel ?? control.label, maxlength: 80, 'aria-label': 'Label', 'data-key': 'label', onChange: e => {
      const label = e.target.value.trim().slice(0, 80);
      tryEdit(() => label ? updateControl(profile, id, { label, customLabel: label }) : withoutProp(updateControl(profile, id, { label: sendsLabel(mapping) || control.label }), id, 'customLabel'));
    } })),
    row('Color', el('span', { class: 'tgroup' }, control.color && link('Default', () => tryEdit(() => withoutProp(profile, id, 'color'))),
      el('input', { type: 'color', value: control.color ?? '#3a3a3c', 'aria-label': 'Color', 'data-key': 'color', onChange: e => tryEdit(() => updateControl(profile, id, { color: e.target.value })) }))))));
  const num = (label, key) => {
    const dim = key === 'x' || key === 'width' ? 'width' : 'height';
    return el('label', {}, label, el('input', { value: Math.round(control.frame[key] * viewport[dim]), inputmode: 'numeric', 'aria-label': `${label} in points`, 'data-key': `frame-${key}`, onChange: e => {
      const n = Number(e.target.value); if (!Number.isFinite(n)) return render();
      const frame = { ...control.frame, [key]: Math.max(key === 'width' || key === 'height' ? 1 : 0, n) / viewport[dim] };
      frame.width = Math.min(frame.width, 1); frame.height = Math.min(frame.height, 1);
      frame.x = Math.min(Math.max(0, frame.x), 1 - frame.width); frame.y = Math.min(Math.max(0, frame.y), 1 - frame.height);
      tryEdit(() => updateControl(profile, id, { frame }));
    } }));
  };
  sections.push(el('div', { class: 'sec' }, el('h4', {}, 'Position and size', el('span', {}, 'points')), el('div', { class: 'nums' }, num('X', 'x'), num('Y', 'y'), num('W', 'width'), num('H', 'height'))),
    el('div', { class: 'tgroup' }, btn('Remove control', () => remove(id), { class: 'btn red', disabled: profile.controls.length <= 1 })));
  return sections;
}

/* ---------- Controllers ---------- */
async function importFile(event) {
  const file = event.target.files[0]; event.target.value = '';
  if (!file) return;
  if (file.size > 60000) return status('Choose a controller JSON file smaller than 60 KB.', true);
  try {
    const profile = JSON.parse(await file.text());
    const problems = layoutProblems(profile, viewport);
    if (problems.length) throw Error(problems[0].title);
    createController(profile, String(profile.name).slice(0, 80));
  } catch (error) { status(`Could not import controller: ${error.message}`, true); }
}
function libraryPage() {
  const all = snapshot.profiles;
  const shown = all.filter(e => (filter === 'All' || profileSource(e) === filter) && e.profile.name.toLowerCase().includes(query.toLowerCase()));
  if (!all.some(e => e.profile.id === libraryId)) libraryId = snapshot.active?.profile.id ?? all[0]?.profile.id;
  const chips = ['All', 'Yours', 'Built in', 'From your account'].map(name => el('button', { type: 'button', class: 'chip', role: 'radio', 'aria-checked': String(filter === name), onClick: () => { filter = name; render(); } },
    name, el('span', { class: 'n' }, name === 'All' ? all.length : all.filter(e => profileSource(e) === name).length)));
  const main = el('main', { class: 'page', 'aria-label': 'Controller library' },
    el('div', { class: 'ph1' }, el('div', {}, el('h1', {}, 'Controllers'), el('p', {}, 'Built-in originals stay intact. Edit a copy, then choose which one your phone uses.')),
      el('label', { class: 'search' }, icon('search'), el('input', { placeholder: 'Search controllers', 'aria-label': 'Search controllers', value: query, 'data-key': 'search', onInput: e => { query = e.target.value; render(); } }))),
    el('div', { class: 'tgroup', role: 'radiogroup', 'aria-label': 'Filter' }, chips),
    shown.length ? el('div', { class: 'cards' }, shown.map(entry => {
      const state = profileState(entry, snapshot), source = profileSource(entry);
      const tags = [state === 'selected' && ['ok', 'On your phone'], state === 'draft' && ['warn', 'Newer than phone'], !entry.editable && ['', source === 'Built in' ? 'Original' : 'Read only'],
        entry.profile.controls.some(c => ['key', 'mouse', 'trackpad'].includes(c.type)) && ['acc', 'Keys and mouse'], entry.profile.theme === 'consoleport' && ['', 'World of Warcraft']].filter(Boolean);
      return el('button', { type: 'button', class: 'card', 'aria-pressed': String(entry.profile.id === libraryId), 'data-key': `card-${entry.profile.id}`, onClick: () => { libraryId = entry.profile.id; render(); }, onDblclick: () => openInDesign(entry) },
        miniPreview(entry.profile), el('span', { class: 'ct' }, el('b', {}, entry.profile.name), el('span', { class: 'meta' }, `${plural(entry.profile.controls.length, 'control')} · ${entry.editable ? `revision ${entry.revision}` : source.toLowerCase()}`)),
        el('span', { class: 'tags' }, tags.map(([c, t]) => el('span', { class: `tag ${c}` }, t))));
    })) : el('p', { class: 'empty' }, 'No controllers match.'),
    note('Studio, the phone editor and agents save to this same list. Each save makes a new revision, and your phone uses exactly the revision you send.'));
  const entry = all.find(e => e.profile.id === libraryId);
  return [main, entry ? libraryDetail(entry) : el('aside', { class: 'insp' }, note('Select a controller.'))];
}
function openInDesign(entry) {
  if (!entry.editable) return createController(entry.profile);
  if (editor.profile.id === entry.profile.id && editor.revision === entry.revision) { page = 'design'; return render(); }
  dirtyConfirm(() => { loadEntry(entry); page = 'design'; sheet = null; render(); });
}
function libraryDetail(entry) {
  const state = profileState(entry, snapshot), active = state !== 'saved', source = profileSource(entry);
  const types = entry.profile.controls.reduce((all, c) => ({ ...all, [c.type]: (all[c.type] ?? 0) + 1 }), {});
  const sourceNote = entry.editable ? 'Your controller.' : source === 'Built in' ? 'Built in. Duplicate it to make your own.' : 'From your Thumble account. The original stays as it arrived.';
  const openedHere = editor.profile.id === entry.profile.id && editor.dirty;
  return el('aside', { class: 'insp', 'aria-label': 'Selected controller' }, miniPreview(entry.profile),
    el('div', {}, el('b', { style: { fontSize: '15px' } }, entry.profile.name), el('p', { class: 'note', style: { marginTop: '2px' } }, sourceNote)),
    el('div', { class: 'box' }, row('Controls', el('span', { class: 'v' }, Object.entries(types).map(([t, n]) => `${n} ${typeNames[t].toLowerCase()}${n === 1 ? '' : 's'}`).join(', '))),
      row('Revision', el('span', { class: 'v' }, entry.revision)),
      row('On your phone', el('span', { class: 'v' }, state === 'selected' ? `Yes · revision ${entry.revision}` : state === 'draft' ? `Revision ${snapshot.active.profileRevision} · newer saved` : 'No'))),
    el('div', { class: 'lib-actions' }, btn(entry.editable ? 'Open in Design' : 'Duplicate and edit', () => openInDesign(entry), { class: 'btn lg pri' }),
      btn(state === 'selected' ? 'On your phone' : state === 'draft' ? 'Send the latest revision' : 'Use on phone', () => send(entry), { class: 'btn lg', disabled: busy || state === 'selected' || openedHere, title: openedHere ? 'Save your changes in Design first' : undefined })),
    el('div', { class: 'tgroup' }, btn('Duplicate', () => createController(entry.profile)), btn('Export…', () => exportProfile(entry.profile)),
      entry.editable && btn('Rename…', () => openSheet({ kind: 'rename', entryId: entry.profile.id }), { disabled: openedHere, title: openedHere ? 'Save your changes in Design first' : undefined })),
    entry.editable ? el('div', { class: 'sec', style: { marginTop: 'auto' } }, btn('Delete controller', () => confirmSheet(`Delete “${entry.profile.name}”?`, 'This removes it from this computer. Export a copy first if you want a backup.', 'Delete controller', () => {
      perform('delete', { profileId: entry.profile.id, expectedProfileRevision: entry.revision, expectedActivationRevision: snapshot.activationRevision }, () => {
        if (editor.profile.id === entry.profile.id) { const next = snapshot.profiles.find(e => e.profile.id === snapshot.active?.profile.id) ?? snapshot.profiles[0]; if (next) loadEntry(next); }
        sheet = null; status('Controller deleted.');
      });
    }, true), { class: 'btn red', disabled: busy || active }), active && note('Your phone uses this one. Send another controller before deleting it.'))
      : note(source === 'Built in' ? 'Built-in controllers can’t be changed or deleted.' : 'Edit it and Studio saves your changes as a new controller.'));
}

/* ---------- Connections ---------- */
function connectionsPage() {
  const r = snapshot.receiver, settings = snapshot.settings ?? {}, active = snapshot.active, online = phoneOnline(), ack = acknowledged(snapshot);
  const activeProfile = active?.profile ?? defaultProfile;
  const hero = online
    ? el('section', { class: 'cx-hero', 'aria-labelledby': 'phone-h' }, el('div', { class: 'cx-dev' }, miniPreview(activeProfile)),
      el('div', { class: 'cx-who' }, el('h1', { id: 'phone-h' }, 'Phone connected'), el('div', { class: 'cx-st' }, el('i', { class: 'lt ok' }), 'Connected over your local network'),
        el('div', { class: 'cx-sub' }, `Using ${activeProfile.name}${active ? `, revision ${active.profileRevision}` : ''} · ${ack || !active ? 'controls live' : 'waiting for the phone to confirm'}`),
        el('div', { class: 'tgroup' }, btn('Disconnect', () => perform('disconnect', {}, () => status('Phone disconnected. It can reconnect without a new code.'))),
          btn('Forget phone…', () => confirmSheet('Forget this phone?', 'It will need to scan a new pairing code before it can connect again.', 'Forget phone', () => { sheet = null; perform('forget', {}, () => status('Phone forgotten.')); }, true), { class: 'btn red' }))))
    : el('section', { class: 'cx-hero', 'aria-labelledby': 'pair-h' },
      snapshot.pairing?.png ? el('img', { class: 'cx-qr', alt: 'Pairing code for your phone', src: `data:image/png;base64,${snapshot.pairing.png}` }) : el('div', { class: 'cx-qr none' }, r.running ? 'The pairing code appears in a moment.' : 'Start the receiver to show a pairing code.'),
      el('div', { class: 'cx-who' }, el('h1', { id: 'pair-h' }, 'Pair your phone'), el('div', { class: 'cx-st' }, el('i', { class: r.running ? 'lt wait' : 'lt bad' }), r.running ? 'Waiting on this network' : 'The receiver isn’t running'),
        el('ol', { class: 'cx-steps' }, el('li', {}, 'Open Thumble on your phone'), el('li', {}, 'Tap Connect computer'), el('li', {}, 'Scan this code')),
        el('div', { class: 'tgroup' }, btn('Copy pairing link', () => perform('copy-pairing', {}, () => status('Pairing link copied.')), { class: 'btn pri', disabled: busy || !snapshot.pairing?.png })),
        el('div', { class: 'cx-sub' }, 'Keep both on the same Wi-Fi. A phone you paired before reconnects on its own.')));
  const check = (state, title, detail) => el('div', { class: 'cx-chk' }, el('span', { class: `ck ${state}` }, icon(state === '' ? 'check' : state === 'bad' ? 'warn' : 'dash', 3)), el('div', {}, el('b', {}, title), el('span', {}, detail)));
  const checks = el('section', { class: 'cx-checks', 'aria-label': 'Ready to play' },
    check(r.running ? '' : 'bad', 'Controller output', r.running ? 'Games see an Xbox-compatible controller' : r.detail || 'Receiver stopped'),
    check(online ? '' : 'off', 'Phone', online ? 'Connected' : 'Not connected'),
    check(!active ? (online ? '' : 'off') : ack ? '' : online ? 'wait' : 'off', 'Controller on phone', !active ? 'Built-in controller' : ack ? `${active.profile.name} · revision ${active.profileRevision}` : online ? 'Waiting for the phone to confirm' : 'Confirms when the phone connects'));
  const rowIc = (color, name, title, detail, control) => el('div', { class: 'cx-row' }, el('span', { class: 'cx-ic', style: { background: color } }, icon(name)), el('div', { class: 'cx-tx' }, el('b', {}, title), detail && el('span', {}, detail)), control);
  const folder = settings.wowPaths?.[0];
  const games = el('section', { class: 'cx-sec', 'aria-labelledby': 'games-h' }, el('div', { class: 'cx-lbl' }, el('span', { id: 'games-h' }, 'Games')), el('div', { class: 'box' },
    rowIc('#FF9F0A', 'tag', 'World of Warcraft spell labels', 'ConsolePort labels sync to the ConsolePort controller after /reload', toggle(settings.syncEnabled, v => perform('settings', { syncEnabled: v }), 'Sync World of Warcraft spell labels', { disabled: busy })),
    settings.syncEnabled && [el('div', { class: 'cx-row sub' }, el('div', { class: 'cx-tx' }, el('span', {}, 'Game folder'), el('span', { class: 'mono' }, folder ?? 'No folder chosen yet')), link(folder ? 'Change…' : 'Choose…', () => perform('choose-wow-folder'), { disabled: busy })),
      el('div', { class: 'cx-row sub' }, el('div', { class: 'cx-tx' }, el('span', {}, snapshot.sync?.detail ?? 'Waiting for /reload')))]));
  const receiver = el('section', { class: 'cx-sec', 'aria-labelledby': 'rcv-h' }, el('div', { class: 'cx-lbl' }, el('span', { id: 'rcv-h' }, 'Receiver'), link('Driver and permissions…', () => perform('setup-driver'), { style: { fontSize: '12px' }, disabled: busy })), el('div', { class: 'box' },
    rowIc('#8E8E93', 'power', 'Start when I sign in', null, toggle(settings.startAtLogin, v => perform('settings', { startAtLogin: v }), 'Start when I sign in', { disabled: busy })),
    rowIc('#30D158', 'restart', 'Restart receiver', r.detail, btn('Restart', () => perform('retry', {}, () => status('Receiver restarted.')), { disabled: busy })),
    snapshot.simulated && rowIc('#BF5AF2', 'flask', 'Simulated receiver', 'Preview only. Pick a state to test.', el('select', { class: 'sel', 'aria-label': 'Simulated state', onChange: e => perform('simulate', { state: e.target.value }) },
      ['connected', 'disconnected', 'missing-driver', 'pending', 'stale-edit'].map(s => el('option', { value: s, selected: snapshot.scenario === s || undefined }, s))))));
  return el('main', { class: 'cx', 'aria-label': 'Connections' }, el('div', { class: 'cx-col' }, hero, checks, games, receiver, el('p', { class: 'cx-foot' }, 'Switching controllers always pauses input until you resume on your phone.')));
}

/* ---------- sheets ---------- */
function sheetView() {
  const view = sheet.kind === 'send' ? sendSheet() : sheet.kind === 'conflict' ? conflictSheet() : sheet.kind === 'new' ? newSheet() : sheet.kind === 'rename' ? renameSheet() : confirmView();
  return el('div', { class: 'scrim', onPointerdown: e => { if (e.target === e.currentTarget && sheet.kind !== 'conflict' && sheet.stage !== 'progress') closeSheet(); } }, view);
}
const dialog = (labelId, children, wide = false) => el('section', { class: `sheet${wide ? ' wide' : ''}`, role: 'dialog', 'aria-modal': 'true', 'aria-labelledby': labelId }, children);
function confirmView() {
  return dialog('confirm-h', [el('h2', { id: 'confirm-h' }, sheet.title), el('p', {}, sheet.detail),
    el('div', { class: 'acts' }, btn('Cancel', closeSheet, { class: 'btn lg', 'data-autofocus': true }), btn(sheet.confirm, () => { const action = sheet.action; sheet = null; action(); render(); }, { class: `btn lg ${sheet.danger ? 'red' : 'pri'}` }))]);
}
function sendSheet() {
  const entry = snapshot.profiles.find(e => e.profile.id === sheet.entryId), name = entry?.profile.name ?? 'this controller', active = snapshot.active;
  if (sheet.stage === 'review') {
    const online = phoneOnline();
    return dialog('send-h', [el('h2', { id: 'send-h' }, online ? `Send “${name}” to your phone?` : `Use “${name}” on your phone?`),
      el('p', {}, online ? 'Your phone pauses controls while the new layout loads, so nothing stays pressed. You resume on the phone when you’re ready.' : 'Your phone isn’t connected. Studio selects this revision now and sends it as soon as the phone connects.'),
      el('div', { class: 'box' }, row('Sending', el('span', { class: 'v' }, `Revision ${sheet.revision} · ${plural(entry?.profile.controls.length ?? 0, 'control')}`)),
        row('Phone has', el('span', { class: 'v' }, active ? `${active.profile.name} · revision ${active.profileRevision}` : 'Built-in controller'))),
      el('div', { class: 'acts' }, btn('Cancel', closeSheet, { class: 'btn lg' }), btn(online ? 'Send and pause controls' : 'Select for phone', confirmSend, { class: 'btn lg pri', 'data-autofocus': true, disabled: busy }))]);
  }
  const ack = acknowledged(snapshot) && snapshot.activationRevision === sheet.activation, online = sheet.online;
  const step = (n, title, detail, state) => el('div', { class: 'step' }, el('span', { class: `num1 ${state}` }, state === 'done' ? icon('check', 2.6) : n), el('div', {}, el('b', {}, title), el('span', {}, detail)));
  const slow = !ack && Date.now() - sheet.startedAt > 8000;
  const steps = online
    ? [step(1, 'Pause controls on your phone', 'Everything is released, so nothing stays pressed in your game.', 'done'),
      step(2, `Send revision ${sheet.revision}`, 'Over your local network. Nothing goes through the internet.', phoneOnline() || ack ? 'done' : 'now'),
      step(3, 'Phone confirms the new layout', 'The phone draws it, checks it and reports back.', ack ? 'done' : 'now')]
    : [step(1, `Select revision ${sheet.revision} for your phone`, 'Saved on this computer as the layout to use.', 'done'),
      step(2, 'Waiting for your phone to connect', 'Open Thumble on your phone on the same Wi-Fi.', ack ? 'done' : 'now')];
  return dialog('send-h', [el('h2', { id: 'send-h' }, ack ? `Your phone is using revision ${sheet.revision}` : online ? 'Sending to your phone…' : 'Selected for your phone'),
    el('div', { class: 'steps' }, steps),
    ack && el('div', { class: 'callout ok' }, icon('check', 2.2), el('div', {}, el('b', {}, 'Resume on your phone to play'), 'Controls stay paused until you tap Resume on the phone.')),
    slow && online && el('div', { class: 'callout warn' }, icon('warn', 2.2), el('div', {}, el('b', {}, 'Your phone hasn’t confirmed yet'), snapshot.receiver.detail || 'Check that Thumble is open on your phone. It confirms as soon as it can.')),
    el('div', { class: 'acts' }, btn(ack || !online ? 'Done' : 'Hide', closeSheet, { class: 'btn lg pri', 'data-autofocus': true }))]);
}
function conflictSheet() {
  const entry = currentEntry();
  if (!entry) { sheet = null; return ''; }
  const changed = new Set(editor.profile.controls.filter(c => { const other = entry.profile.controls.find(o => o.id === c.id); return !other || signature(other) !== signature(c); }).map(c => c.id));
  const theirs = new Set(entry.profile.controls.filter(c => { const mine = editor.saved?.controls.find(o => o.id === c.id); return !mine || signature(mine) !== signature(c); }).map(c => c.id));
  return dialog('conflict-h', [el('div', {}, el('h2', { id: 'conflict-h' }, 'This controller changed somewhere else'),
    el('p', { style: { marginTop: '6px' } }, `You edited revision ${editor.revision} here while your phone or another app saved revision ${entry.revision}. Saving now would overwrite those changes, so choose what to keep. Nothing is lost until you do.`)),
  el('div', { class: 'pair2' }, el('div', { class: 'box' }, miniPreview(editor.profile, changed), el('div', {}, el('b', {}, 'Your draft on this computer'), note(`Based on revision ${editor.revision} · ${plural(changed.size, 'changed control')}`))),
    el('div', { class: 'box' }, miniPreview(entry.profile, theirs), el('div', {}, el('b', {}, `Revision ${entry.revision}`), note(`Saved elsewhere · ${theirs.size ? plural(theirs.size, 'changed control') : 'name or settings changed'}`)))),
  el('div', { class: 'acts' }, link('Export my draft…', () => exportProfile(editor.profile), { style: { marginRight: 'auto' } }),
    btn('Open the newer version', () => { loadEntry(entry); sheet = null; status(`Opened revision ${entry.revision}.`); render(); }, { class: 'btn lg' }),
    btn('Save mine as a copy', () => {
      const next = newProfile(uid('desktop'), editor.profile); next.name = editor.profile.name.endsWith(' copy') ? editor.profile.name : `${editor.profile.name} copy`.slice(0, 80);
      editor.profile = next; editor.revision = 0; persist();
    }, { class: 'btn lg pri', 'data-autofocus': true }))], true);
}
function newSheet() {
  const starters = [...builtInProfiles.map(p => [p, p.name]), [desktopProfile, 'Keyboard and mouse starter']];
  return dialog('new-h', [el('h2', { id: 'new-h' }, 'New controller'), el('p', {}, 'Start from a template. You can change everything after.'),
    el('div', { class: 'cards' }, starters.map(([profile, title]) => el('button', { type: 'button', class: 'card', onClick: () => createController(profile) },
      miniPreview(profile), el('span', { class: 'ct' }, el('b', {}, title), el('span', { class: 'meta' }, plural(profile.controls.length, 'control')))))),
    el('div', { class: 'acts' }, btn('Cancel', closeSheet, { class: 'btn lg', 'data-autofocus': true }))], true);
}
function renameSheet() {
  const entry = snapshot.profiles.find(e => e.profile.id === sheet.entryId);
  if (!entry) { sheet = null; return ''; }
  const input = el('input', { class: 'wide', value: entry.profile.name, maxlength: 80, 'aria-label': 'Controller name', 'data-autofocus': true, onKeydown: e => { if (e.key === 'Enter') go(); } });
  function go() {
    const name = input.value.trim().slice(0, 80); if (!name || name === entry.profile.name) return closeSheet();
    sheet = null;
    perform('save', { profile: { ...copy(entry.profile), name }, expectedProfileRevision: entry.revision, viewport }, () => {
      const next = snapshot.profiles.find(e => e.profile.id === entry.profile.id);
      if (editor.profile.id === entry.profile.id && next) loadEntry(next, true);
      status('Controller renamed.');
    });
  }
  return dialog('rename-h', [el('h2', { id: 'rename-h' }, 'Rename controller'), input, el('div', { class: 'acts' }, btn('Cancel', closeSheet, { class: 'btn lg' }), btn('Rename', go, { class: 'btn lg pri' }))]);
}

/* ---------- keyboard ---------- */
document.addEventListener('keydown', event => {
  if (recording && page === 'design' && editor?.selected) {
    if (event.key === 'Tab') return;
    event.preventDefault(); event.stopPropagation();
    if (event.key === 'Escape') { recording = false; return render(); }
    if (/^(Control|Shift|Alt|Meta)/.test(event.code)) return;
    const key = `key:${event.code}`;
    if (!outputs('key').includes(key)) return status('That key isn’t supported. Choose another.', true);
    const chord = [event.shiftKey && 'key:ShiftLeft', event.ctrlKey && 'key:ControlLeft', event.altKey && 'key:AltLeft', event.metaKey && 'key:MetaLeft', key].filter(Boolean);
    recording = false;
    return tryEdit(() => setChord(editor.profile, editor.selected, [...new Set(chord)]));
  }
  if (sheet) {
    if (event.key === 'Escape' && sheet.kind !== 'conflict') closeSheet();
    if (event.key === 'Tab') {
      const items = [...root.querySelectorAll('.sheet button:not(:disabled), .sheet input')];
      const index = items.indexOf(document.activeElement);
      event.preventDefault(); items[(index + (event.shiftKey ? -1 : 1) + items.length) % items.length]?.focus();
    }
    return;
  }
  if (busy || page !== 'design' || !editor) return;
  const typing = /INPUT|SELECT|TEXTAREA/.test(event.target.tagName);
  const mod = event.metaKey || event.ctrlKey;
  if (mod && event.key.toLowerCase() === 's') { event.preventDefault(); if (editor.dirty) save(); return; }
  if (typing) return;
  if (mod && event.key.toLowerCase() === 'z') { event.preventDefault(); event.shiftKey ? editor.redo() : editor.undo(); return render(); }
  if (!editor.selected) return;
  if (['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown'].includes(event.key)) {
    event.preventDefault(); const n = event.shiftKey ? 10 : 1;
    edit(moveControl(editor.profile, editor.selected, event.key === 'ArrowLeft' ? -n / viewport.width : event.key === 'ArrowRight' ? n / viewport.width : 0, event.key === 'ArrowUp' ? -n / viewport.height : event.key === 'ArrowDown' ? n / viewport.height : 0, event.altKey, viewport));
  } else if (event.key === 'Delete' || event.key === 'Backspace') { event.preventDefault(); remove(editor.selected); }
  else if (event.key === 'Escape') select(null);
});
window.addEventListener('beforeunload', event => { if (editor?.dirty) { event.preventDefault(); event.returnValue = ''; } });

/* ---------- receiver polling ---------- */
let lastSignature = '';
async function refresh() {
  if (busy || dragging || document.hidden) return;
  const epoch = mutationEpoch;
  try {
    const next = await request('snapshot');
    if (epoch !== mutationEpoch || busy || dragging) return;
    snapshot = next;
    if (message.startsWith('Sent.') && acknowledged(next)) status('Phone acknowledged the selected controller. Resume controls on your phone.');
    if (!editor) {
      const active = snapshot.profiles.find(item => item.profile.id === snapshot.active?.profile.id) ?? snapshot.profiles[0];
      editor = new Editor(active?.profile ?? defaultProfile, active?.revision ?? 0);
      lastSignature = signature(next); return render();
    }
    const entry = currentEntry();
    if (entry && editor.revision && entry.revision !== editor.revision) {
      if (!editor.dirty) { loadEntry(entry, true); message = `Updated to revision ${entry.revision}, saved elsewhere.`; }
      else if (conflictSeen !== entry.revision && !sheet) openConflict(entry);
    }
    const sig = signature(next);
    const editing = /INPUT|SELECT|TEXTAREA/.test(document.activeElement?.tagName);
    if ((sig !== lastSignature || sheet?.kind === 'send') && !editing) render();
    else { root.querySelector('.tbar')?.replaceWith(toolbar()); document.querySelector('#statusbar')?.replaceWith(statusbar()); }
    lastSignature = sig;
  } catch (error) {
    if (!snapshot || !editor) root.replaceChildren(el('main', { class: 'page' }, el('h1', {}, 'Studio couldn’t open'), el('p', { class: 'note' }, error.message), el('div', {}, btn('Try again', refresh, { class: 'btn pri' }))));
    else status(error.message, true);
  }
}
// A Qt channel script is loaded by bridge-bootstrap. Wait for its load event
// without masking a missing production bridge behind simulated data.
if (window.qt?.webChannelTransport && !window.QWebChannel) {
  const channelScript = [...document.scripts].find(script => script.src.startsWith('qrc:'));
  channelScript?.addEventListener('load', refresh, { once: true });
  channelScript?.addEventListener('error', () => status('The native connection bridge could not load.', true), { once: true });
} else void refresh();
setInterval(refresh, 1500);
