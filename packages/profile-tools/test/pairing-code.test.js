import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm, chmod, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import { showPairingCode } from '../src/pairing-code.js';
import { callProfileTool } from '../src/tools.js';

const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII=';
async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'thumble-pairing-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const path = join(directory, 'pairing-code.json');
  const now = Date.now();
  const payload = { version: 1, updatedAt: now, expiresAt: now + 100_000, png };
  const write = value => writeFile(path, JSON.stringify(value), { mode: 0o600 });
  await write(payload);
  return { directory, path, now, payload, write };
}

test('pairing tool returns native MCP image content over stdio without exposing invitation text', async t => {
  const { directory } = await fixture(t);
  const child = spawn(process.execPath, ['packages/profile-tools/src/server.js'], {
    env: { ...process.env, TAPPING_PROFILE_DIR: directory }, stdio: ['pipe', 'pipe', 'pipe'],
  });
  t.after(() => child.kill());
  let output = '', errors = '';
  child.stdout.on('data', chunk => output += chunk);
  child.stderr.on('data', chunk => errors += chunk);
  child.stdin.end([
    { jsonrpc: '2.0', id: 1, method: 'initialize' },
    { jsonrpc: '2.0', id: 2, method: 'tools/list' },
    { jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'show_pairing_code', arguments: {} } },
  ].map(JSON.stringify).join('\n') + '\n');
  assert.equal(await new Promise(resolve => child.on('close', resolve)), 0, errors);
  const replies = output.trim().split('\n').map(JSON.parse);
  assert(replies[1].result.tools.some(tool => tool.name === 'show_pairing_code'));
  assert.deepEqual(replies[2].result.content[1], { type: 'image', mimeType: 'image/png', data: png });
  assert.match(replies[2].result.content[0].text, /single use/);
  assert(!output.includes('thumble://pair'));
});

test('pairing rejects absent, stale, expired, invalid and publicly readable images', async t => {
  const f = await fixture(t);
  for (const change of [{ updatedAt: f.now - 5000 }, { updatedAt: f.now + 1 }, { expiresAt: f.now }, { expiresAt: f.now + 180_000 }, { png: 'not-a-png' }, { version: 2 }]) {
    await f.write({ ...f.payload, ...change });
    await assert.rejects(showPairingCode(f, f.now), /stale|invalid/);
  }
  await f.write(f.payload);
  await chmod(f.path, 0o644);
  await assert.rejects(showPairingCode(f, f.now), /No current pairing code/);
  await rm(f.path);
  await assert.rejects(showPairingCode(f, f.now), /No current pairing code/);
  const target = join(f.directory, 'other.json');
  await writeFile(target, JSON.stringify(f.payload), { mode: 0o600 });
  await symlink(target, f.path);
  await assert.rejects(showPairingCode(f, f.now), /No current pairing code/);
});

test('pairing refuses arguments that could trigger disconnect or window actions', async () => {
  await assert.rejects(callProfileTool({}, 'show_pairing_code', { refresh: true }), /Invalid tool arguments/);
});
