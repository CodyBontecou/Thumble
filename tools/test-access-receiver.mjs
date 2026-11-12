// An isolated receiver linked to a reporting stub, never a real HID device.
import { mkdtemp, mkdir, writeFile, readFile, rm, readdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { generateKeyPairSync } from 'node:crypto';
import { once } from 'node:events';
import assert from 'node:assert/strict';
import WebSocket from 'ws';
import { xboxProfile, neutralState } from '../packages/controller/src/index.js';
import { parseInvitation } from '../packages/controller/src/pairing.js';
import { createGrant } from '../apps/entitlements/src/grants.js';
const folder = await mkdtemp(join(tmpdir(), 'tapping-access-'));
let child, socket, heartbeat;
try {
  const contents = join(folder, 'AccessTest.app/Contents');
  await mkdir(join(contents, 'MacOS'), { recursive: true }); await mkdir(join(contents, 'Resources'));
  const binary = join(contents, 'MacOS/receiver');
  const keys = generateKeyPairSync('ed25519');
  const raw = keys.publicKey.export({ type: 'spki', format: 'der' }).subarray(-32).toString('base64');
  await writeFile(join(contents, 'Resources/Monetization.json'), JSON.stringify({ entitlementPublicKey: raw }));
  await writeFile(join(contents, 'Info.plist'), '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>receiver</string><key>CFBundleIdentifier</key><string>test.tapping.access</string></dict></plist>');
  function run(command, args) { const result = spawnSync(command, args, { encoding: 'utf8' }); if (result.status !== 0) throw Error(result.stderr || result.stdout); }
  run('xcrun', ['clang', '-c', 'tools/access-receiver-tests/GamepadStub.c', '-o', join(folder, 'stub.o')]);
  const sources = (await readdir('apps/receiver/Sources')).filter(name => name.endsWith('.swift') && name !== 'main.swift').map(name => `apps/receiver/Sources/${name}`);
  run('xcrun', ['swiftc', '-swift-version', '5', '-module-cache-path', resolve('build/monetization-swift-cache'), '-import-objc-header', 'apps/receiver/Sources/Gamepad.h', ...sources, 'tools/access-receiver-tests/main.swift', join(folder, 'stub.o'), '-o', binary]);
  const profiles = join(folder, 'profiles'); await mkdir(profiles);
  const receiverId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  const phoneId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
  // A record written by a demo-era receiver: its receiver ID must keep working.
  await writeFile(join(profiles, 'demo.json'), JSON.stringify({ version: 1, receiverId, used: 500 }));
  const custom = { ...xboxProfile, id: 'custom', name: 'Custom' };
  await writeFile(join(profiles, 'store.json'), JSON.stringify({ version: 1, profiles: [{ revision: 1, profile: custom }], active: { revision: 5, profileRevision: 1, profile: custom } }));
  const invitationPath = join(folder, 'invitation'), reports = join(folder, 'reports');
  child = spawn(binary, [], { env: { ...process.env, TAPPING_PROFILE_DIR: profiles, TAPPING_TEST_INVITATION: invitationPath, TAPPING_TEST_REPORTS: reports }, stdio: ['ignore', 'ignore', 'pipe'] });
  let errors = ''; child.stderr.on('data', value => errors += value);
  const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
  async function until(get, timeout = 6000) {
    const deadline = Date.now() + timeout;
    while (Date.now() < deadline) { const value = await get(); if (value) return value; await sleep(10); }
    throw Error(`Timed out: ${errors}`);
  }
  const link = await until(async () => { try { return await readFile(invitationPath, 'utf8'); } catch { return null; } });
  if (process.argv.includes('--preview')) {
    const previewPath = resolve('build/access-preview-invitation');
    await writeFile(previewPath, link, { mode: 0o600 });
    heartbeat = setInterval(() => { void readFile(invitationPath, 'utf8').then(value => writeFile(previewPath, value, { mode: 0o600 })).catch(() => {}); }, 1000);
    console.log(`Isolated receiver preview ready. Private invitation file: ${previewPath}`);
    await new Promise(resolve => process.once('SIGINT', resolve));
    process.exitCode = 0;
  } else {
  const invite = parseInvitation(link);
  socket = new WebSocket(invite.url, { rejectUnauthorized: false });
  const messages = []; socket.on('message', data => messages.push(JSON.parse(data)));
  await once(socket, 'open');
  const send = value => socket.send(JSON.stringify(value));
  // Older phones still send demoUsed; it must be accepted and ignored.
  send({ type: 'hello', v: 3, phoneId, demoUsed: 0, token: invite.token });
  const ready = await until(() => messages.find(message => message.type === 'ready'));
  let access = await until(() => messages.find(message => message.type === 'access' && message.nonce));
  assert.equal(access.pro, false); assert.equal(access.remaining, 0); assert.equal(access.enabled, false);
  assert.equal(access.receiverId, receiverId, 'Existing receiver record lost its receiver ID');
  for (const field of ['debitedUsed', 'grantExpires']) assert.equal(typeof access[field], 'number');
  assert.equal(typeof access.running, 'boolean'); assert.equal(access.error, '');
  const layout = await until(() => messages.find(message => message.type === 'layout'));
  assert.equal(layout.profile.id, 'custom'); assert.equal(layout.revision, 5);
  let sequence = 0, lease = ready.lease, frame = neutralState(), revision = layout.revision;
  socket.on('message', data => {
    const message = JSON.parse(data);
    if (message.lease) lease = message.lease;
    if (message.type === 'access') access = message;
    if (message.type === 'paused') frame = neutralState();
    if (message.type === 'layout') {
      revision = message.revision; frame = neutralState();
      send({ type: 'layout-ready', revision });
    }
  });
  send({ type: 'layout-ready', revision });
  await until(() => messages.find(message => message.type === 'paused'));
  heartbeat = setInterval(() => send({ type: 'input', seq: ++sequence, lease, revision, state: frame }), 30);
  send({ type: 'profiles-list', id: 'unplanned-list' });
  const catalog = await until(() => messages.find(message => message.id === 'unplanned-list'));
  assert.equal(catalog.catalog.profiles[0].id, 'custom');
  send({ type: 'profile-select', id: 'unplanned-select', profileId: 'custom', profileRevision: 1, expectedActivationRevision: 5, lease });
  const selected = await until(() => messages.find(message => message.id === 'unplanned-select'));
  assert.equal(selected.catalog.activationRevision, 6);
  await until(() => messages.filter(message => message.type === 'paused').length >= 2);
  const held = { ...neutralState(), lx: 1, buttons: 1 };
  const neutralReport = '0014000000000000000000000000000000000000';
  const reported = async () => { try { return (await readFile(reports, 'utf8')).trim().split('\n'); } catch { return []; } };
  send({ type: 'access-resume' });
  await sleep(300); // Neutral heartbeats clear the pause, so held input below is applied.
  frame = held;
  const heldFrom = sequence + 1;
  await until(() => messages.some(message => message.type === 'ack' && message.seq >= heldFrom + 5));
  assert.equal(access.enabled, false); assert.equal(access.running, false); assert.equal(access.remaining, 0);
  assert((await reported()).every(report => report === neutralReport), 'A phone without a plan produced output');
  send({ type: 'chat', id: 'unplanned-chat', revision, lease, text: 'hello', channel: 'say' });
  const chat = await until(() => messages.find(message => message.id === 'unplanned-chat'));
  assert.equal(chat.error, 'Start a free trial or restore your plan in Thumble on your phone.');
  console.log('PASS receiver: without a plan, layouts and profiles work but Resume, input and chat stay blocked with no free time');
  const privateKey = keys.privateKey.export({ type: 'pkcs8', format: 'pem' });
  const expiring = createGrant({ receiverId, phoneId, nonce: access.nonce, pro: true, until: Date.now() / 1000 + 2 }, privateKey);
  send({ type: 'access-grant', grant: expiring });
  await until(() => access.pro);
  assert.equal(access.enabled, false, 'A new plan must wait for Resume');
  send({ type: 'access-resume' });
  await until(() => access.running && access.enabled);
  frame = held;
  await until(async () => (await reported()).some(report => report !== neutralReport));
  await until(() => !access.pro && !access.enabled && !access.running);
  await sleep(100);
  assert.equal((await reported()).at(-1), neutralReport, 'Plan expiry left non-neutral input');
  assert.equal(access.remaining, 0);
  console.log('PASS receiver: a valid plan grant starts output; expiry during held input neutralizes it');
  const grant = createGrant({ receiverId, phoneId, nonce: access.nonce, pro: true }, privateKey);
  send({ type: 'access-grant', grant });
  await until(() => access.pro);
  assert.equal(socket.readyState, WebSocket.OPEN);
  assert.equal(revision, 6, 'Restoring a plan changed the selected layout');
  send({ type: 'access-resume' });
  await until(() => access.running);
  frame = held;
  await sleep(2200);
  assert.equal(access.remaining, 0); assert.equal(access.enabled, true); assert.equal(access.running, true);
  send({ type: 'access-grant', grant: createGrant({ receiverId, phoneId, nonce: access.nonce, pro: false }, privateKey) });
  await until(() => !access.pro && !access.enabled);
  await sleep(100);
  assert.equal((await reported()).at(-1), neutralReport, 'Revocation left non-neutral input');
  assert.equal(socket.readyState, WebSocket.OPEN);
  assert.equal(revision, 6, 'Revocation changed the selected layout');
  send({ type: 'profiles-list', id: 'expired-list' });
  assert((await until(() => messages.find(message => message.id === 'expired-list'))).catalog);
  const saved = JSON.parse(await readFile(join(profiles, 'demo.json'), 'utf8'));
  assert.equal(saved.receiverId, receiverId); assert.equal(saved.used, 500);
  console.log('PASS receiver: plan grants keep layouts and profile access; revocation stops output; the receiver record is unchanged');
  }
} finally {
  clearInterval(heartbeat); socket?.terminate(); child?.kill();
  if (child && child.exitCode === null) await once(child, 'exit');
  if (process.argv.includes('--preview')) await rm(resolve('build/access-preview-invitation'), { force: true });
  await rm(folder, { recursive: true, force: true });
}
