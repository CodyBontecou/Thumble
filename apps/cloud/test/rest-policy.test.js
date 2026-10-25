import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/worker.js';
import { withRestPolicy } from '../src/rest-policy.js';
import { assertProfile } from '@tapping/controller';

test('REST policy enforces the binding and advertises only known quota information', async () => {
  const keys = [];
  let permitted = true, calls = 0;
  const env = { REST_RATE_LIMITER: { async limit({ key }) { keys.push(key); return { success: permitted }; } } };
  const request = new Request('https://thumble.io/v1/profiles', { headers: { authorization: 'Bearer private-token', 'cf-connecting-ip': '192.0.2.1' } });
  const next = () => { calls++; return Response.json({ error: { code: 'unauthorized' } }, { status: 401 }); };
  let response = await withRestPolicy(request, env, next);
  assert.equal(response.status, 401);
  assert.equal(response.headers.get('ratelimit-policy'), '"thumble-rest";q=600;w=60');
  assert.equal(response.headers.get('x-ratelimit-limit'), '600');
  assert.equal(response.headers.get('ratelimit'), null);
  assert.equal(response.headers.get('retry-after'), null);
  assert.match(keys[0], /^credential:[a-f0-9]{64}$/);
  assert.ok(!keys[0].includes('private-token'));
  permitted = false;
  response = await withRestPolicy(request, env, next);
  assert.equal(response.status, 429); assert.equal(calls, 1);
  assert.equal(response.headers.get('retry-after'), '60');
  assert.equal(response.headers.get('ratelimit'), '"thumble-rest";r=0;t=60');
  assert.equal((await response.json()).error.code, 'rate_limit_exceeded');
  await withRestPolicy(new Request('https://thumble.io/v1/config', { headers: { 'cf-connecting-ip': '192.0.2.2' } }), env, next);
  assert.equal(keys[2], 'public:192.0.2.2');
});

test('public sandbox needs no credentials or database and cannot mutate or return live records', async () => {
  const env = { REST_RATE_LIMITER: { limit: async () => ({ success: true }) }, get DB() { throw Error('Sandbox must not access storage'); } };
  const response = await worker.fetch(new Request('https://thumble.io/v1/sandbox'), env);
  assert.equal(response.status, 200);
  const value = await response.json();
  assert.equal(value.sandbox, true);
  assert.equal(value.devices[0].id, 'sample-phone');
  assert.equal(value.profile.profile.id, 'sample-controller');
  assertProfile(value.profile.profile);
  assert.ok(!JSON.stringify(value).match(/access_token|refresh_token|deviceToken|data:image|td_/));
  const write = await worker.fetch(new Request('https://thumble.io/v1/sandbox', { method: 'POST' }), env);
  assert.equal(write.status, 405); assert.equal(write.headers.get('allow'), 'GET');
});
