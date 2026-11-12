import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';

const repository = fileURLToPath(new URL('../../', import.meta.url));
const artifact = path.join(repository, 'dist/website');
const base = 'https://thumble.io';
const hub = await fs.readFile(path.join(artifact, 'guides.html'), 'utf8');
const routes = ['/guides', ...[...hub.matchAll(/<a class="guide-card" href="([^"]+)"/g)].map(match => match[1])];
assert.equal(new Set(routes).size, routes.length, 'Duplicate guide route');
const { documents } = await import(pathToFileURL(path.join(artifact, 'functions/_markdown.js')));
const requests = [
  ...[...routes, '/', '/docs'].map(route => ({ route, accept: 'text/html' })),
  ...routes.map(route => ({ route, accept: 'text/markdown' })),
  ...['/sitemap.xml', '/guides.css', '/cli/thumble.mjs', '/cli/thumble-cli-0.1.0.tgz'].map(route => ({ route })),
  { route: '/guides/missing-seo-check', accept: 'text/markdown', status: 404 },
  { route: '/guides/wow-controller-mac', accept: 'text/markdown', method: 'HEAD' },
  { route: '/downloads/receiver-latest.dmg', method: 'HEAD' },
];
function withoutEdgeDecorations(html, route) {
  let source = html.replace(/<script\b[^>]*src="https:\/\/static\.cloudflareinsights\.com\/[^\"]*"[^>]*>[\s\S]*?<\/script>\n?/g, '');
  // Production adds these exact localization links outside the Pages artifact.
  // Keep the rest of the homepage byte-for-byte strict, including release links.
  if (route === '/') {
    source = source.replace('<link rel="alternate" hreflang="en" href="https://thumble.io/"><link rel="alternate" hreflang="zh-Hans" href="https://thumble.io/zh-hans/"><link rel="alternate" hreflang="x-default" href="https://thumble.io/">', '')
      .replace('<nav aria-label="Language"><a href="/zh-hans/" lang="zh-Hans" hreflang="zh-Hans">简体中文</a></nav>', '');
  }
  return source;
}
async function check(request) {
  const { route, accept = '*/*', method = 'GET', status = 200 } = request;
  const response = await fetch(base + route, { method, headers: { Accept: accept, 'Cache-Control': 'no-cache' }, signal: AbortSignal.timeout(15000) });
  assert.equal(response.status, status, `${method} ${route}`);
  if (method === 'HEAD') { assert.equal((await response.arrayBuffer()).byteLength, 0); return; }
  const bytes = Buffer.from(await response.arrayBuffer());
  if (status === 404) { assert.match(bytes.toString(), /Page not found/); return; }
  if (accept === 'text/markdown') {
    assert.match(response.headers.get('content-type'), /text\/markdown/);
    assert.match(response.headers.get('vary'), /accept/i);
    assert.equal(response.headers.get('cache-control'), 'no-store');
    assert.ok(bytes.toString() === documents[route], `Markdown mismatch: ${route}`);
  } else if (accept === 'text/html') {
    assert.match(response.headers.get('content-type'), /text\/html/);
    const file = route === '/' ? 'index.html' : route.slice(1) + '.html';
    assert.ok(withoutEdgeDecorations(bytes.toString(), route) === await fs.readFile(path.join(artifact, file), 'utf8'), `HTML mismatch: ${route}`);
  } else {
    const expected = await fs.readFile(path.join(artifact, route.slice(1)));
    // The production edge may add the Chinese landing page to a sitemap that does not list it yet.
    const edgeless = route === '/sitemap.xml'
      ? Buffer.from(bytes.toString().replace('<url><loc>https://thumble.io/zh-hans/</loc><lastmod>2026-10-26</lastmod></url>', ''))
      : bytes;
    assert.ok(bytes.equals(expected) || edgeless.equals(expected), `Asset mismatch: ${route}`);
  }
}
// Retry propagation and transient fetch failures, then fail the workflow visibly.
for (let offset = 0; offset < requests.length; offset += 6) {
  await Promise.all(requests.slice(offset, offset + 6).map(async request => {
    for (let attempt = 0; ; attempt++) {
      try { await check(request); return; }
      catch (error) { if (attempt === 3) throw error; await delay(2000); }
    }
  }));
}
console.log(`PASS: ${requests.length} production checks against the built artifact (${routes.length - 1} articles).`);
