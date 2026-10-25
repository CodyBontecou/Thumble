import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/worker.js';

test('root OAuth discovery redirects to existing path-based issuer metadata', async () => {
  for (const [path, target] of [
    ['/.well-known/oauth-authorization-server', '/.well-known/oauth-authorization-server/api/auth'],
    ['/.well-known/openid-configuration', '/api/auth/.well-known/openid-configuration'],
  ]) {
    for (const method of ['GET', 'HEAD']) {
      const response = await worker.fetch(new Request(`https://thumble.io${path}`, { method }), {});
      assert.equal(response.status, 307);
      assert.equal(response.headers.get('location'), `https://thumble.io${target}`);
    }
    const response = await worker.fetch(new Request(`https://thumble.io${path}`, { method: 'POST' }), {});
    assert.equal(response.status, 405);
    assert.equal(response.headers.get('allow'), 'GET, HEAD');
  }
});
