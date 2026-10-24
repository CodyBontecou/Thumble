import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { execFileSync } from 'node:child_process';
import { validateProfile } from '@tapping/controller';
import { ProfileStore } from '../packages/profile-tools/src/store.js';
const directory = await mkdtemp(join(tmpdir(), 'thumble-consoleport-sync-'));
try {
  const binary = join(directory, 'tests');
  execFileSync('xcrun', ['swiftc', '-swift-version', '5', '-module-cache-path', resolve('build/swift-module-cache'), ...['ProfileCatalog', 'CloudProfile', 'ConsolePortSync'].map(n => resolve(`apps/receiver/Sources/${n}.swift`)), resolve('tools/consoleport-sync-tests/main.swift'), '-o', binary], { stdio: 'inherit' });
  execFileSync(binary, [directory], { stdio: 'inherit' });
  const store = await new ProfileStore(join(directory, 'profiles')).read();
  if (validateProfile(store.active.profile).length) throw Error('Swift output fails phone validation');
  if (!store.consolePortSync?.character?.name) throw Error('Missing sync provenance');
  console.log('PASS native ConsolePort profiles readable by Node and valid for phone');
} finally { await rm(directory, { recursive: true, force: true }); }
