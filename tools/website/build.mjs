import fs from 'node:fs/promises';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const repository = fileURLToPath(new URL('../../', import.meta.url));
const source = path.join(repository, 'apps/website');
export const output = path.join(repository, 'dist/website');
const publicDirectories = new Set(['assets', 'blog', 'guides', 'compare', 'zh-hans', '.well-known', 'functions']);
const publicFiles = new Set(['_headers', '_redirects', 'pricing.md', 'openapi.json', 'sitemap.xml']);

// Positive selection keeps migrations, reports, schema and maintenance tools private.
export async function stageWebsite(input, destination) {
  if (path.resolve(input) === path.resolve(destination)) throw new Error('Build output must differ from source');
  await fs.mkdir(destination, { recursive: true });
  async function copy(from, to) {
    const stat = await fs.lstat(from);
    if (stat.isSymbolicLink()) throw new Error(`Website source must not contain symlinks: ${from}`);
    if (stat.isDirectory()) {
      await fs.mkdir(to, { recursive: true });
      for (const entry of await fs.readdir(from)) {
        if (entry.startsWith('.') && entry !== '.well-known') continue;
        await copy(path.join(from, entry), path.join(to, entry));
      }
    } else {
      await fs.copyFile(from, to);
    }
  }
  for (const entry of await fs.readdir(input, { withFileTypes: true })) {
    const isPublicFile = !entry.isDirectory() && (publicFiles.has(entry.name) || /\.(html|css|js|txt)$/.test(entry.name) || entry.name === 'attribution.mjs');
    if (publicDirectories.has(entry.name) || isPublicFile) await copy(path.join(input, entry.name), path.join(destination, entry.name));
  }
}

function verify(bytes, expected, label) {
  if (createHash('sha256').update(bytes).digest('hex') !== expected) throw new Error(`Unexpected SHA-256 for ${label}; update the distribution manifest only for an intentional release`);
}

export async function buildWebsite({ cliArchive } = {}) {
  await fs.rm(output, { recursive: true, force: true });
  await stageWebsite(source, output);
  // The deployment is self-contained, including Functions and the existing bindings.
  await fs.copyFile(path.join(source, 'wrangler.toml'), path.join(output, 'wrangler.toml'));
  execFileSync(process.execPath, [path.join(source, 'build-markdown.mjs'), output], { stdio: 'inherit' });
  const manifest = JSON.parse(await fs.readFile(path.join(source, 'cli-distribution.json'), 'utf8'));
  const script = await fs.readFile(path.join(repository, manifest.script.source));
  verify(script, manifest.script.sha256, 'CLI script');
  const cache = path.join(repository, 'build/website-downloads', manifest.archive.sha256 + '.tgz');
  let archive;
  if (cliArchive) archive = await fs.readFile(cliArchive);
  else {
    try { archive = await fs.readFile(cache); }
    catch (error) {
      if (error.code !== 'ENOENT') throw error;
      const response = await fetch(manifest.archive.url, { signal: AbortSignal.timeout(30000) });
      if (!response.ok) throw new Error(`CLI archive fetch failed: HTTP ${response.status}`);
      archive = Buffer.from(await response.arrayBuffer());
    }
  }
  verify(archive, manifest.archive.sha256, 'published CLI archive');
  await fs.mkdir(path.dirname(cache), { recursive: true });
  await fs.writeFile(cache, archive);
  await fs.mkdir(path.join(output, 'cli'), { recursive: true });
  await fs.writeFile(path.join(output, 'cli/thumble.mjs'), script);
  await fs.writeFile(path.join(output, 'cli', manifest.archive.filename), archive);
  console.log(`Website built from apps/website to ${path.relative(repository, output)}; published CLI hashes verified.`);
  return output;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const args = process.argv.slice(2);
  if (args.length && !(args.length === 2 && args[0] === '--cli-archive')) throw new Error('Usage: node tools/website/build.mjs [--cli-archive /path/to/published.tgz]');
  await buildWebsite({ cliArchive: args[1] });
}
