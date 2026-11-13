import test from 'node:test';
import assert from 'node:assert/strict';
import { defaultProfile } from '../../controller/src/index.js';
import { Editor, copy, newProfile, moveControl, addControl, removeControl, setOutput, setChord, updateControl, desktopProfile, issues, acknowledged, controlBox, labelColor, profileState } from '../src/model.js';

test('undo/redo restores the exact saved profile and does not mutate originals', () => {
  const editor = new Editor(defaultProfile, 1), original = copy(defaultProfile);
  const id = editor.profile.controls[0].id;
  editor.commit(moveControl(editor.profile, id, .03, 0));
  assert.equal(editor.dirty, true);
  editor.undo(); assert.equal(editor.dirty, false);
  editor.redo(); assert.equal(editor.dirty, true);
  editor.markSaved(2); assert.equal(editor.dirty, false);
  editor.undo(); assert.equal(editor.dirty, true);
  assert.deepEqual(defaultProfile, original);
});
test('resize and movement remain within canvas and minimum logical touch sizes', () => {
  const profile = newProfile('desktop-'+'a'.repeat(32));
  const id = profile.controls.find(c => c.type === 'stick').id;
  const resized = moveControl(profile, id, -9, -9, true);
  const frame = resized.controls.find(c => c.id === id).frame;
  assert.ok(frame.width * 844 >= 96 && frame.height * 390 >= 96);
  const moved = moveControl(resized, id, 99, -99).controls.find(c => c.id === id).frame;
  assert.equal(moved.y, 0); assert.ok(moved.x + moved.width <= 1.000001);
});
test('new control finds safe space; removing it restores a semantically clean editor', () => {
  const editor = new Editor(defaultProfile, 1);
  editor.commit(addControl(editor.profile, 'button', 'new-button'));
  assert.deepEqual(issues(editor.profile), []);
  editor.commit(removeControl(editor.profile, 'new-button'));
  assert.equal(editor.dirty, false);
});
test('analog outputs cannot be assigned twice, and incompatible outputs fail', () => {
  const stick = defaultProfile.controls.find(c => c.type === 'stick');
  const output = defaultProfile.mappings.find(m => m.controlId === stick.id).outputs[0];
  assert.throws(() => setOutput(defaultProfile, stick.id, output === 'lx' ? 'rx' : 'lx'), /already assigned/);
  assert.throws(() => setOutput(defaultProfile, stick.id, 'a'), /compatible/);
});
test('blank names, overlapping controls and malformed profiles cannot be saved', () => {
  assert.match(issues({ ...copy(defaultProfile), name: '  ' })[0], /name/);
  const profile = copy(defaultProfile);
  profile.controls[0].frame = copy(profile.controls[1].frame);
  assert.ok(issues(profile).some(message => /overlap/.test(message)));
  assert.ok(issues({ arbitrary: 'object' }).length > 0);
});
test('an old phone acknowledgement cannot confirm a newer selected controller', () => {
  const snapshot = { activationRevision: 3, receiver: { running: true, connected: true, layoutAcknowledged: true, revision: 2 } };
  assert.equal(acknowledged(snapshot), false);
  snapshot.receiver.revision = 3; assert.equal(acknowledged(snapshot), true);
  snapshot.receiver.connected = false; assert.equal(acknowledged(snapshot), false);
});
test('native JSON key order does not create false edits or undo steps', () => {
  const editor = new Editor(defaultProfile, 1);
  const reordered = Object.fromEntries(Object.entries(copy(defaultProfile)).reverse());
  editor.commit(reordered);
  assert.equal(editor.dirty, false); assert.equal(editor.past.length, 0);
});
test('stick preview matches the actual centered circular touch area', () => {
  const control = { type: 'stick', frame: { x: .1, y: .2, width: .3, height: .3 } };
  const box = controlBox(control);
  assert.ok(Math.abs(box.width * 844 - box.height * 390) < .0001);
  assert.ok(Math.abs(box.x + box.width/2 - .25) < .0001);
  assert.ok(Math.abs(box.y + box.height/2 - .35) < .0001);
});
test('bright custom controls use dark labels and dark controls use light labels', () => {
  assert.equal(labelColor('#ffdd44'), '#000000');
  assert.equal(labelColor('#ffffff'), '#000000');
  assert.equal(labelColor('#101a13'), '#ffffff');
});
test('a newer saved draft is not presented as the revision selected for the phone', () => {
  const entry = { profile: { id: 'desktop-test' }, revision: 2 };
  const snapshot = { active: { profile: { id: 'desktop-test' }, profileRevision: 1 } };
  assert.equal(profileState(entry, snapshot), 'draft');
  snapshot.active.profileRevision = 2; assert.equal(profileState(entry, snapshot), 'selected');
  snapshot.active.profile.id = 'another'; assert.equal(profileState(entry, snapshot), 'saved');
});

test('a key control face follows its keys unless the player renamed it', () => {
  let profile = addControl(desktopProfile, 'key', 'jump');
  assert.equal(profile.controls.at(-1).label, 'A');
  profile = setOutput(profile, 'jump', 'key:Digit1');
  assert.equal(profile.controls.at(-1).label, '1');
  profile = setChord(profile, 'jump', ['key:Digit1', 'key:ShiftLeft']);
  assert.equal(profile.controls.at(-1).label, 'Shift+1');
  profile = updateControl(profile, 'jump', { label: 'Potion', customLabel: 'Potion' });
  profile = setChord(profile, 'jump', ['key:Digit2']);
  assert.equal(profile.controls.at(-1).label, 'Potion');
  assert.equal(setOutput(desktopProfile, 'left-click', 'mouse:right').controls.find(control => control.id === 'left-click').label, 'Left click', 'mouse labels are untouched');
});
