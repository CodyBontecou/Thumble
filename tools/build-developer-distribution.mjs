// Prepare the official CLI's website distribution without tracking build archives.
import { mkdir, copyFile } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const repository = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const output = process.argv[2];
if (!output) throw Error('Usage: node tools/build-developer-distribution.mjs /absolute/site-staging/cli');
const target = resolve(output);
await mkdir(target, { recursive: true });
await copyFile(resolve(repository, 'packages/cli/src/thumble.mjs'), resolve(target, 'thumble.mjs'));
execFileSync('npm', ['pack', '--workspace', 'thumble-cli', '--ignore-scripts', '--pack-destination', target], { cwd: repository, stdio: 'inherit' });
