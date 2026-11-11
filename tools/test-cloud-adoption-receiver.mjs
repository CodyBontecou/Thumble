// Actual TLS receiver + production phone state machine, with a non-HID test stub.
import { spawn } from 'node:child_process';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { once } from 'node:events';
import { dirname, join } from 'node:path';
import { createHash } from 'node:crypto';
import assert from 'node:assert/strict';
import WebSocket from 'ws';
import { Connection } from '../apps/mobile/src/connection-core.js';
import { xboxProfile, parseInvitation, neutralState, bindingChange } from '@tapping/controller';
import { ProfileStore } from '../packages/profile-tools/src/store.js';
const fixture = spawn(process.execPath, ['tools/test-onboarding-receiver.mjs', '--preview'], { stdio: ['ignore', 'pipe', 'pipe'] });
let output = ''; fixture.stdout.on('data', d => { output += d; }); fixture.stderr.on('data', d => { output += d; });
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(read, timeout = 30000) { const end = Date.now() + timeout; while (Date.now() < end) { const value = await read(); if (value) return value; await pause(20); } throw Error('Receiver integration timed out: ' + output); }
let socket, connection;
try {
  await until(() => output.includes('preview ready'));
  const invitationPath = await readFile('build/onboarding-preview-invitation', 'utf8');
  const directory = await readFile('build/onboarding-preview-directory', 'utf8');
  const invitation = await readFile(invitationPath, 'utf8');
  const parsed = parseInvitation(invitation), listeners = {};
  const native = {
    addListener: (name, fn) => { listeners[name] = fn; },
    connect(url) {
      socket = new WebSocket(url, { rejectUnauthorized: false });
      socket.on('open', () => { assert.equal(createHash('sha256').update(socket._socket.getPeerCertificate().raw).digest('hex'), parsed.pin); listeners.status({ value: 'open', id: 'fixture-pairing' }); });
      socket.on('message', value => listeners.message({ value: String(value), id: 'fixture-pairing' }));
      return 'fixture-pairing';
    },
    send: text => { if (socket?.readyState !== WebSocket.OPEN) return false; socket.send(text); return true; },
    disconnect: () => socket?.close(),
  };
  connection = new Connection(native); connection.phoneId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
  connection.subscribeProfile(() => { if (connection.layoutPending) setImmediate(() => connection.acknowledgeLayout(connection.layout.revision)); });
  await connection.connect(invitation);
  await until(() => connection.snapshot().phase === 'connected');
  const catalog = await connection.requestProfiles(); assert.equal(connection.cloudAdoptionSupported, true);
  const profile = structuredClone(xboxProfile); profile.id = 'cloud-receiver-test'; profile.name = 'Cloud receiver test';
  for (const control of profile.controls) control.layers = Object.fromEntries(['', 'SHIFT-', 'CTRL-', 'ALT-', 'CTRL-SHIFT-', 'ALT-SHIFT-', 'ALT-CTRL-', 'ALT-CTRL-SHIFT-'].map(key => [key, { label: 'Layer '.repeat(10).trim() }]));
  assert.ok(Buffer.byteLength(JSON.stringify(profile)) > 4096);
  const source = { service: 'https://pilot.example', accountId: 'a'.repeat(64), profileId: profile.id, revision: 7 };
  const adopted = await connection.adoptProfile(profile, source, catalog.activationRevision);
  assert.equal(adopted.activationRevision, 1); assert.equal(connection.canPlay, false);
  assert.equal(connection.layoutPending, false); assert.equal(connection.recovering, false);
  const disk = await new ProfileStore(directory).read();
  assert.equal(disk.active.profile.id, adopted.adoption.profileId);
  assert.equal(disk.profiles.find(entry => entry.profile.id === adopted.adoption.profileId).cloudSource.revision, 7);
  assert.deepEqual({ ...disk.active.profile, id: profile.id }, profile);
  const retry = await connection.adoptProfile(profile, source, adopted.activationRevision);
  assert.equal(retry.activationRevision, 1);
  assert.equal((await new ProfileStore(directory).read()).profiles.length, 3);
  const reportPath = join(dirname(directory), 'reports');
  const lastReport = async () => {
    try { return Buffer.from((await readFile(reportPath, 'utf8')).trim().split('\n').at(-1), 'hex'); }
    catch { return null; }
  };
  const neutral = async () => { const bytes = await lastReport(); return bytes?.length === 20 && bytes.subarray(2).every(value => value === 0); };
  await until(() => connection.accessSnapshot());
  connection.resumePlay(); await until(() => connection.canPlay && !connection.recovering);
  // This fixture never creates HID: combinations are checked at the real
  // receiver's report boundary without sending them into a running game.
  const chord = { ...neutralState(), buttons: 1 | (1 << 4), lt: 1, lx: 0.5 };
  connection.withTouch(() => connection.submit(chord));
  await until(async () => { const bytes = await lastReport(); return bytes && bytes.readUInt16LE(2) === 0x1100 && bytes[4] === 255 && bytes.readInt16LE(6) > 0; });
  connection.pausePlay(); await until(neutral);
  assert.equal(connection.canPlay, false);
  connection.resumePlay(); await until(() => connection.canPlay && !connection.recovering);
  connection.withTouch(() => connection.submit(chord));
  await until(async () => (await lastReport())?.[4] === 255);
  const nextProfile = { ...profile, name: 'Second exact revision' }, nextSource = { ...source, revision: 8 };
  const next = await connection.adoptProfile(nextProfile, nextSource, 1);
  assert.equal(next.activationRevision, 2);
  assert.notEqual(next.adoption.profileId, adopted.adoption.profileId);
  assert.equal(connection.canPlay, false); await until(neutral);
  connection.resumePlay(); await until(() => connection.canPlay && !connection.recovering);
  connection.withTouch(() => connection.submit(chord));
  await until(async () => (await lastReport())?.[4] === 255);
  connection.disconnect(); await until(neutral);
  await until(async () => (await readFile(invitationPath, 'utf8')) !== invitation);
  // Recreate the production phone connection core, as after an app restart.
  connection = new Connection(native); connection.phoneId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
  connection.subscribeProfile(() => { if (connection.layoutPending) setImmediate(() => connection.acknowledgeLayout(connection.layout.revision)); });
  await connection.connect(await readFile(invitationPath, 'utf8'));
  await until(() => connection.snapshot().phase === 'connected' && connection.layout.revision === 2 && !connection.layoutPending && !connection.recovering);
  assert.equal(connection.layout.profile.id, next.adoption.profileId);
  assert.equal(connection.canPlay, false); await until(neutral);
  assert.equal((await new ProfileStore(directory).read()).profiles.length, 4);
  assert.equal(connection.phoneProfileSaveSupported, true);
  const edited = { ...profile, id: 'phone-' + '1'.repeat(32), name: 'Phone edits' };
  const editedCatalog = await connection.savePhoneProfile(edited, 2);
  assert.equal(editedCatalog.activationRevision, 3);
  assert.deepEqual(connection.layout.profile, edited);
  await assert.rejects(connection.savePhoneProfile({ ...edited, name: 'Stale change' }, 2), /Profiles changed/);
  const updated = { ...edited, name: 'Phone edits v2' };
  const updatedCatalog = await connection.savePhoneProfile(updated, 3, 1);
  assert.equal(updatedCatalog.activationRevision, 4);
  assert.equal(updatedCatalog.profiles.find(entry => entry.id === edited.id).revision, 2);
  assert.deepEqual((await new ProfileStore(directory).read()).active.profile, updated);
  assert.equal((await connection.savePhoneProfile(updated, 4)).activationRevision, 4);
  assert.equal(connection.canPlay, false); await until(neutral);
  const snapshot = JSON.parse(await readFile('packages/profile-tools/test/fixtures/warrior-character.json', 'utf8'));
  snapshot.exportedAt = Math.floor(Date.now() / 1000);
  const wow = join(dirname(directory), 'wow', 'WTF/Account/123/Realm/Hero/SavedVariables');
  await mkdir(wow, { recursive: true });
  const sync = { bridgeVersion: 1, kind: 'consoleport-sync', exportedAt: snapshot.exportedAt, character: snapshot.character,
    modifiers: { GamePadEmulateShift: 'PADLTRIGGER', GamePadEmulateCtrl: 'PADRTRIGGER', GamePadEmulateAlt: 'NONE' },
    consolePortLayout: [{ key: 'PAD1', layers: ['', 'SHIFT-', 'CTRL-', 'ALT-', 'CTRL-SHIFT-', 'ALT-SHIFT-', 'ALT-CTRL-', 'ALT-CTRL-SHIFT-'].map(modifier => ({ modifier, command: 'JUMP', label: 'Jump' })) }] };
  // Use a ConsolePort theme so the receiver reads this character's snapshot.
  await assert.rejects(connection.savePhoneProfile({ ...updated, name: 'Old editor' }, 4, 1), /Profiles changed/);
  const synced = { ...updated, theme: 'consoleport' };
  await connection.savePhoneProfile(synced, 4, 2);
  let receipt = null;
  const saveVariables = async () => writeFile(join(wow, 'ThumbleBridge.lua'), 'ThumbleBridgeDB = {["syncText"]=' + JSON.stringify(JSON.stringify(sync)) + ',["phoneExportText"]=' + JSON.stringify(JSON.stringify(snapshot)) + (receipt ? ',["receiptText"]=' + JSON.stringify(JSON.stringify(receipt)) : '') + '}');
  await saveVariables();
  await until(() => connection.layout.revision >= 6 && !connection.layoutPending && !connection.recovering);
  const context = await connection.readBindings();
  assert.equal(context.snapshotId, snapshot.snapshotId);
  assert.ok(context.spells.some(spell => spell.id === 100));
  await assert.rejects(connection.readBindings(0, 'stale-snapshot'), /changed/);
  const current = await connection.requestProfiles();
  const currentEntry = current.profiles.find(entry => entry.id === synced.id);
  const change = bindingChange(context, connection.layout.profile, { controlId: 'a', spellId: 100 });
  const plan = { bridgeVersion: 1, kind: 'binding-plan', id: 'phone-proposal', snapshotId: context.snapshotId,
    characterGuid: context.character.guid, bindingSet: context.bindingSet,
    profile: { id: synced.id, name: synced.name, revision: currentEntry.revision }, changes: [change] };
  assert.deepEqual(await connection.copyBindingPlan(plan), { planId: plan.id });
  assert.deepEqual(JSON.parse(await readFile(join(directory, 'binding-proposal.json'), 'utf8')), plan);
  await assert.rejects(connection.copyBindingPlan({ ...plan, changes: [{ ...change, spellId: 9999999 }] }), /validated/);
  await assert.rejects(connection.copyBindingPlan({ ...plan, profile: { ...plan.profile, revision: 1 } }), /changed/);
  // A receipt is confirmed only against the bindings in a subsequent export.
  receipt = { bridgeVersion: 1, kind: 'binding-receipt', planId: plan.id, characterGuid: context.character.guid,
    bindingSet: context.bindingSet, results: [{ key: change.key, command: 'SPELL Charge' }] };
  await saveVariables();
  assert.equal((await connection.readBindings()).receipt, undefined);
  snapshot.bindings.find(binding => binding.key === change.key).base = 'SPELL Charge';
  snapshot.bindings.find(binding => binding.key === change.key).effective = 'SPELL Charge';
  snapshot.snapshotId += ':after-apply';
  await saveVariables();
  assert.deepEqual((await connection.readBindings()).receipt, { planId: plan.id, status: 'verified' });
  // Page across a large spellbook without exceeding the WebSocket message limit.
  snapshot.spells.push(...Array.from({ length: 70 }, (_, index) => ({ id: 10000 + index, name: 'Learned spell ' + index, passive: false })));
  await saveVariables();
  let page = await connection.readBindings(), learned = [...page.spells];
  assert.ok(page.nextOffset > 0);
  while (page.nextOffset !== null) {
    page = await connection.readBindings(page.nextOffset, page.snapshotId);
    learned.push(...page.spells);
  }
  assert.equal(learned.length, snapshot.spells.filter(spell => !spell.passive).length);
  console.log('PASS character snapshot transport, learned spell proposal, exact Mac handoff, stale context and invalid spell rejection');
  console.log('PASS phone edits through the TLS receiver: exact activation, conflict handling, revisioned updates and idempotent retry');
  console.log('PASS actual TLS receiver adoption: >4KiB validated profile, isolated persisted copy, phone layout/neutral ACK, paused input, idempotent retry');
  console.log('PASS receiver safety: movement + button/shoulder/trigger chord, pause release, profile switch release, disconnect release, persisted exact profile after fresh pairing/phone core restart, explicit resume required');
} finally {
  connection?.disconnect(); socket?.terminate(); fixture.kill('SIGTERM'); await once(fixture, 'exit').catch(() => {});
}
