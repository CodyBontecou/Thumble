import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { stageWebsite } from '../build.mjs';

test('deployment staging includes discovery, content and Functions while excluding maintenance data', async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'thumble-site-stage-'));
  try {
    const source = path.join(root, 'source');
    const output = path.join(root, 'output');
    const files = ['index.html', 'script.js', 'attribution.mjs', 'pricing.md', 'openapi.json', '_headers', '.well-known/mcp/server-card.json', 'guides/example.html', 'functions/api/subscribe.js', 'assets/icon.png', 'sitemap.xml', 'README.md', 'schema.sql', 'migrations/private.sql', 'reports/private.sql', 'build-markdown.mjs', 'cli-distribution.json', 'wrangler.toml'];
    for (const name of files) {
      const file = path.join(source, name);
      await fs.mkdir(path.dirname(file), { recursive: true });
      await fs.writeFile(file, name);
    }
    await stageWebsite(source, output);
    for (const name of files.slice(0, 11)) assert.equal(await fs.readFile(path.join(output, name), 'utf8'), name);
    for (const name of files.slice(11)) await assert.rejects(fs.access(path.join(output, name)), { code: 'ENOENT' });
  } finally { await fs.rm(root, { recursive: true, force: true }); }
});

test('deployment staging rejects symlinks into files outside the website', async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'thumble-site-link-'));
  try {
    const source = path.join(root, 'source');
    await fs.mkdir(source);
    await fs.writeFile(path.join(root, 'private.txt'), 'not public');
    await fs.symlink(path.join(root, 'private.txt'), path.join(source, 'leak.txt'));
    await assert.rejects(stageWebsite(source, path.join(root, 'output')), /must not contain symlinks/);
  } finally { await fs.rm(root, { recursive: true, force: true }); }
});
