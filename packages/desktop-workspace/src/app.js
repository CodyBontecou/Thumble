import { Editor, copy, newProfile, canvasSize, outputNames, outputs, issues, moveControl, updateControl, setOutput, addControl, removeControl, acknowledged, signature, controlBox, labelColor, profileState } from './model.js';
import { defaultProfile } from '../../controller/src/index.js';
import { request } from './bridge.js';

const root = document.querySelector('#app');
let snapshot, editor, page = 'design', message = '', failure = false, busy = false, dragging = false;
let viewport = { ...canvasSize };
let mutationEpoch = 0;
const uid = prefix => `${prefix}-${crypto.randomUUID().replaceAll('-', '')}`;
const el = (tag, attrs = {}, ...children) => {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs)) {
    if (key.startsWith('on')) node.addEventListener(key.slice(2).toLowerCase(), value);
    else if (key === 'class') node.className = value;
    else if (key === 'value') node.value = value;
    else if (key === 'checked' || key === 'disabled') node[key] = !!value;
    else if (key === 'style') Object.assign(node.style, value);
    else if (value !== undefined && value !== null) node.setAttribute(key, value);
  }
  for (const child of children.flat(Infinity)) if (child !== undefined && child !== null && child !== false) node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  return node;
};
const button = (text, action, attrs = {}) => el('button', { type: 'button', onClick: () => action(), ...attrs }, text);
const actions = (...children) => el('div', { class: 'actions' }, children);
const small = text => el('p', { class: 'muted' }, text);
const field = (label, node, help) => el('label', { class: 'field' }, label, node, help && el('span', { class: 'field-help' }, help));
const currentEntry = () => snapshot?.profiles.find(entry => entry.profile.id === editor?.profile.id);
window.thumbleHasUnsavedChanges = () => !!editor?.dirty;
const dirtyConfirm = action => {
  if (!editor?.dirty) return action();
  confirmDialog('Discard unsaved changes?', 'Your last saved controller will remain available.', 'Discard changes', action);
};

function confirmDialog(title, detail, confirm, action) {
  const previous = document.activeElement;
  const cancel = button('Cancel', () => close());
  const okay = button(confirm, () => { close(); action(); }, { class: 'primary' });
  const dialog = el('div', { class: 'dialog-backdrop' }, el('section', { class: 'dialog', role: 'dialog', 'aria-modal': 'true', 'aria-label': title }, el('h2', {}, title), el('p', {}, detail), actions(cancel, okay)));
  function close() { dialog.remove(); previous?.focus(); }
  dialog.addEventListener('keydown', e => {
    if (e.key === 'Escape') close();
    if (e.key === 'Tab') { e.preventDefault(); (document.activeElement === cancel ? okay : cancel).focus(); }
  });
  document.body.append(dialog); cancel.focus();
}

function status(text, error = false) { message = text; failure = error; renderStatus(); }
async function perform(operation, payload = {}, success) {
  if (busy) return;
  mutationEpoch++;
  busy = true; renderActions();
  try {
    const result = await request(operation, payload);
    if (result?.profiles) snapshot = result;
    if (success) await success(result);
    return result;
  } catch (error) { status(error.message, true); }
  finally { busy = false; render(); }
}

function loadEntry(entry) {
  editor = new Editor(entry.profile, entry.revision);
  message = ''; failure = false; render();
}
function edit(profile) {
  editor.commit(profile);
  status('Unsaved changes');
  renderCanvas(); renderInspector(); renderLayers(); renderActions();
}
function save() {
  const problems = issues(editor.profile, viewport);
  if (problems.length) { status(problems[0], true); return; }
  if (currentEntry() && !currentEntry().editable) {
    confirmDialog('Save your own copy?', 'Built-in and synced controllers stay intact. Your changes will be saved as a new controller.', 'Save copy', () => {
      const next = newProfile(uid('desktop'), editor.profile);
      next.name = editor.profile.name.endsWith(' copy') ? editor.profile.name : `${editor.profile.name} copy`.slice(0, 80);
      editor.profile = next; editor.revision = 0; persist();
    });
  } else persist();
}
function persist() {
  const profile = copy(editor.profile);
  perform('save', { profile, expectedProfileRevision: editor.revision, viewport }, () => {
    const entry = snapshot.profiles.find(item => item.profile.id === profile.id);
    editor.load(profile, entry.revision);
    status('Saved on this computer. Send to phone when you’re ready.');
  });
}
function send() {
  if (editor.dirty) return status('Save this controller before sending it to your phone.', true);
  perform('activate', { profileId: editor.profile.id, profileRevision: editor.revision, expectedActivationRevision: snapshot.activationRevision, viewport }, () => {
    status(snapshot.receiver.connected ? 'Sent. Waiting for the phone to acknowledge this layout.' : 'Selected. This controller will be sent when your phone connects.');
  });
}

