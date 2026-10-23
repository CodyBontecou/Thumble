// Native/Node store compatibility regression. macOS + Xcode command-line tools.
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { execFileSync } from 'node:child_process';
import { ProfileStore } from '../packages/profile-tools/src/store.js';
const directory = await mkdtemp(join(tmpdir(), 'thumble-catalog-'));
try {
  const store = new ProfileStore(directory);
  await store.save(JSON.parse(await readFile(new URL('../examples/profiles/warrior.json', import.meta.url))), 0);
  const binary = join(directory, 'test');
  execFileSync('xcrun', ['swiftc', '-module-cache-path', resolve('build/monetization-swift-cache'), resolve('apps/receiver/Sources/ProfileCatalog.swift'), resolve('tools/profile-catalog-tests/main.swift'), '-o', binary], { stdio: 'inherit' });
  execFileSync(binary, [directory], { stdio: 'inherit' });
  const data = await store.read();
  if (data.active.profile.id !== 'warrior' || data.active.revision !== 1) throw Error('Node could not read native activation');
  console.log('PASS Node tools read Swift-written store');
} finally { await rm(directory, { recursive: true, force: true }); }
