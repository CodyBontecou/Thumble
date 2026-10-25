import { randomUUID } from 'node:crypto';

import { MUSE_CLIENT_ID, MUSE_REDIRECT_URI, MUSE_SCOPES } from '../../apps/cloud/src/muse-client.js';
export { MUSE_CLIENT_ID, MUSE_REDIRECT_URI, MUSE_SCOPES };

// Operator-managed public client: authorization always requires user sign-in,
// explicit consent and PKCE. The exact callback was confirmed in Muse's live secure flow.
export function museClientSql() {
  const now = new Date().toISOString();
  const row = { id: randomUUID(), clientId: MUSE_CLIENT_ID, name: 'Muse', redirectUris: [MUSE_REDIRECT_URI], applicationType: 'web', tokenEndpointAuthMethod: 'none', requirePKCE: true, skipConsent: false, disabled: false, subjectType: 'public', scopes: MUSE_SCOPES, clientCredentialsScopes: [], grantTypes: ['authorization_code', 'refresh_token'], responseTypes: ['code'], createdAt: now, updatedAt: now };
  const quote = value => "'" + String(value).replaceAll("'", "''") + "'";
  const entries = Object.entries(row).map(([key, value]) => [key, Array.isArray(value) ? JSON.stringify(value) : typeof value === 'boolean' ? Number(value) : value]);
  return `INSERT INTO oauthClient (${entries.map(([key]) => '"' + key + '"').join(',')}) VALUES (${entries.map(([, value]) => typeof value === 'number' ? value : quote(value)).join(',')});\nINSERT INTO oauthClientResource (id,clientId,resourceId,createdAt) VALUES (${quote(randomUUID())},${quote(MUSE_CLIENT_ID)},'https://thumble.io/mcp',${quote(now)});\n`;
}
