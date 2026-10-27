import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../../apps/downloads/src/worker.js';

const files = [
  ['Thumble-Receiver-1.0.1.dmg', 'macos/receiver', 'application/x-apple-diskimage'],
  ['Thumble-Receiver-0.1.1-windows-x64-setup.exe', 'windows/receiver', 'application/vnd.microsoft.portable-executable'],
  ['Thumble-Receiver-0.1.1-linux-x64.tar.gz', 'linux/receiver', 'application/gzip'],
  ['Thumble-Receiver-0.1.1-desktop-setup.txt', 'desktop/receiver', 'text/plain'],
  ['Thumble-Receiver-0.1.1-desktop.json', 'desktop/receiver', 'application/json'],
];

test('versioned releases and checksums stream only from their allowlisted keys', async () => {
  for (const [name, prefix, mime] of files) for (const suffix of ['', '.sha256']) for (const method of ['GET', 'HEAD']) {
    const calls = [];
    const read = async key => { calls.push(key); return { size: 4, body: 'data', httpEtag: '"release"' }; };
    const response = await worker.fetch(new Request(`https://thumble.io/downloads/${name}${suffix}`, { method }),
      { RELEASES: { get: method === 'GET' ? read : assert.fail, head: method === 'HEAD' ? read : assert.fail } });
    assert.equal(response.status, 200);
    assert.deepEqual(calls, [`${prefix}/${name}${suffix}`]);
    assert.equal(await response.text(), method === 'HEAD' ? '' : 'data');
    assert.equal(response.headers.get('Content-Length'), '4');
    assert.match(response.headers.get('Content-Type'), new RegExp(suffix ? 'text/plain' : mime));
    assert.match(response.headers.get('Cache-Control'), /immutable/);
    assert.equal(response.headers.get('Content-Disposition'), `attachment; filename="${name}${suffix}"`);
    assert.equal(response.headers.get('X-Content-Type-Options'), 'nosniff');
  }
});

test('latest aliases redirect without touching storage or caching a release choice', async () => {
  for (const [alias, name] of [['receiver-latest.dmg', files[0][0]], ['receiver-latest-windows.exe', files[1][0]],
    ['receiver-latest-linux.tar.gz', files[2][0]], ['receiver-desktop-setup.txt', files[3][0]]]) {
    const response = await worker.fetch(new Request(`https://thumble.io/downloads/${alias}`), {});
    assert.equal(response.status, 302);
    assert.equal(response.headers.get('Location'), `/downloads/${name}`);
    assert.equal(response.headers.get('Cache-Control'), 'no-store');
  }
});

test('unpublished names, encoded paths and other bucket objects remain private', async () => {
  for (const path of ['/other/Thumble-Receiver-1.0.0.dmg', '/downloads/macos/latest.json', '/downloads/private.json',
    '/downloads/%54humble-Receiver-1.0.0.dmg', '/downloads/Thumble-Receiver-1.0.0.dmg/extra']) {
    assert.equal((await worker.fetch(new Request(`https://thumble.io${path}`), {})).status, 404);
  }
  const response = await worker.fetch(new Request('https://thumble.io/downloads/receiver-latest.dmg', { method: 'POST' }), {});
  assert.equal(response.status, 405);
  assert.equal(response.headers.get('Allow'), 'GET, HEAD');
});

test('missing artifacts and storage failures fail without returning another release', async () => {
  const request = new Request(`https://thumble.io/downloads/${files[1][0]}`);
  assert.equal((await worker.fetch(request, { RELEASES: { get: async () => null } })).status, 404);
  const failed = await worker.fetch(request, { RELEASES: { get: async () => { throw Error('unavailable'); } } });
  assert.equal(failed.status, 503);
  assert.equal(failed.headers.get('Cache-Control'), 'no-store');
});
