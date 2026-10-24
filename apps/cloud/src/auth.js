import { createLocalJWKSet, createRemoteJWKSet, jwtVerify } from 'jose';
import { assertActiveIdentity } from './deletion.js';
import { createIdentity, identityConfig, CHATGPT_SCOPES } from './identity.js';
import { API_VERSION, CLOUD_SCOPES, CloudError, validServiceUrl } from '@tapping/cloud-contracts';

const remoteKeys = new Map();
function configuredUrl(value) {
  return typeof value === 'string' && validServiceUrl(value) ? value : null;
}
export function authConfig(env) {
  if (env.BETTER_AUTH_URL) { const { issuer, resource } = identityConfig(env); return { issuer, audience: resource }; }
  const issuer = configuredUrl(env.OAUTH_ISSUER);
  const audience = typeof env.OAUTH_AUDIENCE === 'string' && env.OAUTH_AUDIENCE.trim() ? env.OAUTH_AUDIENCE : null;
  if (!issuer || !audience || (!env.OAUTH_JWKS_JSON && !configuredUrl(env.OAUTH_JWKS_URL))) {
    throw new CloudError('not_configured', 'Cloud sign-in is not configured.', 503);
  }
  return { issuer, audience };
}
export function getPublicConfig(request, env) {
  if (env.BETTER_AUTH_URL) {
    const config = identityConfig(env);
    if (!env.BETTER_AUTH_SECRET || env.BETTER_AUTH_SECRET.length < 32 || !env.DB) throw new CloudError('not_configured', 'Cloud sign-in is not configured.', 503);
    return { apiVersion: API_VERSION, auth: { issuer: config.issuer, authorizationEndpoint: `${config.issuer}/oauth2/authorize`, tokenEndpoint: `${config.issuer}/oauth2/token`, mobileClientId: config.mobileClientId, audience: config.resource, scopes: config.scopes }, mcpUrl: config.resource };
  }
  const { issuer, audience } = authConfig(env);
  const authorizationEndpoint = configuredUrl(env.OAUTH_AUTHORIZATION_ENDPOINT);
  const tokenEndpoint = configuredUrl(env.OAUTH_TOKEN_ENDPOINT);
  if (!authorizationEndpoint || !tokenEndpoint || !env.OAUTH_MOBILE_CLIENT_ID) throw new CloudError('not_configured', 'Cloud sign-in is not configured.', 503);
  return { apiVersion: API_VERSION, auth: { issuer, authorizationEndpoint, tokenEndpoint, mobileClientId: env.OAUTH_MOBILE_CLIENT_ID, audience, scopes: ['openid', ...CLOUD_SCOPES] }, mcpUrl: new URL('/mcp', request.url).href };
}
export function bearerToken(request) {
  const match = /^Bearer ([^\s]+)$/i.exec(request.headers.get('authorization') || '');
  if (!match) throw new CloudError('unauthorized', 'A valid access token is required.', 401);
  return match[1];
}
export async function sha256(value) {
  return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value))), byte => byte.toString(16).padStart(2, '0')).join('');
}
export async function authenticateAccount(request, env) {
  const { issuer, audience } = authConfig(env);
  const token = bearerToken(request);
  try {
    let keys;
    if (env.BETTER_AUTH_URL) {
      const jwks = await (await createIdentity(env)).api.getJwks();
      keys = createLocalJWKSet(jwks);
    }
    else if (env.OAUTH_JWKS_JSON) keys = createLocalJWKSet(JSON.parse(env.OAUTH_JWKS_JSON));
    else {
      const cacheKey = `${issuer}\n${env.OAUTH_JWKS_URL}`;
      keys = remoteKeys.get(cacheKey);
      if (!keys) { keys = createRemoteJWKSet(new URL(env.OAUTH_JWKS_URL)); if (remoteKeys.size >= 8) remoteKeys.delete(remoteKeys.keys().next().value); remoteKeys.set(cacheKey, keys); }
    }
    const { payload } = await jwtVerify(token, keys, { issuer, audience, algorithms: ['RS256', 'ES256', 'EdDSA'], requiredClaims: ['sub', 'exp', 'iat'] });
    if (typeof payload.sub !== 'string' || !payload.sub.trim() || typeof payload.scope !== 'string') throw new Error('Invalid claims');
    if (env.BETTER_AUTH_URL) await assertActiveIdentity(env, issuer, payload.sub);
    if (env.BETTER_AUTH_URL && (payload.client_id ?? payload.azp) === 'thumble-chatgpt' && payload.scope.split(/\s+/).some(scope => !CHATGPT_SCOPES.includes(scope))) throw new CloudError('forbidden', 'Reconnect ChatGPT with the current controller permissions.', 403);
    return { kind: 'account', accountId: await sha256(`${issuer}\n${payload.sub}`), scopes: payload.scope.split(/\s+/).filter(Boolean) };
  } catch (error) {
    if (error instanceof CloudError && ['account_deleted', 'forbidden'].includes(error.code)) throw error;
    throw new CloudError('unauthorized', 'The access token is invalid or expired. Sign in again.', 401);
  }
}
export async function authenticateDevice(request, env, deviceId) {
  const token = bearerToken(request);
  const device = await env.DB.prepare('SELECT * FROM devices WHERE id = ? AND token_hash = ? AND revoked_at IS NULL AND token_expires_at > ?').bind(deviceId, await sha256(token), new Date().toISOString()).first();
  if (!device) throw new CloudError('unauthorized', 'This phone connection has expired or was revoked. Reconnect the phone.', 401);
  await env.DB.prepare('UPDATE devices SET last_seen_at = ? WHERE id = ?').bind(new Date().toISOString(), deviceId).run();
  return device;
}
