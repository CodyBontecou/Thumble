import { createHash, randomUUID } from 'node:crypto';
import { assertProfile, bindingChange, utilityActions } from '../../controller/src/index.js';
import { validateConsolePortLayout } from './consoleport.js';
import { gamepadKeys } from './gamepad-keys.js';
export { gamepadKeys } from './gamepad-keys.js';
export { utilityActions };
const labelActions = new Map([['jump', 'JUMP'], ['chat', 'OPENCHAT'], ['target', 'TARGETNEARESTENEMY'], ['bags', 'OPENALLBAGS'], ['map', 'TOGGLEWORLDMAP'], ['menu', 'TOGGLEGAMEMENU'], ['interact', 'INTERACTTARGET']]);
const buttons = new Set(Object.values(gamepadKeys));
const mods = ['', 'SHIFT-', 'CTRL-', 'ALT-', 'CTRL-SHIFT-', 'ALT-SHIFT-', 'ALT-CTRL-', 'ALT-CTRL-SHIFT-'];
const chords = new Set(mods.flatMap(mod => [...buttons].map(key => mod + key)));
const record = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const text = (value, max = 512, empty = false) => typeof value === 'string' && (empty || value.length > 0) && value.length <= max && !/[\x00-\x1f\x7f|]/.test(value);
const integer = (value, min = 1) => Number.isSafeInteger(value) && value >= min && value < 2147483648;
const check = (condition, error) => { if (!condition) throw Error(error); };
function parse(exportText, kind) {
  check(typeof exportText === 'string' && Buffer.byteLength(exportText) <= 262144, 'Paste addon JSON under 256 KiB');
  const value = JSON.parse(exportText);
  check(record(value) && value.bridgeVersion === 1 && value.kind === kind, `Expected Thumble ${kind} export version 1`);
  return value;
}
export function validateCharacter(value) {
  if (value.consolePortLayout !== undefined) validateConsolePortLayout(value.consolePortLayout);
  check(record(value.character) && text(value.snapshotId, 128) && text(value.character.guid, 128) && text(value.character.name, 128) && text(value.character.realm, 128) && text(value.character.class, 40) && integer(value.character.classId) && integer(value.character.specId, 0), 'Invalid character identity');
  check(text(value.build, 32) && integer(value.interface) && integer(value.actionPage) && [1, 2].includes(value.bindingSet) && integer(value.exportedAt), 'Invalid game context or binding scope');
  check(record(value.modifiers) && record(value.reserved) && Object.entries(value.modifiers).every(([name, key]) => text(name, 80) && text(key, 80, true)) && Object.entries(value.reserved).every(([key, reason]) => buttons.has(key) && text(reason, 80)), 'Invalid gamepad modifiers');
  check(Array.isArray(value.bindings) && value.bindings.length <= 256 && Array.isArray(value.spells) && value.spells.length <= 2048 && Array.isArray(value.actions) && value.actions.length <= 300, 'Invalid character collections');
  const keys = new Set(), spells = new Set();
  for (const binding of value.bindings) {
    check(record(binding) && chords.has(binding.key) && !keys.has(binding.key) && text(binding.base, 512, true) && text(binding.effective, 512, true) && (binding.consolePortProxy === undefined || typeof binding.consolePortProxy === 'boolean'), 'Invalid or duplicate gamepad binding');
    keys.add(binding.key);
  }
  check([...buttons].every(key => keys.has(key)), 'Export is missing gamepad buttons');
  for (const spell of value.spells) {
    check(record(spell) && integer(spell.id) && !spells.has(spell.id) && text(spell.name, 256) && typeof spell.passive === 'boolean' && (spell.rank === undefined || text(spell.rank, 128, true)), 'Invalid or duplicate learned spell');
    spells.add(spell.id);
  }
  for (const action of value.actions) check(record(action) && integer(action.slot) && action.slot <= 300 && text(action.type, 40) && (integer(action.id) || text(action.id, 128)) && text(action.name, 512), 'Invalid action slot');
  return value;
}
const bridge = data => data.characterBridge ??= { snapshots: [], plans: [], receipts: [] };
export async function importCharacter(store, exportText) {
  const snapshot = validateCharacter(parse(exportText, 'character'));
  const digest = createHash('sha256').update(JSON.stringify(snapshot)).digest('hex');
  return store.transaction(data => {
    const state = bridge(data), previous = state.snapshots.find(item => item.snapshot.snapshotId === snapshot.snapshotId);
    check(!previous || previous.digest === digest, 'Snapshot ID was already imported with different contents');
    if (!previous) {
      check(state.snapshots.length < 20, 'Character snapshot limit reached (20); archive your store before clearing old snapshots');
      state.snapshots.push({ snapshot, digest });
    }
    return { snapshotId: snapshot.snapshotId, character: snapshot.character, bindingSet: snapshot.bindingSet, spells: snapshot.spells.filter(spell => !spell.passive).length, bindings: snapshot.bindings.length, note: 'Imported addon data. Use get_character to inspect it; no game or phone settings changed.' };
  });
}
export async function getCharacter(store, snapshotId) {
  const data = await store.read();
  const item = bridge(data).snapshots.find(item => item.snapshot.snapshotId === snapshotId);
  check(item, `Unknown character snapshot: ${snapshotId}`);
  return validateCharacter(item.snapshot);
}
export async function listCharacters(store) {
  return bridge(await store.read()).snapshots.map(({ snapshot }) => ({ snapshotId: snapshot.snapshotId, character: snapshot.character, exportedAt: snapshot.exportedAt }));
}
export async function proposeBindings(store, { snapshotId, profileId, profileRevision, intents }) {
  check(integer(profileRevision), 'Invalid profile revision');
  return store.transaction(data => {
    const state = bridge(data);
    const item = state.snapshots.find(item => item.snapshot.snapshotId === snapshotId);
    check(item, `Unknown character snapshot: ${snapshotId}`);
    const snapshot = validateCharacter(item.snapshot);
    const entry = data.profiles.find(item => item.profile.id === profileId);
    check(entry && entry.revision === profileRevision, 'Profile revision conflict; read the profile again');
    const profile = assertProfile(entry.profile);
    const unresolved = [], changes = [], preview = [], used = new Set();
    const learned = snapshot.spells.filter(spell => !spell.passive);
    let requests = intents;
    if (requests === undefined) {
      requests = [];
      for (const control of profile.controls) {
        if (control.type === 'stick') continue;
        const candidates = learned.filter(spell => spell.name.toLowerCase() === control.label.toLowerCase());
        const action = labelActions.get(control.label.toLowerCase());
        if (candidates.length === 1) requests.push({ controlId: control.id, spellId: candidates[0].id });
        else if (action) requests.push({ controlId: control.id, action });
        else unresolved.push({ controlId: control.id, label: control.label, reason: candidates.length > 1 ? 'Several learned ranks match; specify a spellId from get_character.' : 'No learned spell or supported utility matches this label.' });
      }
    }
    check(Array.isArray(requests) && requests.length <= 32, 'intents must be an array of at most 32 changes');
    const seenControls = new Set();
    for (const intent of requests) {
      check(record(intent) && Object.keys(intent).every(key => ['controlId', 'spellId', 'action', 'label'].includes(key)) && text(intent.controlId, 80) && !seenControls.has(intent.controlId), 'Invalid or duplicate intent');
      seenControls.add(intent.controlId);
      const control = profile.controls.find(control => control.id === intent.controlId);
      const mapping = profile.mappings.find(mapping => mapping.controlId === intent.controlId);
      check(control && mapping && control.type !== 'stick' && mapping.outputs.length === 1, `Control ${intent.controlId} must have one gamepad button or trigger output`);
      const key = gamepadKeys[mapping.outputs[0]];
      check(key && !used.has(key), `Two controls propose the same gamepad button: ${key}`); used.add(key);
      const change = bindingChange(snapshot, profile, intent);
      const binding = snapshot.bindings.find(binding => binding.key === key);
      const command = intent.spellId !== undefined ? 'SPELL ' + learned.find(spell => spell.id === intent.spellId).name : intent.action;
      const label = change.label;
      changes.push(change);
      preview.push({ controlId: control.id, key, label, before: binding.base || 'Unbound', after: command, replacesExisting: binding.base !== '' && binding.base !== command });
    }
    if (!changes.length) return { plan: null, unresolved, note: 'No supported changes matched. Inspect get_character and supply explicit intents using learned spell IDs.' };
    check(state.plans.length < 100, 'Binding plan limit reached (100)');
    const plan = { bridgeVersion: 1, kind: 'binding-plan', id: randomUUID(), snapshotId, characterGuid: snapshot.character.guid, bindingSet: snapshot.bindingSet, profile: { id: profile.id, revision: entry.revision, name: profile.name }, changes };
    state.plans.push({ plan, preview });
    return { plan, preview, unresolved, copyToAddon: JSON.stringify(plan), note: `PROPOSED ONLY. Paste copyToAddon into /thumblebridge, review ${snapshot.bindingSet === 1 ? 'ACCOUNT-wide' : 'character'} scope, and click Apply outside combat. No game or phone bindings have changed.` };
  });
}
export async function getBindingPlan(store, planId) {
  check(text(planId, 80), 'Invalid plan ID');
  const item = bridge(await store.read()).plans.find(item => item.plan.id === planId);
  check(item, `Unknown binding plan: ${planId}`);
  return item;
}
export async function importBindingResult(store, exportText) {
  const receipt = parse(exportText, 'binding-receipt');
  check(receipt.status === 'verified' && text(receipt.planId, 80) && text(receipt.snapshotId, 128) && text(receipt.characterGuid, 128) && integer(receipt.appliedAt) && [1, 2].includes(receipt.bindingSet) && Array.isArray(receipt.results), 'Invalid binding result');
  return store.transaction(data => {
    const state = bridge(data), item = state.plans.find(item => item.plan.id === receipt.planId);
    check(item, 'Unknown binding plan');
    const { plan, preview } = item;
    check(receipt.snapshotId === plan.snapshotId && receipt.characterGuid === plan.characterGuid && receipt.bindingSet === plan.bindingSet && record(receipt.profile) && receipt.profile.id === plan.profile.id && receipt.profile.revision === plan.profile.revision && receipt.results.length === plan.changes.length, 'Result does not match the proposed character, scope, profile or changes');
    const seen = new Set();
    for (const result of receipt.results) {
      const expected = preview.find(row => row.key === result.key && row.controlId === result.controlId);
      check(expected && !seen.has(result.key) && result.command === expected.after && result.base === expected.after && result.effective === expected.after, 'Result includes missing, duplicate or unconfirmed bindings');
      seen.add(result.key);
    }
    const previous = state.receipts.findIndex(item => item.planId === plan.id);
    if (previous >= 0) state.receipts[previous] = receipt; else state.receipts.push(receipt);
    return { planId: plan.id, status: 'receipt-confirmed', results: receipt.results, note: 'Addon-reported result matches the proposal. Use sync_binding_labels to save matching labels, then explicitly activate the saved phone profile. This result is a point-in-time export, not continuous game telemetry.' };
  });
}
export async function syncBindingLabels(store, planId, expectedRevision) {
  check(text(planId, 80) && integer(expectedRevision), 'Invalid plan or profile revision');
  return store.transaction(data => {
    const state = bridge(data), item = state.plans.find(item => item.plan.id === planId);
    check(item && state.receipts.some(receipt => receipt.planId === planId), 'Import a confirmed addon result before synchronizing labels');
    const {plan} = item;
    const entry = data.profiles.find(entry => entry.profile.id === plan.profile.id);
    check(entry && entry.revision === expectedRevision && entry.revision === plan.profile.revision, 'Profile changed after the proposal; create a new plan before syncing');
    const profile = assertProfile(entry.profile);
    for (const change of plan.changes) {
      const control = profile.controls.find(control => control.id === change.controlId);
      const mapping = profile.mappings.find(mapping => mapping.controlId === change.controlId);
      check(control && mapping.outputs.length === 1 && gamepadKeys[mapping.outputs[0]] === change.key, 'Controller mapping changed');
      control.label = change.label;
    }
    entry.profile = assertProfile(profile); entry.revision += 1;
    return { ...entry, note: 'Matching labels saved. Explicitly activate this new revision to push it to the phone. Re-export character data if in-game bindings change later.' };
  });
}
