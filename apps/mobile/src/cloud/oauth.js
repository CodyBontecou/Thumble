import { validServiceUrl } from '@tapping/cloud-contracts';

// Public deployment address only. Tokens and provider credentials never enter
// the JS bundle; builds can select another service with EXPO_PUBLIC_CLOUD_URL.
export const PILOT_CLOUD_URL = 'https://thumble-cloud-pilot.costream.workers.dev';
export const DEFAULT_CLOUD_URL = process.env.EXPO_PUBLIC_CLOUD_URL || 'https://thumble.io';

export function validateCloudConfig(config, service, allowLocalhost = false) {
  if (!validServiceUrl(service, allowLocalhost)) throw Error('Use an HTTPS cloud service URL.');
  if (config?.apiVersion !== 1 || typeof config.auth?.mobileClientId !== 'string' || !config.auth.mobileClientId || !Array.isArray(config.auth.scopes) || config.auth.scopes.some(scope => typeof scope !== 'string' || !scope.trim() || /\s/.test(scope))) throw Error('This service has an unsupported sign-in configuration.');
  for (const field of ['issuer', 'authorizationEndpoint', 'tokenEndpoint']) {
    if (!validServiceUrl(config.auth[field], allowLocalhost)) throw Error('The identity provider requires valid HTTPS endpoints.');
  }
  // The trusted service can advertise its canonical MCP origin separately
  // from the API origin that hosts sign-in and phone registration.
  if (!validServiceUrl(config.mcpUrl, allowLocalhost) || config.auth.audience !== config.mcpUrl) throw Error('The identity provider must authorize this cloud service resource.');
  return config.auth;
}

export function authorizationConfig(auth, redirectUri) {
  return { clientId: auth.mobileClientId, scopes: [...new Set(['openid', 'offline_access', ...auth.scopes])], redirectUri, responseType: /** @type {const} */ ('code'), usePKCE: true, extraParams: { resource: auth.audience } };
}
/** @param {any} auth @param {string} redirectUri @param {string} code @param {string} verifier @param {string | undefined} responseIssuer */
export function codeExchangeConfig(auth, redirectUri, code, verifier, responseIssuer = undefined) {
  if (responseIssuer !== undefined && responseIssuer !== auth.issuer) throw Error('Sign-in returned from a different identity provider.');
  if (!code || !verifier) throw Error('Sign-in did not finish. Try again.');
  return { clientId: auth.mobileClientId, code, redirectUri, extraParams: { code_verifier: verifier, resource: auth.audience } };
}
export function refreshConfig(session) {
  if (!session.auth?.mobileClientId || !session.auth.audience || !session.refreshToken) throw Error('Your sign-in expired. Sign out and sign in again.');
  return { clientId: session.auth.mobileClientId, refreshToken: session.refreshToken, extraParams: { resource: session.auth.audience } };
}
export function tokenFields(result, previous = {}, now = Date.now()) {
  if (typeof result.accessToken !== 'string' || !result.accessToken || !Number.isFinite(result.expiresIn) || result.expiresIn <= 0) throw Error('The identity provider returned an invalid access token.');
  return { accessToken: result.accessToken, refreshToken: result.refreshToken || previous.refreshToken || null, expiresAt: now + result.expiresIn * 1000 };
}
