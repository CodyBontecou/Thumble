import { cp, mkdir, readFile, rename, access, rm } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { randomUUID } from 'node:crypto';
const client = process.argv[2];
if (!client) { console.error('Usage: node tools/install-wow-addon.mjs /path/to/WoW/_classic_era_ (or _forever_)'); process.exit(2); }
const parent = resolve(client, 'Interface/AddOns'), target = join(parent, 'ThumbleBridge');
const staging = join(parent, '.ThumbleBridge-install-' + randomUUID());
let backup;
try {
  await access(parent);
  try {
    const manifest = await readFile(join(target, 'ThumbleBridge.toc'), 'utf8');
    if (!/^## Title: Thumble(?: Bridge)?\s*$/m.test(manifest)) throw Error('Destination contains an unrecognized addon; refusing to overwrite it');
    backup = join(parent, '.thumble-backups', 'ThumbleBridge-' + Date.now());
  } catch (error) { if (error.code !== 'ENOENT') throw error; }
  await cp(new URL('../addons/ThumbleBridge', import.meta.url), staging, { recursive: true });
  if (backup) { await mkdir(resolve(backup, '..'), { recursive: true }); await rename(target, backup); }
  try { await rename(staging, target); }
  catch (error) { if (backup) await rename(backup, target); throw error; }
  console.log(JSON.stringify({ installed: target, backup, next: 'Reload the UI (restart the client if this is a newly discovered addon), then type /thumble. No bindings are applied automatically.' }));
} finally { await rm(staging, { force: true, recursive: true }); }
