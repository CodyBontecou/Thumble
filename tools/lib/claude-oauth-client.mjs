import { createHash, randomUUID } from 'node:crypto';

export const CLAUDE_SCOPES = Object.freeze(['openid', 'offline_access', 'profiles:read', 'profiles:write', 'devices:read', 'deliveries:write', 'deliveries:read']);
export const CLAUDE_CLIENT_ID = 'thumble-claude';
export const CLAUDE_REDIRECT_URI = 'https://claude.ai/api/mcp/auth_callback';
// Operator-managed confidential client. This registers an OAuth application,
// not a user or session; every user must still sign in and grant consent.
export function claudeClientRow(secret, scopes = CLAUDE_SCOPES) {
  if (typeof secret !== 'string' || secret.length < 32) throw Error('Use a fresh client secret of at least 32 characters.');
  if (!Array.isArray(scopes) || scopes.some(scope => !CLAUDE_SCOPES.includes(scope))) throw Error('Claude must use only the hosted AI permission set.');
  const now = new Date().toISOString();
  return { id: randomUUID(), clientId: CLAUDE_CLIENT_ID, clientSecret: createHash('sha256').update(secret).digest('base64url'), name: 'Claude', redirectUris: [CLAUDE_REDIRECT_URI], applicationType: 'web', tokenEndpointAuthMethod: 'client_secret_post', requirePKCE: true, skipConsent: false, disabled: false, subjectType: 'public', scopes: [...scopes], clientCredentialsScopes: [], grantTypes: ['authorization_code', 'refresh_token'], responseTypes: ['code'], createdAt: now, updatedAt: now };
}
export function claudeClientSql(row, resource = 'https://thumble.io/mcp') {
  if (resource !== 'https://thumble.io/mcp') throw Error('Use the canonical Thumble resource.');
  const quote = value => "'" + String(value).replaceAll("'", "''") + "'";
  const entries = Object.entries(row).map(([key, value]) => [key, Array.isArray(value) ? JSON.stringify(value) : typeof value === 'boolean' ? Number(value) : value]);
  return `INSERT INTO oauthClient (${entries.map(([key]) => '"' + key + '"').join(',')}) VALUES (${entries.map(([, value]) => typeof value === 'number' ? value : quote(value)).join(',')});\nINSERT INTO oauthClientResource (id,clientId,resourceId,createdAt) VALUES (${quote(randomUUID())},${quote(CLAUDE_CLIENT_ID)},${quote(resource)},${quote(row.createdAt)});\n`;
}
