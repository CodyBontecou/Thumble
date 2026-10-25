import { CloudError } from '@tapping/cloud-contracts';

export const CLINE_CLIENT_ID = 'thumble-cline';
export const CLINE_REDIRECT_URI = 'http://127.0.0.1:1456/mcp/oauth/callback';
export const CLINE_SCOPES = Object.freeze(['offline_access', 'profiles:read', 'devices:read', 'deliveries:read']);

// Cline copies every discovery scope. Reduce only this operator-registered
// client's request before signing the login handoff and displaying consent.
export function clineAuthorization(request) {
  const url = new URL(request.url);
  if (!url.pathname.endsWith('/oauth2/authorize') || url.searchParams.get('client_id') !== CLINE_CLIENT_ID) return request;
  const requested = (url.searchParams.get('scope') || '').split(/\s+/).filter(Boolean);
  const scopes = requested.filter(scope => CLINE_SCOPES.includes(scope));
  if (!scopes.some(scope => scope !== 'offline_access')) throw new CloudError('invalid_scope', 'Request a Cline read scope.', 400);
  url.searchParams.set('scope', [...new Set(['offline_access', ...scopes])].join(' '));
  return new Request(url, request);
}
