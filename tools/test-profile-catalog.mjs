// Native/Node store compatibility regression. macOS + Xcode command-line tools.
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { xboxProfile, validateProfile } from '@tapping/controller';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { execFileSync } from 'node:child_process';
import { callProfileTool } from '../packages/profile-tools/src/tools.js';
import { ProfileStore } from '../packages/profile-tools/src/store.js';
const directory = await mkdtemp(join(tmpdir(), 'thumble-catalog-'));
try {
  const store = new ProfileStore(directory);
  await store.save(JSON.parse(await readFile(new URL('../examples/profiles/warrior.json', import.meta.url))), 0);
  await callProfileTool(store, 'agent_connection_check', { code: '123456abcdef' });
  const cases = [structuredClone(xboxProfile)];
  for (const mutate of [p => { p.macros = ['cast']; }, p => { p.controls[0].frame.x = true; }, p => { p.controls.push(p.controls[0]); }, p => { p.mappings[0].outputs = ['keyboard']; }, p => { p.controls[0].layers = { 'SHIFT-': { label: 'Shift', icon: 'ability_test' } }; }, p => { p.mappings[0].deadzone = 0.1; }, p => { p.schemaVersion = true; }]) {
    const profile = structuredClone(xboxProfile); mutate(profile); cases.push(profile);
  }
  await writeFile(join(directory, 'adoption-cases.json'), JSON.stringify(cases.map(profile => ({ profile, valid: validateProfile(profile).length === 0 }))));
  const binary = join(directory, 'test');
  execFileSync('xcrun', ['swiftc', '-module-cache-path', resolve('build/monetization-swift-cache'), resolve('apps/receiver/Sources/ProfileCatalog.swift'), resolve('apps/receiver/Sources/CloudProfile.swift'), resolve('tools/profile-catalog-tests/main.swift'), '-o', binary], { stdio: 'inherit' });
  execFileSync(binary, [directory], { stdio: 'inherit' });
  const data = await store.read();
  if (!data.active.profile.id.startsWith('cloud-') || data.active.revision !== 3) throw Error('Node could not read native activation');
  console.log('PASS Node tools read Swift-written store');
} finally { await rm(directory, { recursive: true, force: true }); }