function render() {
  if (!snapshot || !editor) return;
  root.replaceChildren(header(), page === 'design' ? design() : page === 'controllers' ? controllers() : connections(), statusbar());
}
function header() {
  const receiver = snapshot.receiver;
  return el('header', {}, el('div', { class: 'brand' }, 'thumble', el('span', {}, '.'), el('span', { class: 'studio' }, 'STUDIO')),
    el('nav', { 'aria-label': 'Workspace' }, ...[['design', 'Design'], ['controllers', 'Controllers'], ['connections', 'Connections']].map(([key, title]) => button(title, () => { page = key; render(); }, { 'aria-current': page === key ? 'page' : undefined }))),
    snapshot.simulated && el('span', { class: 'preview-flag' }, 'SIMULATED RECEIVER'),
    el('div', { class: 'connection-chip' }, el('span', { class: `dot ${receiver.connected ? 'online' : ''}` }), receiver.connected ? 'Phone connected' : receiver.running ? 'Ready to pair' : 'Receiver unavailable'));
}
function toolbarActions() {
  return actions(button(editor.dirty ? 'Export draft' : 'Export', () => exportProfile(editor.profile), { disabled: busy }), button('Undo', () => { editor.undo(); render(); }, { disabled: busy || !editor.past.length, title: 'Undo (⌘/Ctrl Z)' }), button('Redo', () => { editor.redo(); render(); }, { disabled: busy || !editor.future.length }),
    button('Save controller', save, { disabled: busy || !editor.dirty, class: 'accent' }), button('Send to phone', send, { disabled: busy || editor.dirty || !currentEntry(), class: 'primary' }));
}
function design() {
  const toolbar = el('div', { class: 'toolbar' }, el('div', {}, el('h1', {}, editor.profile.name), el('small', {}, editor.dirty ? 'Unsaved changes' : `Revision ${editor.revision || 'new'} · ${currentEntry()?.editable ? 'Your controller' : 'Original controller'}`)), el('div', { id: 'toolbar-actions' }, toolbarActions()));
  const sidebar = el('aside', { class: 'sidebar', 'aria-label': 'Controllers and controls' }, el('p', { class: 'eyebrow' }, 'Your controllers'),
    snapshot.profiles.map(entry => button([el('strong', {}, entry.profile.name), el('small', {}, profileState(entry, snapshot) === 'selected' ? 'Selected for phone' : profileState(entry, snapshot) === 'draft' ? `Draft r${entry.revision} · phone r${snapshot.active.profileRevision}` : entry.editable ? 'Custom controller' : 'Original')], () => dirtyConfirm(() => loadEntry(entry)), { class: 'profile-row', 'aria-pressed': editor.profile.id === entry.profile.id })),
    button('+ New controller', createController, { class: 'new' }), el('hr', { class: 'separator' }), el('p', { class: 'eyebrow' }, 'Controls'), el('div', { id: 'layers' }, layers()));
  const center = el('section', { class: 'canvas-region', 'aria-label': 'Design canvas' }, el('div', { class: 'canvas-heading' }, el('span', {}, 'LANDSCAPE CONTROLLER'), el('span', {}, `${viewport.width} × ${viewport.height} PT`)), el('div', { class: 'device' }, el('div', { id: 'canvas', class: 'canvas', role: 'group', 'aria-label': 'Controller layout', tabIndex: 0, style: { aspectRatio: `${viewport.width}/${viewport.height}` } })),
    el('p', { class: 'canvas-caption' }, 'Select a control to edit it. Drag to move; drag its corner to resize. Arrow keys nudge, Shift moves faster.'), el('div', { class: 'canvas-tools' }, button('+ Button', () => add('button')), button('+ Trigger', () => add('trigger')), button('+ Stick', () => add('stick'))));
  const inspector = el('aside', { id: 'inspector', class: 'inspector', 'aria-label': 'Control inspector' });
  const container = el('div', {}, toolbar, el('main', { class: 'workspace' }, sidebar, center, inspector));
  queueMicrotask(() => { renderCanvas(); renderInspector(); });
  return container;
}
function layers() {
  return editor.profile.controls.map(control => button([el('span', { class: 'control-icon' }, control.type === 'stick' ? '◎' : control.type === 'trigger' ? '▱' : '○'), control.customLabel ?? control.label], () => { editor.selected = control.id; renderCanvas(); renderInspector(); renderLayers(); }, { class: 'control-row', 'aria-pressed': editor.selected === control.id }));
}
function renderLayers() { document.querySelector('#layers')?.replaceChildren(...layers()); }
function renderActions() { document.querySelector('#toolbar-actions')?.replaceChildren(toolbarActions()); }
function renderStatus() {
  const bar = document.querySelector('#statusbar'); if (bar) bar.replaceWith(statusbar());
}
function statusbar() {
  return el('footer', { id: 'statusbar', class: `statusbar ${failure ? 'error' : ''}`, role: 'status', 'aria-live': 'polite' }, el('span', { class: `dot ${failure ? '' : 'online'}` }), message || snapshot?.receiver.detail || 'Opening receiver…', el('span', { class: 'right' }, snapshot?.platform ?? 'Desktop'));
}
function renderCanvas() {
  const canvas = document.querySelector('#canvas'); if (!canvas) return;
  canvas.replaceChildren(el('span', { class: 'chrome chat' }, 'CHAT'), el('span', { class: 'chrome menu' }, 'MENU'));
  for (const control of editor.profile.controls) {
    const f = controlBox(control, viewport);
    const node = button(el('span', { class: 'control-label', style: { color: labelColor(control.color) } }, control.customLabel ?? control.label), () => {}, { class: `pad-control ${editor.selected === control.id ? 'selected' : ''}`, 'aria-label': `${control.customLabel ?? control.label}, ${control.type}`, 'aria-pressed': editor.selected === control.id, 'data-id': control.id, 'data-type': control.type, style: { left: `${f.x * 100}%`, top: `${f.y * 100}%`, width: `${f.width * 100}%`, height: `${f.height * 100}%`, ...(control.color ? { backgroundColor: control.color } : {}) } });
    if (editor.selected === control.id) node.append(el('span', { class: 'resize', 'aria-label': 'Resize control', role: 'presentation' }));
    node.addEventListener('pointerdown', event => beginDrag(event, control.id));
    node.addEventListener('keydown', event => {
      if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); editor.selected = control.id; renderCanvas(); renderInspector(); renderLayers(); }
    });
    canvas.append(node);
  }
}
function beginDrag(event, id) {
  if (event.button !== 0 || dragging || busy) return;
  event.preventDefault(); editor.selected = id;
  const original = copy(editor.profile), startX = event.clientX, startY = event.clientY;
  const resize = event.target.classList.contains('resize');
  const node = event.currentTarget;
  const bounds = document.querySelector('#canvas').getBoundingClientRect();
  node.classList.add('selected');
  for (const sibling of node.parentElement.querySelectorAll('.pad-control')) if (sibling !== node) sibling.classList.remove('selected');
  renderInspector(); renderLayers();
  dragging = true; node.setPointerCapture(event.pointerId);
  const move = e => {
    if (e.pointerId !== event.pointerId) return;
    const profile = moveControl(original, id, (e.clientX - startX) / bounds.width, (e.clientY - startY) / bounds.height, resize, viewport);
    const f = controlBox(profile.controls.find(c => c.id === id), viewport);
    Object.assign(node.style, { left: `${f.x * 100}%`, top: `${f.y * 100}%`, width: `${f.width * 100}%`, height: `${f.height * 100}%` });
    editor.profile = profile;
  };
  const end = e => {
    if (e.pointerId !== event.pointerId) return;
    node.removeEventListener('pointermove', move); node.removeEventListener('pointerup', end); node.removeEventListener('pointercancel', cancel); node.removeEventListener('lostpointercapture', cancel);
    const next = editor.profile; editor.profile = original; editor.commit(next); dragging = false;
    status(editor.dirty ? 'Unsaved changes' : 'Controller unchanged'); renderCanvas(); renderInspector(); renderActions();
  };
  const cancel = () => {
    node.removeEventListener('pointermove', move); node.removeEventListener('pointerup', end); node.removeEventListener('pointercancel', cancel); node.removeEventListener('lostpointercapture', cancel);
    editor.profile = original; dragging = false; renderCanvas(); renderInspector();
  };
  node.addEventListener('pointermove', move); node.addEventListener('pointerup', end); node.addEventListener('pointercancel', cancel); node.addEventListener('lostpointercapture', cancel);
}
function textInput(value, action, attrs = {}) { return el('input', { value, onChange: e => action(e.target.value), ...attrs }); }
function renderInspector() {
  const target = document.querySelector('#inspector'); if (!target) return;
  const control = editor.profile.controls.find(c => c.id === editor.selected);
  const title = el('div', {}, el('h2', {}, control ? outputNames[editor.profile.mappings.find(m => m.controlId === control.id)?.outputs[0]] ?? control.type : 'Controller settings'), small(control ? `${control.type} · ${control.id}` : 'Select a control on the canvas to edit it.'));
  const content = [title, field('Controller name', textInput(editor.profile.name, name => { edit({ ...editor.profile, name }); }, { maxlength: 80, 'aria-label': 'Controller name' }))];
  if (control) {
    const mapping = editor.profile.mappings.find(m => m.controlId === control.id);
    content.push(el('hr', { class: 'separator' }), field('Button label', textInput(control.customLabel ?? control.label, label => edit(updateControl(editor.profile, control.id, { label, customLabel: label })), { maxlength: 80, 'aria-label': 'Button label' })),
      field('Gamepad output', el('select', { 'aria-label': 'Gamepad output', onChange: e => { try { edit(setOutput(editor.profile, control.id, e.target.value)); } catch (error) { status(error.message, true); } } }, outputs(control.type).map(output => el('option', { value: output, selected: output === mapping.outputs[0] ? 'selected' : undefined }, outputNames[output] ?? output)))),
      field('Control color', textInput(control.color ?? '#3c473d', color => edit(updateControl(editor.profile, control.id, { color })), { type: 'color', 'aria-label': 'Control color' })));
    for (const pair of [['x', 'y'], ['width', 'height']]) content.push(el('div', { class: 'field-pair' }, pair.map(key => field(key === 'x' ? 'Left' : key === 'y' ? 'Top' : key === 'width' ? 'Width' : 'Height', textInput(Math.round(control.frame[key] * viewport[key === 'x' || key === 'width' ? 'width' : 'height']), value => {
      const dimension = key === 'x' || key === 'width' ? 'width' : 'height', n = Number(value);
      if (!Number.isFinite(n)) return;
      const frame = { ...control.frame, [key]: n / viewport[dimension] };
      edit(updateControl(editor.profile, control.id, { frame }));
    }, { type: 'number', min: 0, max: viewport[key === 'x' || key === 'width' ? 'width' : 'height'], 'aria-label': `Control ${key}` })))));
    if (control.type === 'stick') {
      for (const [key, label, min, max, fallback] of [['deadzone', 'Deadzone', 0, .5, .1], ['sensitivity', 'Sensitivity', .1, 3, 1]]) content.push(field(label, textInput(mapping[key] ?? fallback, value => { const n = Number(value); if (Number.isFinite(n)) edit(setOutput(editor.profile, control.id, mapping.outputs[0], { [key]: n })); }, { type: 'number', min, max, step: .01, 'aria-label': label })));
      for (const [key, label] of [['invertX', 'Invert horizontal'], ['invertY', 'Invert vertical']]) content.push(field(label, el('input', { type: 'checkbox', checked: mapping[key], onChange: e => edit(setOutput(editor.profile, control.id, mapping.outputs[0], { [key]: e.target.checked })) })));
    }
    content.push(button('Remove control', () => { try { edit(removeControl(editor.profile, control.id)); editor.selected = null; renderInspector(); } catch (error) { status(error.message, true); } }, { class: 'delete danger' }));
  } else {
    content.push(el('hr', { class: 'separator' }), field('Canvas size', el('select', { 'aria-label': 'Canvas size', onChange: e => { const [width, height] = e.target.value.split('x').map(Number); viewport = { width, height }; render(); } }, [[844,390], [852,393], [932,430], [780,360]].map(([w,h]) => el('option', { value: `${w}x${h}`, selected: viewport.width === w ? 'selected' : undefined }, `${w} × ${h} points`)))), small('Validation uses this usable phone canvas. The layout scales to fit the connected phone.'));
  }
  const problems = issues(editor.profile, viewport);
  if (problems.length) content.push(el('div', { class: 'validation', role: 'alert' }, el('strong', {}, `${problems.length} layout ${problems.length === 1 ? 'issue' : 'issues'}`), el('ul', {}, problems.slice(0, 5).map(problem => el('li', {}, problem)))));
  else content.push(small('✓ Touch targets and spacing checked'));
  target.replaceChildren(...content);
}
function add(type) {
  try { const profile = addControl(editor.profile, type, uid(type), viewport); editor.selected = profile.controls.at(-1).id; edit(profile); }
  catch (error) { status(error.message, true); }
}
function createController(source = defaultProfile) {
  dirtyConfirm(() => { editor = new Editor(newProfile(uid('desktop'), source), 0); editor.saved = null; page = 'design'; status('New controller. Save it when you’re ready.'); render(); });
}
function exportProfile(profile) { perform('export', { profile }, result => status(result.exported ? 'Controller exported.' : 'Export cancelled.')); }
function controllers() {
  return el('main', { class: 'panel-page' }, el('h1', {}, 'A controller for every setup.'), el('p', { class: 'intro' }, 'Design on your computer. Keep originals intact, save your own controllers, and send a specific revision to your phone.'),
    actions(button('+ New controller', () => createController(), { class: 'primary' }), field('Import controller JSON', el('input', { type: 'file', accept: '.json,application/json', 'aria-label': 'Import controller JSON', onChange: async e => {
      const file = e.target.files[0]; if (!file) return;
      if (file.size > 60000) return status('Choose a controller JSON file smaller than 60 KB.', true);
      try {
        const profile = JSON.parse(await file.text());
        const problems = issues(profile, viewport); if (problems.length) throw Error(problems[0]);
        createController(profile);
      } catch (error) { status(`Could not import controller: ${error.message}`, true); }
    } }))), el('div', { class: 'cards', style: { marginTop: '24px' } }, snapshot.profiles.map(entry => {
      const selected = snapshot.active?.profile.id === entry.profile.id;
      const state = profileState(entry, snapshot);
      return el('article', { class: 'card' }, el('span', { class: 'badge' }, state === 'selected' ? 'SELECTED FOR PHONE' : state === 'draft' ? `NEWER DRAFT · PHONE USES REVISION ${snapshot.active.profileRevision}` : entry.editable ? 'YOUR CONTROLLER' : 'ORIGINAL'), el('h2', {}, entry.profile.name), el('p', {}, `${entry.profile.controls.length} controls · revision ${entry.revision}`), actions(
        button('Open in editor', () => dirtyConfirm(() => { loadEntry(entry); page = 'design'; render(); })), button('Duplicate', () => createController(entry.profile)), button('Export', () => exportProfile(entry.profile)),
        entry.editable && button('Delete', () => confirmDialog('Delete this controller?', 'This removes the saved controller from this computer. Export a copy first if you want a backup.', 'Delete controller', () => perform('delete', { profileId: entry.profile.id, expectedProfileRevision: entry.revision, expectedActivationRevision: snapshot.activationRevision }, () => { if (editor.profile.id === entry.profile.id) loadEntry(snapshot.profiles[0]); status('Controller deleted.'); })), { class: 'danger', disabled: selected || busy, title: selected ? 'Select another controller before deleting this one.' : 'Delete saved controller' })));
    })));
}
function connections() {
  const receiver = snapshot.receiver, settings = snapshot.settings ?? {};
  return el('main', { class: 'panel-page' }, el('h1', {}, 'Your phone. Your computer.'), el('p', { class: 'intro' }, 'Keep both devices on the same Wi-Fi. Pair once, then manage your controller and connection here.'), el('div', { class: 'cards' },
    el('section', { class: 'card' }, el('span', { class: 'badge' }, receiver.connected ? 'PHONE CONNECTED' : 'PAIR A PHONE'), el('h2', {}, receiver.connected ? 'Connection established' : 'Scan with Thumble'), el('p', {}, receiver.connected ? 'Your phone is connected over the local network.' : 'Open Thumble on your phone and scan the receiver’s current pairing code.'),
      snapshot.pairing?.png ? el('img', { class: 'qr', alt: 'Current phone pairing QR code', src: `data:image/png;base64,${snapshot.pairing.png}` }) : small(receiver.connected ? 'Pairing code hidden while connected.' : 'A pairing code appears when the receiver is ready.'),
      actions(button('Copy pairing link', () => perform('copy-pairing'), { disabled: !snapshot.pairing?.png }), button('Disconnect', () => perform('disconnect', {}, () => status('Phone disconnected. Remembered pairing retained.')), { disabled: !receiver.connected }), button('Forget phone', () => confirmDialog('Forget this phone?', 'The phone will need to scan a new pairing code before reconnecting.', 'Forget phone', () => perform('forget')), { class: 'quiet danger' }))),
    el('section', { class: 'card' }, el('span', { class: 'badge' }, receiver.running ? 'RECEIVER RUNNING' : 'SETUP NEEDED'), el('h2', {}, 'Controller connection'), el('p', {}, receiver.detail), small(`Selected: ${snapshot.active?.profile.name ?? 'Built-in controller'}`), small(acknowledged(snapshot) ? 'Phone acknowledged the selected layout. Controls resume from the phone.' : receiver.connected ? 'Waiting for the phone’s layout acknowledgement.' : 'Connect a phone to verify delivery.'),
      actions(button('Retry receiver', () => perform('retry')), button('Driver & permissions', () => perform('setup-driver')))),
    el('section', { class: 'card' }, el('h2', {}, 'World of Warcraft'), el('p', {}, snapshot.sync?.detail ?? 'Configure your WoW folder to sync ConsolePort labels after /reload.'),
      field('Sync ConsolePort labels', el('input', { type: 'checkbox', checked: settings.syncEnabled, onChange: e => perform('settings', { syncEnabled: e.target.checked }) })), small((settings.wowPaths ?? []).join('\n') || 'No WoW folder selected'), actions(button('Choose WoW folder', () => perform('choose-wow-folder')))),
    el('section', { class: 'card' }, el('h2', {}, 'Receiver settings'), field('Start when I sign in', el('input', { type: 'checkbox', checked: settings.startAtLogin, onChange: e => perform('settings', { startAtLogin: e.target.checked }) })), small('Input stays paused after switching controllers until you resume it on your phone.'), snapshot.simulated && field('Simulated connection', el('select', { 'aria-label': 'Simulated connection', onChange: e => perform('simulate', { state: e.target.value }) }, ['connected', 'disconnected', 'missing-driver', 'pending', 'stale-edit'].map(state => el('option', { value: state, selected: snapshot.scenario === state ? 'selected' : undefined }, state)))))));
}

