import { Buffer } from 'node:buffer';
import { McpError, ErrorCode } from '@modelcontextprotocol/sdk/types.js';
import { findThumbleResource, thumbleAssets } from '../../../assets/thumble.js';

export async function handleAsset(request, env) {
  const { pathname } = new URL(request.url);
  if (!thumbleAssets.some(asset => asset.path === pathname)) {
    return new Response('Asset not found.', { status: 404 });
  }
  if (!['GET', 'HEAD'].includes(request.method)) {
    return new Response('Use GET or HEAD.', { status: 405, headers: { allow: 'GET, HEAD' } });
  }
  if (!env.ASSETS) return new Response('Assets are not configured.', { status: 503 });
  const response = await env.ASSETS.fetch(request);
  const headers = new Headers(response.headers);
  headers.set('access-control-allow-origin', '*');
  headers.set('x-content-type-options', 'nosniff');
  if (response.ok || response.status === 304) headers.set('cache-control', 'public, max-age=3600');
  return new Response(response.body, { status: response.status, headers });
}

export async function readThumbleResource(uri, env) {
  const asset = findThumbleResource(uri);
  if (!asset) throw new McpError(-32002, 'Thumble asset not found.');
  if (!env.ASSETS) throw new McpError(ErrorCode.InternalError, 'Assets are not configured.');
  // Construct the URL from the allowlist; never fetch a client-supplied URL.
  const response = await env.ASSETS.fetch(new URL(asset.path, 'https://assets.local'));
  if (!response.ok) throw new McpError(ErrorCode.InternalError, 'Thumble asset could not be loaded.');
  return { contents: [{ uri, mimeType: asset.mimeType, blob: Buffer.from(await response.arrayBuffer()).toString('base64') }] };
}
