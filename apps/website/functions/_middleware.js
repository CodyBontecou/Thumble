import { documents } from './_markdown.js';

// Prefer the explicitly requested representation; a wildcard alone keeps HTML.
export function prefersMarkdown(accept = '') {
  const ranges = accept.toLowerCase().split(',').map((part, index) => {
    const [type, ...params] = part.trim().split(';');
    const quality = params.find(value => value.trim().startsWith('q='));
    const q = quality ? Number(quality.trim().slice(2)) : 1;
    return { type, q: Number.isFinite(q) && q >= 0 && q <= 1 ? q : 0, index };
  });
  const md = ranges.find(value => value.type === 'text/markdown');
  const html = ranges.find(value => value.type === 'text/html');
  return Boolean(md && md.q > 0 && (!html || md.q > html.q || md.q === html.q && md.index < html.index));
}
function varyAccept(headers) {
  const vary = headers.get('vary') || '';
  if (!vary.split(',').some(value => value.trim().toLowerCase() === 'accept')) headers.set('vary', [vary, 'Accept'].filter(Boolean).join(', '));
}
export async function onRequest({ request, next }) {
  const url = new URL(request.url);
  const path = url.pathname.replace(/\.html$/, '').replace(/\/$/, '') || '/';
  const read = request.method === 'GET' || request.method === 'HEAD';
  const markdown = read && prefersMarkdown(request.headers.get('accept') || '');
  if (markdown && Object.hasOwn(documents, path)) {
    return new Response(request.method === 'HEAD' ? null : documents[path], { headers: {
      'Content-Type': 'text/markdown; charset=utf-8', 'Vary': 'Accept',
      // Cloudflare's shared cache does not key arbitrary Vary headers. Avoid mixing variants.
      'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff',
      'Link': `<https://thumble.io${path}>; rel="canonical"`,
    } });
  }
  const response = await next();
  if (read && response.status === 404 && markdown) {
    return new Response(request.method === 'HEAD' ? null : '# Page not found\n\nThis Thumble page does not exist or has moved. Continue with the [setup guide](https://thumble.io/docs), [developer documentation](https://thumble.io/developers), [sitemap](https://thumble.io/sitemap.xml) or [agent guidance](https://thumble.io/llms.txt).\n', { status: 404, headers: {'Content-Type': 'text/markdown; charset=utf-8', 'Vary': 'Accept', 'Cache-Control': 'no-store', 'X-Content-Type-Options':'nosniff'} });
  }
  const result = new Response(response.body, response);
  if (result.headers.get('content-type')?.includes('text/html')) {
    varyAccept(result.headers);
    result.headers.set('Cache-Control', 'no-store');
    result.headers.append('Link', '<https://thumble.io/openapi.json>; rel="service-desc"; type="application/vnd.oai.openapi+json", <https://thumble.io/developers>; rel="service-doc"');
  }
  return result;
}