document.addEventListener('keydown', event => {
  if (page !== 'design' || document.querySelector('[role=dialog]') || /INPUT|SELECT|TEXTAREA/.test(event.target.tagName)) return;
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 's') { event.preventDefault(); save(); }
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'z') { event.preventDefault(); event.shiftKey ? editor.redo() : editor.undo(); render(); }
  if (editor?.selected && ['ArrowLeft','ArrowRight','ArrowUp','ArrowDown'].includes(event.key)) {
    event.preventDefault(); const n = event.shiftKey ? 10 : 1;
    edit(moveControl(editor.profile, editor.selected, event.key === 'ArrowLeft' ? -n/viewport.width : event.key === 'ArrowRight' ? n/viewport.width : 0, event.key === 'ArrowUp' ? -n/viewport.height : event.key === 'ArrowDown' ? n/viewport.height : 0, event.altKey, viewport));
  }
  if (event.key === 'Escape' && editor) { editor.selected = null; renderCanvas(); renderInspector(); renderLayers(); }
});
window.addEventListener('beforeunload', event => { if (editor?.dirty) { event.preventDefault(); event.returnValue = ''; } });
async function refresh() {
  if (busy || dragging || document.hidden) return;
  const epoch = mutationEpoch;
  try {
    const next = await request('snapshot');
    if (epoch !== mutationEpoch || busy || dragging) return;
    const previous = snapshot;
    snapshot = next;
    if (message.startsWith('Sent.') && acknowledged(next)) status('Phone acknowledged the selected controller. Resume controls on your phone.');
    if (!editor) {
      const active = snapshot.profiles.find(item => item.profile.id === snapshot.active?.profile.id) ?? snapshot.profiles[0];
      editor = new Editor(active?.profile ?? defaultProfile, active?.revision ?? 0); render();
    } else {
      const entry = currentEntry();
      if (entry && entry.revision !== editor.revision) {
        if (!editor.dirty) editor.load(entry.profile, entry.revision);
        else status('This controller changed elsewhere. Export your draft or reopen the saved controller before saving.', true);
      }
      if (!document.querySelector('[role=dialog]') && !/INPUT|SELECT|TEXTAREA/.test(document.activeElement?.tagName)) {
        if (page === 'connections' || signature(previous?.profiles) !== signature(next.profiles)) render();
        else { document.querySelector('header')?.replaceWith(header()); renderActions(); renderStatus(); }
      }
    }
  } catch (error) {
    if (!snapshot || !editor) root.replaceChildren(el('main', { class: 'panel-page' }, el('h1', {}, 'The workspace couldn’t open.'), el('p', { class: 'intro' }, error.message), button('Try again', refresh, { class: 'primary' })));
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
