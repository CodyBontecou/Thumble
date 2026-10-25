export const MUSE_CLIENT_ID = 'thumble-muse';
export const MUSE_REDIRECT_URI = 'https://agent.meta.ai/api/hatch/oauth/callback';
export const MUSE_SCOPES = Object.freeze(['offline_access', 'profiles:read', 'devices:read', 'deliveries:read']);

// Muse omits RFC 8707 resource indicators. Bind its fixed registration to our
// canonical MCP resource before Better Auth signs the authorization handoff.
// Explicit resource values still go through the provider's normal validation.
export function museAuthorization(request, resource) {
  const url = new URL(request.url);
  if (url.pathname !== '/api/auth/oauth2/authorize' || url.searchParams.getAll('client_id').length !== 1 || url.searchParams.get('client_id') !== MUSE_CLIENT_ID || url.searchParams.has('resource')) return request;
  url.searchParams.set('resource', resource);
  return new Request(url, request);
}
