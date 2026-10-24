import { execFileSync } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
const directory = await mkdtemp(join(tmpdir(), 'thumble-local-access-'));
try {
  for (const flags of [[], ['-D', 'THUMBLE_LOCAL_TESTING']]) {
    const binary = join(directory, flags.length ? 'local' : 'production');
    execFileSync('xcrun', ['swiftc', '-swift-version', '5', ...flags, '-module-cache-path', resolve('build/monetization-swift-cache'), 'apps/receiver/Sources/AccessSession.swift', 'tools/local-test-access-tests/main.swift', '-o', binary], { stdio:'inherit' });
    execFileSync(binary, { stdio:'inherit' });
  }
} finally { await rm(directory, { recursive:true, force:true }); }
