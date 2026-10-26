// Explicit public release allowlist: no access to other objects in the bucket.
const releases = new Map([
  ['Thumble-Receiver-1.0.0.dmg', ['macos/receiver', 'application/x-apple-diskimage']],
  ['Thumble-Receiver-0.1.0-windows-x64-setup.exe', ['windows/receiver', 'application/vnd.microsoft.portable-executable']],
  ['Thumble-Receiver-0.1.0-linux-x64.tar.gz', ['linux/receiver', 'application/gzip']],
  ['Thumble-Receiver-0.1.0-desktop-setup.txt', ['desktop/receiver', 'text/plain; charset=utf-8']],
  ['Thumble-Receiver-0.1.0-desktop.json', ['desktop/receiver', 'application/json; charset=utf-8']],
]);
const aliases = new Map([
  ['/downloads/receiver-latest.dmg', 'Thumble-Receiver-1.0.0.dmg'],
  ['/downloads/receiver-latest-windows.exe', 'Thumble-Receiver-0.1.0-windows-x64-setup.exe'],
  ['/downloads/receiver-latest-linux.tar.gz', 'Thumble-Receiver-0.1.0-linux-x64.tar.gz'],
  ['/downloads/receiver-desktop-setup.txt', 'Thumble-Receiver-0.1.0-desktop-setup.txt'],
]);

export default {
  async fetch(request, env) {
    const path = new URL(request.url).pathname;
    if (!['GET', 'HEAD'].includes(request.method)) {
      return new Response(null, { status: 405, headers: { Allow: 'GET, HEAD' } });
    }
    if (aliases.has(path)) {
      return new Response(null, {
        status: 302,
        headers: { Location: `/downloads/${aliases.get(path)}`, 'Cache-Control': 'no-store' },
      });
    }
    if (!path.startsWith('/downloads/')) return new Response('Release not found', { status: 404 });
    const name = path.slice('/downloads/'.length);
    const checksum = name.endsWith('.sha256');
    const release = releases.get(checksum ? name.slice(0, -7) : name);
    if (!release) return new Response('Release not found', { status: 404 });
    try {
      const key = `${release[0]}/${name}`;
      const object = request.method === 'HEAD' ? await env.RELEASES.head(key) : await env.RELEASES.get(key);
      if (!object) return new Response('Release not found', { status: 404 });
      const headers = new Headers({
        'Content-Type': checksum ? 'text/plain; charset=utf-8' : release[1],
        'Content-Disposition': `attachment; filename="${name}"`,
        'Content-Length': String(object.size),
        'Cache-Control': 'public, max-age=31536000, immutable',
        'X-Content-Type-Options': 'nosniff',
        ETag: object.httpEtag,
      });
      return new Response(request.method === 'HEAD' ? null : object.body, { headers });
    } catch {
      console.error(JSON.stringify({ event: 'receiver_download_failed' }));
      return new Response('Download temporarily unavailable', { status: 503, headers: { 'Cache-Control': 'no-store' } });
    }
  },
};
