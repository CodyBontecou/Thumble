import { randomUUID } from 'node:crypto';

export const GROK_CLIENT_ID = 'thumble-grok';
export const GROK_REDIRECT_URI = 'https://grok.com/connectors-oauth-exchange-code/';
export const GROK_SCOPES = Object.freeze(['openid', 'offline_access', 'profiles:read', 'devices:read', 'deliveries:read']);

// Operator-managed public client: authorization always requires user sign-in,
// explicit consent and PKCE. The exact callback is published by Grok's CIMD.
export function grokClientSql() {
  const now = new Date().toISOString();
  const row = { id: randomUUID(), clientId: GROK_CLIENT_ID, name: 'Grok', redirectUris: [GROK_REDIRECT_URI], applicationType: 'web', tokenEndpointAuthMethod: 'none', requirePKCE: true, skipConsent: false, disabled: false, subjectType: 'public', scopes: GROK_SCOPES, clientCredentialsScopes: [], grantTypes: ['authorization_code', 'refresh_token'], responseTypes: ['code'], createdAt: now, updatedAt: now };
  const quote = value => "'" + String(value).replaceAll("'", "''") + "'";
  const entries = Object.entries(row).map(([key, value]) => [key, Array.isArray(value) ? JSON.stringify(value) : typeof value === 'boolean' ? Number(value) : value]);
  return `INSERT INTO oauthClient (${entries.map(([key]) => '"' + key + '"').join(',')}) VALUES (${entries.map(([, value]) => typeof value === 'number' ? value : quote(value)).join(',')});\nINSERT INTO oauthClientResource (id,clientId,resourceId,createdAt) VALUES (${quote(randomUUID())},${quote(GROK_CLIENT_ID)},'https://thumble.io/mcp',${quote(now)});\n`;
}
