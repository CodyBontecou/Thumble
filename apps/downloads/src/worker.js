// Explicit public release allowlist: no access to other objects in the bucket.
const filename = 'Thumble-Receiver-1.0.0.dmg';

export default {
  async fetch(request, env) {
    const path = new URL(request.url).pathname;
    if (!['GET', 'HEAD'].includes(request.method)) {
      return new Response(null, { status: 405, headers: { Allow: 'GET, HEAD' } });
    }
    if (path === '/downloads/receiver-latest.dmg') {
      return new Response(null, {
        status: 302,
        headers: { Location: `/downloads/${filename}`, 'Cache-Control': 'no-store' },
      });
    }
    const name = path.slice('/downloads/'.length);
    if (path !== `/downloads/${filename}` && path !== `/downloads/${filename}.sha256`) {
      return new Response('Release not found', { status: 404 });
    }
    try {
      const key = `macos/receiver/${name}`;
      const object = request.method === 'HEAD' ? await env.RELEASES.head(key) : await env.RELEASES.get(key);
      if (!object) return new Response('Release not found', { status: 404 });
      const headers = new Headers({
        'Content-Type': name.endsWith('.dmg') ? 'application/x-apple-diskimage' : 'text/plain; charset=utf-8',
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
