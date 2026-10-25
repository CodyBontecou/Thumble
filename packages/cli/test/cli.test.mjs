import test from 'node:test';
import assert from 'node:assert/strict';
import { run } from '../src/thumble.mjs';

test('public CLI reads need no token and account reads target only the canonical HTTPS origin', async () => {
  const requests = [], output = [];
  const fetchImpl = async (url, options) => { requests.push({ url, options }); return Response.json({ ok: true }); };
  const dependencies = { fetchImpl, token: 'private-token', out: value => output.push(value), err: () => assert.fail('Unexpected error') };
  assert.equal(await run(['sandbox'], dependencies), 0);
  assert.equal(requests[0].url, 'https://thumble.io/v1/sandbox');
  assert.equal(requests[0].options.headers.authorization, undefined);
  assert.equal(await run(['profile','sample-controller','2'], dependencies), 0);
  assert.equal(requests[1].url, 'https://thumble.io/v1/profiles/sample-controller/revisions/2');
  assert.equal(requests[1].options.headers.authorization, 'Bearer private-token');
  assert.equal(requests[1].options.redirect, 'error');
  assert.deepEqual(JSON.parse(output[0]), { ok: true });
});

test('CLI rejects unsafe input and missing credentials before a request', async () => {
  for (const args of [['profile','../other'], ['profile','sample','0'], ['delivery','id','2'], ['config','extra'], ['unknown'], ['devices']]) {
    let requested = false;
    const errors = [];
    assert.equal(await run(args, { token: '', fetchImpl: () => { requested = true; }, out: () => {}, err: value => errors.push(value) }), 1);
    assert.equal(requested, false); assert.equal(errors.length, 1);
  }
});

test('CLI handles rate limits without retrying or exposing tokens or server error content', async () => {
  const errors = []; let requests = 0;
  const status = await run(['profiles'], { token: 'secret-value', out: () => assert.fail('No successful output'), err: value => errors.push(value), fetchImpl: async () => {
    requests++; return Response.json({ error: { message: 'secret-value echoed by server' } }, { status: 429, headers: { 'retry-after': '60' } });
  } });
  assert.equal(status, 1); assert.equal(requests, 1);
  assert.equal(JSON.parse(errors[0]).error.retryAfter, '60');
  assert.ok(!errors[0].includes('secret-value'));
});

test('CLI executes through the symlink used by npm-installed binaries', async () => {
  const { mkdtemp, symlink, rm } = await import('node:fs/promises');
  const { tmpdir } = await import('node:os');
  const { join } = await import('node:path');
  const { fileURLToPath } = await import('node:url');
  const { execFileSync } = await import('node:child_process');
  const directory = await mkdtemp(join(tmpdir(), 'thumble-cli-test-'));
  try {
    const command = join(directory, 'thumble');
    await symlink(fileURLToPath(new URL('../src/thumble.mjs', import.meta.url)), command);
    const output = execFileSync(process.execPath, [command, '--help'], { encoding: 'utf8' });
    assert.match(output, /Thumble CLI 0.1.0/);
  } finally { await rm(directory, { recursive: true, force: true }); }
});
