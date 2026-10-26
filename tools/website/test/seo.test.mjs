import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { normalizeTouch } from '../../../apps/website/attribution.mjs';
import { documents } from '../../../apps/website/functions/_markdown.js';
import { onRequest } from '../../../apps/website/functions/_middleware.js';

const root = fileURLToPath(new URL('../../../apps/website/', import.meta.url));
const builder = path.join(root, 'build-markdown.mjs');
const hub = await fs.readFile(path.join(root, 'guides.html'), 'utf8');
const articleRoutes = [...hub.matchAll(/<a class="guide-card" href="([^"]+)"/g)].map(match => match[1]);
assert.equal(new Set(articleRoutes).size, articleRoutes.length, 'guide hub has duplicate article cards');
const guideRoutes = ['/guides', ...articleRoutes];

test('Markdown discovery includes nested public content and skips assets and 404s', async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'thumble-markdown-'));
  try {
    for (const name of ['functions', 'guides/deep', 'blog', 'assets']) await fs.mkdir(path.join(dir, name), {recursive: true});
    for (const name of ['index', '404', 'guides/index', 'guides/deep/example', 'blog/update', 'assets/private']) {
      await fs.writeFile(path.join(dir, name+'.html'), '<main><nav>Breadcrumb noise</nav><aside>TOC noise</aside><nav aria-labelledby="related-guides-title"><a href="/guides/next">Related article</a></nav><h1 id="example">Example</h1><a href="/docs">Setup</a><a href="#example">This section</a><table><tr><th>Option</th><th>Requirements</th></tr><tr><td>Phone</td><td>Mac</td></tr></table></main>');
    }
    execFileSync(process.execPath, [builder, dir]);
    const generated = await fs.readFile(path.join(dir, 'functions/_markdown.js'), 'utf8');
    const result = JSON.parse(generated.replace('export const documents = ', '').trim().replace(/;$/, ''));
    assert.deepEqual(Object.keys(result).sort(), ['/', '/blog/update', '/guides', '/guides/deep/example']);
    assert.match(result['/guides/deep/example'], /\[Setup\]\(https:\/\/thumble.io\/docs\)/);
    assert.ok(result['/guides/deep/example'].includes('[Related article](https://thumble.io/guides/next)'));
    assert.ok(!result['/guides/deep/example'].includes('Breadcrumb noise'));
    assert.ok(!result['/guides/deep/example'].includes('TOC noise'));
    assert.ok(result['/guides/deep/example'].includes('[This section](https://thumble.io/guides/deep/example#example)'));
    assert.ok(result['/guides/deep/example'].includes('| Option | Requirements |\n| --- | --- |\n| Phone | Mac |'));
    await fs.writeFile(path.join(dir, 'guides.html'), '<main>Duplicate hub</main>');
    assert.throws(() => execFileSync(process.execPath, [builder, dir], {stdio: 'pipe'}), /Duplicate public Markdown route/);
  } finally { await fs.rm(dir, {recursive: true, force: true}); }
});

test('every acquisition page is discoverable and its local links and fragments resolve', async () => {
  const sitemap = await fs.readFile(path.join(root, 'sitemap.xml'), 'utf8');
  const files = [];
  async function collect(dir) {
    for (const entry of await fs.readdir(dir, {withFileTypes: true})) {
      if (entry.isDirectory() && ['blog','guides','compare'].includes(entry.name)) await collect(path.join(dir, entry.name));
      if (entry.isFile() && entry.name.endsWith('.html')) files.push(path.join(dir, entry.name));
    }
  }
  await collect(root);
  const pages = new Map();
  for (const file of files) {
    const route = '/'+path.relative(root,file).replaceAll(path.sep,'/').replace(/index\.html$/, '').replace(/\.html$/, '');
    pages.set(route, await fs.readFile(file,'utf8'));
  }
  for (const route of guideRoutes) {
    assert.match(sitemap, new RegExp(`<loc>https://thumble.io${route}</loc>`));
    assert.ok(documents[route], `missing Markdown: ${route}`);
    assert.equal(normalizeTouch({landing: route}).landing, route, `missing attribution path: ${route}`);
    const html = pages.get(route);
    assert.equal((html.match(/<h1\b/g)||[]).length, 1);
    assert.ok(html.includes(`rel="canonical" href="https://thumble.io${route}"`));
    assert.match(html, /coming soon/);
    for (const match of html.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)) JSON.parse(match[1]);
  }
  for (const [route,html] of pages) {
    for (const [,href] of html.matchAll(/<a\b[^>]*href="([^"]*)"/g)) {
      const url = new URL(href, 'https://thumble.io'+route);
      if (url.origin !== 'https://thumble.io') continue;
      if (pages.has(url.pathname) && url.hash) {
        assert.ok(pages.get(url.pathname).includes(`id="${decodeURIComponent(url.hash.slice(1))}"`), `${route} links missing fragment ${href}`);
      } else if (guideRoutes.includes(route) && !url.pathname.startsWith('/downloads/')) {
        assert.ok(pages.has(url.pathname) || !/^\/(guides|compare)(\/|$)/.test(url.pathname), `${route} links missing guide ${href}`);
      }
    }
  }
});

test('guide Markdown negotiation preserves HTML fallback, HEAD and real missing-page status', async () => {
  for (const route of guideRoutes) {
    const next = () => new Response('<html>HTML fallback</html>', {headers:{'Content-Type':'text/html'}});
    const request = new Request('https://thumble.io'+route, {headers:{Accept:'text/markdown'}});
    const result = await onRequest({request,next});
    assert.equal(result.status,200);
    assert.match(result.headers.get('Content-Type'), /text\/markdown/);
    assert.equal(result.headers.get('Vary'),'Accept');
    assert.equal(result.headers.get('Cache-Control'),'no-store');
    assert.equal(await result.text(),documents[route]);
    const head = await onRequest({request:new Request(request,{method:'HEAD'}),next});
    assert.equal(await head.text(),'');
    const html = await onRequest({request:new Request(request,{headers:{Accept:'text/html, text/markdown;q=0.5'}}),next});
    assert.equal(await html.text(),'<html>HTML fallback</html>');
  }
  const missing = await onRequest({request:new Request('https://thumble.io/guides/missing',{headers:{Accept:'text/markdown'}}),next:()=>new Response('Missing',{status:404})});
  assert.equal(missing.status,404);
  assert.match(await missing.text(),/Page not found/);
});
