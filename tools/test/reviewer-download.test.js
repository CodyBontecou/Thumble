import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, timingSafeEqual } from 'node:crypto';
import worker from '../../apps/downloads/src/worker.js';

// Cloudflare's documented constant-time Web Crypto extension.
crypto.subtle.timingSafeEqual = (a, b) => timingSafeEqual(Buffer.from(a), Buffer.from(b));
const authorization = `Basic ${Buffer.from('reviewer:test-only-password').toString('base64')}`;
const secret = createHash('sha256').update(authorization).digest('hex');
const url = 'https://thumble.io/downloads/app-review/receiver.zip';
function fixture() {
  const reads = [];
  const object = { body: new Blob(['review zip']).stream(), size: 10, httpEtag: 'test-etag' };
  return { reads, env: {
    REVIEW_DOWNLOAD_AUTH_SHA256: secret,
    RELEASES: {
      get: async key => { reads.push(key); return object; },
      head: async key => { reads.push(key); return object; },
    },
  } };
}
test('review download fails closed without credentials, wrong credentials, or configuration', async () => {
  for (const auth of [undefined, 'Basic invalid', `${authorization}x`]) {
    const { reads, env } = fixture();
    const response = await worker.fetch(new Request(url, { headers: auth ? { Authorization: auth } : {} }), env);
    assert.equal(response.status, 401);
    assert.match(response.headers.get('WWW-Authenticate'), /^Basic /);
    assert.match(response.headers.get('Cache-Control'), /no-store/);
    assert.deepEqual(reads, []);
  }
  const { env, reads } = fixture();
  delete env.REVIEW_DOWNLOAD_AUTH_SHA256;
  assert.equal((await worker.fetch(new Request(url), env)).status, 503);
  assert.deepEqual(reads, []);
});
test('authorized GET and HEAD access only the review object without public caching', async () => {
  for (const method of ['GET', 'HEAD']) {
    const { env, reads } = fixture();
    const response = await worker.fetch(new Request(url, { method, headers: { Authorization: authorization } }), env);
    assert.equal(response.status, 200);
    assert.equal(response.headers.get('Content-Type'), 'application/zip');
    assert.match(response.headers.get('Cache-Control'), /private, no-store/);
    assert.equal(await response.text(), method === 'HEAD' ? '' : 'review zip');
    assert.deepEqual(reads, ['macos/review/Thumble-Review-Receiver-1.0.1.zip']);
  }
});
test('private path cannot select arbitrary bucket objects or accept writes', async () => {
  const { env, reads } = fixture();
  for (const suffix of ['/other.zip', '/receiver.zip.sha256', '/receiver.zip/']) {
    assert.equal((await worker.fetch(new Request(`https://thumble.io/downloads/app-review${suffix}`), env)).status, 404);
  }
  assert.equal((await worker.fetch(new Request(url, { method: 'POST' }), env)).status, 405);
  assert.deepEqual(reads, []);
});
test('existing public release and latest redirect remain available', async () => {
  const { env, reads } = fixture();
  const response = await worker.fetch(new Request('https://thumble.io/downloads/Thumble-Receiver-1.0.0.dmg'), env);
  assert.equal(response.status, 200);
  assert.match(response.headers.get('Cache-Control'), /public/);
  assert.deepEqual(reads, ['macos/receiver/Thumble-Receiver-1.0.0.dmg']);
  assert.equal((await worker.fetch(new Request('https://thumble.io/downloads/receiver-latest.dmg'), env)).status, 302);
});

// Versioned downloads stay immutable when advancing the latest alias.
test('latest points at the controller-access release and previous public versions remain available', async () => {
  const { env, reads } = fixture();
  const latest = await worker.fetch(new Request('https://thumble.io/downloads/receiver-latest.dmg'), env);
  assert.equal(latest.headers.get('Location'), '/downloads/Thumble-Receiver-1.0.2.dmg');
  for (const version of ['1.0.0', '1.0.1', '1.0.2']) {
    for (const suffix of ['', '.sha256']) {
      const name = `Thumble-Receiver-${version}.dmg${suffix}`;
      assert.equal((await worker.fetch(new Request(`https://thumble.io/downloads/${name}`), env)).status, 200);
      assert.equal(reads.at(-1), `macos/receiver/${name}`);
    }
  }
  assert.equal((await worker.fetch(new Request('https://thumble.io/downloads/Thumble-Receiver-1.0.3.dmg'), env)).status, 404);
});
