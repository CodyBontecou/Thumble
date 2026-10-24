import { CloudError } from '@tapping/cloud-contracts';

export const GLAMA_REDIRECT_URI = 'https://glama.ai/api/app/mcp/oauth/callback';
export const GLAMA_CLIENT_PREFIX = 'thumble-glama-';
export const GLAMA_MONITOR_SCOPES = Object.freeze(['offline_access', 'profiles:read', 'devices:read', 'deliveries:read']);
export const isGlamaClient = clientId => typeof clientId === 'string' && clientId.startsWith(GLAMA_CLIENT_PREFIX);

export async function readGlamaRegistration(request) {
  const reader = request.body?.getReader();
  if (!reader) throw new CloudError('invalid_client_metadata', 'A registration body is required.', 400);
  let size = 0;
  const chunks = [];
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > 8192) { await reader.cancel(); throw new CloudError('invalid_client_metadata', 'Registration is too large.', 413); }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  return glamaRegistration(JSON.parse(new TextDecoder().decode(bytes)));
}

// Registration proves no publisher identity. The HTTPS callback keeps codes on
// Glama; PKCE, consent, resource limits and the sample-account binding protect data.
export function glamaRegistration(metadata) {
  const redirects = metadata?.redirect_uris;
  if (!Array.isArray(redirects) || !redirects.includes(GLAMA_REDIRECT_URI) || redirects.length > 2 || redirects.some(value => ![GLAMA_REDIRECT_URI, 'http://localhost:6749/callback'].includes(value))) {
    throw new CloudError('invalid_redirect_uri', 'Only the exact Glama HTTPS callback may register.', 400);
  }
  if (metadata.application_type && metadata.application_type !== 'web') throw new CloudError('invalid_client_metadata', 'Glama must use a web client.', 400);
  if (metadata.grant_types?.some(grant => !['authorization_code', 'refresh_token'].includes(grant))) throw new CloudError('invalid_client_metadata', 'Only consented authorization-code and refresh grants are allowed.', 400);
  if (metadata.token_endpoint_auth_method && !['none', 'client_secret_post', 'client_secret_basic'].includes(metadata.token_endpoint_auth_method)) throw new CloudError('invalid_client_metadata', 'Unsupported client authentication.', 400);
  // RFC 7591 response reports the actual server-approved capability set.
  return { ...metadata, redirect_uris: [GLAMA_REDIRECT_URI], client_name: 'Glama health checks', scope: GLAMA_MONITOR_SCOPES.join(' '), grant_types: ['authorization_code', 'refresh_token'], response_types: ['code'] };
}

export function glamaAuthorization(request) {
  const url = new URL(request.url);
  if (!url.pathname.endsWith('/oauth2/authorize') || !isGlamaClient(url.searchParams.get('client_id'))) return request;
  const requested = (url.searchParams.get('scope') || '').split(/\s+/).filter(Boolean);
  const scopes = requested.filter(scope => GLAMA_MONITOR_SCOPES.includes(scope));
  if (!scopes.some(scope => scope !== 'offline_access')) throw new CloudError('invalid_scope', 'Request a Glama monitoring read scope.', 400);
  // Consent and the token response show only the reduced grant. Never issue a
  // write or pairing scope merely because a client copied discovery metadata.
  // The operator explicitly approved persistent monitoring. Glama copies tool
  // scopes only, so request renewal here and expose it on the consent screen.
  url.searchParams.set('scope', [...new Set(['offline_access', ...scopes])].join(' '));
  return new Request(url, request);
}
