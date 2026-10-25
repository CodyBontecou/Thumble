import { randomUUID } from 'node:crypto';

import { CLINE_CLIENT_ID, CLINE_REDIRECT_URI, CLINE_SCOPES } from '../../apps/cloud/src/cline-client.js';
export { CLINE_CLIENT_ID, CLINE_REDIRECT_URI, CLINE_SCOPES };

// Public native client: exact loopback callback, consent, PKCE and read-only scopes.
// A fixed port avoids opening dynamic registration or callback wildcards.
export function clineClientSql() {
  const now = new Date().toISOString();
  const row = { id: randomUUID(), clientId: CLINE_CLIENT_ID, name: 'Cline', redirectUris: [CLINE_REDIRECT_URI], applicationType: 'native', tokenEndpointAuthMethod: 'none', requirePKCE: true, skipConsent: false, disabled: false, subjectType: 'public', scopes: CLINE_SCOPES, clientCredentialsScopes: [], grantTypes: ['authorization_code', 'refresh_token'], responseTypes: ['code'], createdAt: now, updatedAt: now };
  const quote = value => "'" + String(value).replaceAll("'", "''") + "'";
  const entries = Object.entries(row).map(([key, value]) => [key, Array.isArray(value) ? JSON.stringify(value) : typeof value === 'boolean' ? Number(value) : value]);
  return `INSERT INTO oauthClient (${entries.map(([key]) => '"' + key + '"').join(',')}) VALUES (${entries.map(([, value]) => typeof value === 'number' ? value : quote(value)).join(',')});\nINSERT INTO oauthClientResource (id,clientId,resourceId,createdAt) VALUES (${quote(randomUUID())},${quote(CLINE_CLIENT_ID)},'https://thumble.io/mcp',${quote(now)});\n`;
}
