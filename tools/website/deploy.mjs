import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildWebsite } from './build.mjs';

const args = process.argv.slice(2);
if (args.length > 1 || (args[0] && args[0] !== '--preview')) throw new Error('Usage: node tools/website/deploy.mjs [--preview]');
const repository = fileURLToPath(new URL('../../', import.meta.url));
const output = await buildWebsite();
const preview = args[0] === '--preview';
let extra;
if (preview) {
  const source = path.join(repository, 'apps/website');
  const persist = path.join(repository, 'build/website-local');
  const databaseId = fs.readFileSync(path.join(source, 'wrangler.toml'), 'utf8').match(/database_id\s*=\s*"([^"]+)"/)?.[1];
  if (!databaseId) throw new Error('Website DB binding is missing');
  execFileSync('wrangler', ['d1', 'execute', 'DB', '--local', '--file', path.join(source, 'schema.sql'), '--persist-to', persist], { cwd: source, stdio: 'inherit' });
  extra = ['--d1', `DB=${databaseId}`, '--r2', 'RELEASES', '--persist-to', persist];
} else extra = ['--project-name', 'pocketpad-site', '--branch', 'main'];
execFileSync('wrangler', ['pages', preview ? 'dev' : 'deploy', '.', ...extra], { cwd: output, stdio: 'inherit' });
