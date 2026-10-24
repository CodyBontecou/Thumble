import { access, cp, mkdir, mkdtemp, readFile, rm } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';

const source = new URL('../addons/ThumbleBridge/', import.meta.url);
const manifest = await readFile(new URL('ThumbleBridge.toc', source), 'utf8');
const version = /^## Version: ([0-9.]+)$/m.exec(manifest)?.[1];
if (!version || !/^## Title: Thumble$/m.test(manifest)) throw Error('Expected a versioned Thumble addon manifest');
const files = manifest.split(/\r?\n/).filter(line => line && !line.startsWith('##'));
if (files.some(file => !/^[A-Za-z]+\.lua$/.test(file))) throw Error('Unexpected addon source path');
const output = resolve(process.argv[2] || `build/addons/Thumble-${version}.zip`);
try { await access(output); throw Error('Release ZIP already exists; choose a new output path'); }
catch (error) { if (error.code !== 'ENOENT') throw error; }
const staging = await mkdtemp(join(tmpdir(), 'thumble-addon-release-'));
try {
  const target = join(staging, 'ThumbleBridge');
  await mkdir(target);
  for (const file of ['ThumbleBridge.toc', ...files, 'README.md', 'CHANGELOG.md']) await cp(new URL(file, source), join(target, file));
  await mkdir(dirname(output), { recursive: true });
  // zip updates existing archives, so reject reuse rather than retain stale files.
  const zip = spawnSync('zip', ['-X', '-r', '-MM', output, 'ThumbleBridge'], { cwd: staging, encoding: 'utf8' });
  if (zip.status !== 0) throw Error(zip.stderr || zip.stdout);
  const contents = await readFile(output);
  const checksum = createHash('sha256').update(contents).digest('hex');
  console.log(JSON.stringify({ file: output, version, bytes: contents.length, sha256: checksum }));
} finally { await rm(staging, { recursive: true, force: true }); }
