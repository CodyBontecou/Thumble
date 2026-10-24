import { randomUUID } from 'node:crypto';

export const GEMINI_CLIENT_ID = 'thumble-gemini-cli';
export const GEMINI_REDIRECT_URI = 'http://localhost:7777/oauth/callback';
export const GEMINI_SCOPES = Object.freeze(['offline_access', 'profiles:read', 'devices:read', 'deliveries:read']);

// Public native client: exact loopback callback, consent, PKCE and read-only scopes.
// A fixed port avoids opening dynamic registration or callback wildcards.
export function geminiClientSql() {
  const now = new Date().toISOString();
  const row = { id: randomUUID(), clientId: GEMINI_CLIENT_ID, name: 'Gemini CLI', redirectUris: [GEMINI_REDIRECT_URI], applicationType: 'native', tokenEndpointAuthMethod: 'none', requirePKCE: true, skipConsent: false, disabled: false, subjectType: 'public', scopes: GEMINI_SCOPES, clientCredentialsScopes: [], grantTypes: ['authorization_code', 'refresh_token'], responseTypes: ['code'], createdAt: now, updatedAt: now };
  const quote = value => "'" + String(value).replaceAll("'", "''") + "'";
  const entries = Object.entries(row).map(([key, value]) => [key, Array.isArray(value) ? JSON.stringify(value) : typeof value === 'boolean' ? Number(value) : value]);
  return `INSERT INTO oauthClient (${entries.map(([key]) => '"' + key + '"').join(',')}) VALUES (${entries.map(([, value]) => typeof value === 'number' ? value : quote(value)).join(',')});\nINSERT INTO oauthClientResource (id,clientId,resourceId,createdAt) VALUES (${quote(randomUUID())},${quote(GEMINI_CLIENT_ID)},'https://thumble.io/mcp',${quote(now)});\n`;
}
