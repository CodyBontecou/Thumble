// Explicit runtime smoke: starts isolated local workerd/D1, never a phone or receiver.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFile, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';
import { xboxProfile } from '@tapping/controller';
import { createTestAuthority } from './test/helpers.js';
import { thumbleAssets } from '../../assets/thumble.js';

const directory = await mkdtemp(join(tmpdir(), 'thumble-cloud-runtime-'));
const cloud = fileURLToPath(new URL('.', import.meta.url));
const root = resolve(cloud, '../..');
let runtime;
try {
  execFileSync(process.execPath, [join(root, 'node_modules/wrangler/bin/wrangler.js'), 'deploy', '--dry-run', '--outdir', directory], {
    cwd: cloud, env: { ...process.env, WRANGLER_LOG_PATH: join(directory, 'wrangler.log'), WRANGLER_SEND_METRICS: 'false' }, stdio: 'pipe',
  });
  const authority = await createTestAuthority();
  runtime = new Miniflare(convertV4MiniflareOptions({ modules: true, script: await readFile(join(directory, 'worker.js'), 'utf8'), compatibilityDate: '2026-10-23', compatibilityFlags: ['nodejs_compat'], bindings: authority.env, d1Databases: ['DB'], assets: { directory: join(root, 'assets/public'), binding: 'ASSETS', run_worker_first: true, routerConfig: { has_user_worker: true }, assetConfig: { html_handling: 'none', not_found_handling: 'none' } } }));
  const db = await runtime.getD1Database('DB');
  const sql = await readFile(new URL('migrations/0001_cloud.sql', import.meta.url), 'utf8');
  await db.batch(sql.split(';').map(s => s.trim()).filter(Boolean).map(s => db.prepare(s)));
  const accountToken = await authority.token();
  for (const asset of thumbleAssets) {
    const response = await runtime.dispatchFetch('https://cloud.example.test' + asset.path);
    assert.equal(response.status, 200, response.status === 200 ? undefined : await response.text());
    assert.equal(response.headers.get('content-type'), 'image/png');
    assert.equal(response.headers.get('access-control-allow-origin'), '*');
    const bytes = Buffer.from(await response.arrayBuffer());
    assert.deepEqual(bytes, await readFile(join(root, 'assets/public' + asset.path)));
    const head = await runtime.dispatchFetch('https://cloud.example.test' + asset.path, { method: 'HEAD' });
    assert.equal(head.status, 200);
    assert.equal(await head.text(), '');
    const read = await runtime.dispatchFetch('https://cloud.example.test/mcp', { method: 'POST', headers: { authorization: `Bearer ${accountToken}`, 'content-type': 'application/json', accept: 'application/json, text/event-stream' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'resources/read', params: { uri: asset.uri } }) });
    assert.equal(read.status, 200);
    const value = await read.json();
    assert.deepEqual(Buffer.from(value.result.contents[0].blob, 'base64'), bytes);
  }
  assert.equal((await runtime.dispatchFetch('https://cloud.example.test/assets/thumble/missing.png')).status, 404);
  async function api(path, value, token = accountToken) {
    const response = await runtime.dispatchFetch(`https://cloud.example.test/v1${path}`, { method: value ? 'POST' : 'GET', headers: { authorization: `Bearer ${token}`, ...(value ? { 'content-type': 'application/json' } : {}) }, ...(value ? { body: JSON.stringify(value) } : {}) });
    assert.ok(response.ok, `REST ${path}: ${response.status}`); return response.json();
  }
  let nextId = 0;
  async function tool(name, args) {
    const response = await runtime.dispatchFetch('https://cloud.example.test/mcp', { method: 'POST', headers: { authorization: `Bearer ${accountToken}`, 'content-type': 'application/json', accept: 'application/json, text/event-stream', 'mcp-protocol-version': '2025-11-25' }, body: JSON.stringify({ jsonrpc: '2.0', id: ++nextId, method: 'tools/call', params: { name, arguments: args } }) });
    assert.equal(response.status, 200); const result = (await response.json()).result; assert.ok(!result.isError, JSON.stringify(result)); return result.structuredContent;
  }
  const registered = await api('/devices', { name: 'Runtime test phone', platform: 'ios', viewport: { width: 844, height: 390 } });
  const saved = await tool('save_profile', { profile: xboxProfile, expectedRevision: 0 }); assert.equal(saved.revision, 1);
  const { delivery } = await tool('deliver_profile', { deviceId: registered.device.id, profileId: xboxProfile.id, profileRevision: 1, requestId: 'runtime-journey' });
  const pending = await api(`/devices/${registered.device.id}/deliveries`, undefined, registered.deviceToken); assert.equal(pending.deliveries[0].profile.id, xboxProfile.id);
  for (const state of ['received', 'rendered']) await api(`/devices/${registered.device.id}/deliveries/${delivery.id}/ack`, { profileId: xboxProfile.id, profileRevision: 1, state }, registered.deviceToken);
  const status = await tool('delivery_status', { deliveryId: delivery.id }); assert.equal(status.delivery.state, 'rendered');
  console.log('PASS: bundled Worker + public PNG assets + authenticated MCP image resources + real D1 + signed OAuth JWT + hosted MCP save/deliver/status + device receipts. Phone renderer simulated; no real phone used.');
} finally {
  try { await runtime?.dispose(); } catch {} if (process.env.KEEP_CLOUD_RUNTIME_BUILD) console.log(directory); else await rm(directory, { recursive: true, force: true });
}
