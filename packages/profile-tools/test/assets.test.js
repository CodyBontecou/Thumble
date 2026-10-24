import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { thumbleAssets } from '../../../assets/thumble.js';

test('local MCP advertises icon and serves only the packaged Thumble images', async t => {
  const child = spawn(process.execPath, ['packages/profile-tools/src/server.js'], { stdio: ['pipe', 'pipe', 'pipe'] });
  t.after(() => child.kill());
  let output = '', errors = '';
  child.stdout.on('data', chunk => output += chunk);
  child.stderr.on('data', chunk => errors += chunk);
  const requests = [
    { method: 'initialize', params: { protocolVersion: '2025-11-25' } },
    { method: 'resources/list' },
    ...thumbleAssets.map(asset => ({ method: 'resources/read', params: { uri: asset.uri } })),
    { method: 'resources/templates/list' },
    { method: 'resources/read', params: { uri: 'file:///etc/passwd' } },
  ];
  child.stdin.end(requests.map((request, id) => JSON.stringify({ jsonrpc: '2.0', id, ...request })).join('\n') + '\n');
  assert.equal(await new Promise(resolve => child.on('close', resolve)), 0, errors);
  const replies = output.trim().split('\n').map(line => JSON.parse(line));
  assert.equal(replies.length, requests.length);
  assert.deepEqual(replies[0].result.capabilities.resources, {});
  assert.match(replies[0].result.serverInfo.icons[0].src, /^data:image\/png;base64,/);
  assert.deepEqual(replies[1].result.resources.map(resource => resource.uri), thumbleAssets.map(asset => asset.uri));
  for (const [index, asset] of thumbleAssets.entries()) {
    const contents = replies[index + 2].result.contents[0];
    assert.equal(contents.mimeType, 'image/png');
    assert.deepEqual(Buffer.from(contents.blob, 'base64'), await readFile(new URL('../../../assets/public' + asset.path, import.meta.url)));
  }
  assert.deepEqual(replies.at(-2).result.resourceTemplates, []);
  assert.equal(replies.at(-1).error.code, -32002);
});
