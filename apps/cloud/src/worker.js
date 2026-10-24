import { CloudError } from '@tapping/cloud-contracts';
import { handleApi } from './api.js';
import { handleMcp, handleProtectedResourceMetadata } from './mcp.js';
import { handleIdentity } from './identity.js';
import { handleAuthPage } from './auth-pages.js';
import { handleAsset } from './assets.js';

// Account APIs and MCP share the same authenticated service and persistent store.
// The receiver's LAN transport is intentionally outside this Worker.
export default {
  async fetch(request, env) {
    try {
      const { pathname } = new URL(request.url);
      if (pathname === '/.well-known/openai-apps-challenge') {
        if (!['GET', 'HEAD'].includes(request.method)) return new Response('Use GET or HEAD.', { status: 405, headers: { allow: 'GET, HEAD' } });
        if (!env.ASSETS) return new Response('Verification not configured.', { status: 404 });
        const asset = await env.ASSETS.fetch(request);
        return new Response(asset.body, { status: asset.status, headers: { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' } });
      }
      if (pathname.startsWith('/assets/')) return await handleAsset(request, env);
      if (pathname === '/mcp') return await handleMcp(request, env);
      if (pathname === '/.well-known/oauth-protected-resource' || pathname === '/.well-known/oauth-protected-resource/mcp') {
        return await handleProtectedResourceMetadata(request, env);
      }
      if (pathname.startsWith('/api/auth/') || pathname === '/api/auth' || pathname === '/.well-known/oauth-authorization-server/api/auth' || pathname === '/.well-known/openid-configuration/api/auth') {
        return await handleIdentity(request, env);
      }
      if (pathname === '/sign-in' || pathname === '/consent' || pathname === '/account') return await handleAuthPage(request, env);
      if (pathname.startsWith('/v1/')) return await handleApi(request, env);
      return Response.json({ error: { code: 'not_found', message: 'Route not found.' } }, { status: 404, headers: { 'Cache-Control': 'no-store' } });
    } catch (error) {
      const known = error instanceof CloudError;
      return Response.json({ error: { code: known ? error.code : 'internal_error', message: known ? error.message : 'The service could not complete the request.' } }, {
        status: known ? error.status : 500,
        headers: { 'Cache-Control': 'no-store' },
      });
    }
  },
};
