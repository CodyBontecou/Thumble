import { execFileSync } from 'node:child_process';
import { mkdir, mkdtemp, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const output = resolve('build/pairing-code-tests');
await mkdir(output, { recursive: true });
const directory = await mkdtemp(join(tmpdir(), 'thumble-pairing-native-'));
try {
  execFileSync('xcrun', ['swiftc', '-swift-version', '5', '-module-cache-path', resolve('build/receiver/swift-cache'),
    ...['CloudPairing', 'PairingCode', 'ProfileBridge', 'ProfileCatalog', 'CloudProfile', 'ConsolePortSync', 'PhoneBindings'].map(name => resolve(`apps/receiver/Sources/${name}.swift`)),
    resolve('tools/pairing-code-tests/main.swift'), '-o', join(output, 'tests')], { stdio: 'inherit' });
  execFileSync(join(output, 'tests'), [directory], { stdio: 'inherit' });
  execFileSync('xcrun', ['clang', '-c', 'tools/access-receiver-tests/GamepadStub.c', '-o', join(directory, 'stub.o')], { stdio: 'inherit' });
  const sources = (await readdir('apps/receiver/Sources')).filter(name => name.endsWith('.swift') && name !== 'main.swift');
  execFileSync('xcrun', ['swiftc', '-swift-version', '5', '-module-cache-path', resolve('build/receiver/swift-cache'),
    '-import-objc-header', 'apps/receiver/Sources/Gamepad.h', ...sources.map(name => resolve(`apps/receiver/Sources/${name}`)),
    resolve('tools/cloud-pairing-tests/main.swift'), join(directory, 'stub.o'), '-o', join(output, 'lifecycle-tests')], { stdio: 'inherit' });
  execFileSync(join(output, 'lifecycle-tests'), [directory], { stdio: 'inherit' });
} finally { await rm(directory, { recursive: true, force: true }); }
