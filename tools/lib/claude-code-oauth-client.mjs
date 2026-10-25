import { randomUUID } from 'node:crypto';

export const CLAUDE_CODE_CLIENT_ID = 'thumble-claude-code';
export const CLAUDE_CODE_REDIRECT_URI = 'http://localhost:8766/callback';
export const CLAUDE_CODE_SCOPES = Object.freeze(['offline_access', 'profiles:read', 'devices:read', 'deliveries:read']);

// Public native client: exact loopback callback, consent, PKCE and read-only scopes.
// A fixed port avoids opening dynamic registration or callback wildcards.
export function claudeCodeClientSql() {
  const now = new Date().toISOString();
  const row = { id: randomUUID(), clientId: CLAUDE_CODE_CLIENT_ID, name: 'Claude Code', redirectUris: [CLAUDE_CODE_REDIRECT_URI], applicationType: 'native', tokenEndpointAuthMethod: 'none', requirePKCE: true, skipConsent: false, disabled: false, subjectType: 'public', scopes: CLAUDE_CODE_SCOPES, clientCredentialsScopes: [], grantTypes: ['authorization_code', 'refresh_token'], responseTypes: ['code'], createdAt: now, updatedAt: now };
  const quote = value => "'" + String(value).replaceAll("'", "''") + "'";
  const entries = Object.entries(row).map(([key, value]) => [key, Array.isArray(value) ? JSON.stringify(value) : typeof value === 'boolean' ? Number(value) : value]);
  return `INSERT INTO oauthClient (${entries.map(([key]) => '"' + key + '"').join(',')}) VALUES (${entries.map(([, value]) => typeof value === 'number' ? value : quote(value)).join(',')});\nINSERT INTO oauthClientResource (id,clientId,resourceId,createdAt) VALUES (${quote(randomUUID())},${quote(CLAUDE_CODE_CLIENT_ID)},'https://thumble.io/mcp',${quote(now)});\n`;
}
