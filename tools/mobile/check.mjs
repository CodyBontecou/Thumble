import { readdirSync } from 'node:fs';
import path from 'node:path';
import { fileHash, root, run } from './common.mjs';

const releaseLock = process.env.THUMBLE_RELEASE_LOCK_SHA256;
if (releaseLock && fileHash(path.join(root, 'package-lock.json')) !== releaseLock) {
  throw new Error('The build workspace dependency lock differs from the checked release source.');
}

run('npm', ['run', 'lint', '--workspace', '@tapping/mobile']);
run('npm', ['run', 'typecheck', '--workspace', '@tapping/mobile']);
const tests = ['connection', 'calibration', 'onboarding', 'monetization', 'cloud-mobile', 'mobile-release']
  .map(name => `tools/test/${name}.test.js`);
const directory = 'packages/controller/test';
for (const name of readdirSync(path.join(root, directory)).sort()) {
  if (name.endsWith('.test.js')) tests.push(`${directory}/${name}`);
}
console.log(run('node', ['--test', ...tests]));
console.log('Mobile lint, typecheck, and regression tests passed.');
