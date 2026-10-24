import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import worker from '../src/worker.js';
import { thumbleAssets } from '../../../assets/thumble.js';
import { handleMcp } from '../src/mcp.js';

const env = {
  OAUTH_ISSUER: 'https://identity.example', OAUTH_AUDIENCE: 'https://cloud.example/mcp', OAUTH_JWKS_JSON: '{"keys":[]}',
  ASSETS: { async fetch(request) {
    const url = request instanceof Request ? new URL(request.url) : new URL(request);
    const bytes = await readFile(new URL('../../../assets/public' + url.pathname, import.meta.url));
    return new Response(request.method === 'HEAD' ? null : bytes, { headers: { 'content-type': 'image/png', etag: 'test-etag' } });
  } },
};
const deps = { authenticateAccount: async () => ({ kind: 'account', accountId: 'test', scopes: [] }) };
async function rpc(method, params, dependencies = deps) {
  const response = await handleMcp(new Request('https://alias.example/mcp', {
    method: 'POST', headers: { 'content-type': 'application/json', accept: 'application/json, text/event-stream' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
  }), env, dependencies);
  return { response, body: await response.json() };
}

test('public brand assets serve exact PNG bytes without account authentication', async () => {
  for (const asset of thumbleAssets) {
    const response = await worker.fetch(new Request('https://cloud.example' + asset.path), env);
    assert.equal(response.status, 200);
    assert.equal(response.headers.get('content-type'), 'image/png');
    assert.equal(response.headers.get('access-control-allow-origin'), '*');
    assert.equal(response.headers.get('cache-control'), 'public, max-age=3600');
    const bytes = Buffer.from(await response.arrayBuffer());
    assert.deepEqual(bytes, await readFile(new URL('../../../assets/public' + asset.path, import.meta.url)));
    assert.deepEqual(bytes, await readFile(new URL('../../mobile/assets/' + asset.file, import.meta.url)));
    const head = await worker.fetch(new Request('https://cloud.example' + asset.path, { method: 'HEAD' }), env);
    assert.equal(head.status, 200);
    assert.equal(await head.text(), '');
  }
});

test('public route rejects unknown files and writes without reading asset storage', async () => {
  const noReads = { ASSETS: { fetch() { assert.fail('must not read'); } } };
  for (const path of ['/assets/thumble/missing.png', '/assets/private.json', '/assets/thumble/%2e%2e%2fsecret']) {
    assert.equal((await worker.fetch(new Request('https://cloud.example' + path), noReads)).status, 404);
  }
  const response = await worker.fetch(new Request('https://cloud.example/assets/thumble/icon.png', { method: 'POST' }), noReads);
  assert.equal(response.status, 405);
  assert.equal(response.headers.get('allow'), 'GET, HEAD');
  assert.equal((await worker.fetch(new Request('https://cloud.example/assets/thumble/icon.png'), {})).status, 503);
});

test('hosted MCP advertises canonical icon and reads allowlisted binary resources', async () => {
  const init = (await rpc('initialize', { protocolVersion: '2025-11-25', capabilities: {}, clientInfo: { name: 'test', version: '1' } })).body.result;
  assert.deepEqual(init.capabilities.resources, {});
  assert.equal(init.serverInfo.icons[0].src, 'https://cloud.example/assets/thumble/icon.png');
  const resources = (await rpc('resources/list')).body.result.resources;
  assert.equal(resources.length, thumbleAssets.length);
  for (const resource of resources) {
    const value = (await rpc('resources/read', { uri: resource.uri })).body.result.contents[0];
    assert.equal(value.mimeType, 'image/png');
    const asset = thumbleAssets.find(asset => asset.uri === resource.uri);
    assert.deepEqual(Buffer.from(value.blob, 'base64'), await readFile(new URL('../../../assets/public' + asset.path, import.meta.url)));
  }
  assert.deepEqual((await rpc('resources/templates/list')).body.result.resourceTemplates, []);
  for (const uri of ['https://evil.example/icon.png', 'thumble://assets/../secret', 'file:///etc/passwd']) {
    assert.equal((await rpc('resources/read', { uri })).body.error.code, -32002);
  }
});

test('MCP resource discovery and reads still require authentication', async () => {
  const unauthorized = { authenticateAccount: async () => { throw new Error('No token'); } };
  for (const method of ['resources/list', 'resources/read']) {
    assert.equal((await rpc(method, { uri: thumbleAssets[0].uri }, unauthorized)).response.status, 401);
  }
});
