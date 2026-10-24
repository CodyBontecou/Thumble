import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import { generateKeyPair, exportJWK, SignJWT } from 'jose';
import { CLOUD_SCOPES } from '@tapping/cloud-contracts';

// Real SQLite, with D1's small prepared-statement interface and atomic batch semantics.
// Production uses the DB binding; this adapter is test-only and never shipped into the Worker.
export function createTestDb() {
  const sqlite = new DatabaseSync(':memory:');
  sqlite.exec('PRAGMA foreign_keys=ON');
  for (const migration of ['0001_cloud.sql', '0002_better_auth.sql', '0003_account_deletion.sql', '0004_provider_data_minimization.sql', '0005_receiver_pairing.sql']) {
    sqlite.exec(readFileSync(new URL(`../migrations/${migration}`, import.meta.url), 'utf8'));
  }
  function prepare(sql, bindings = []) {
    return {
      bind(...values) { return prepare(sql, values); },
      async first() { return sqlite.prepare(sql).get(...bindings) || null; },
      async all() { return { results: sqlite.prepare(sql).all(...bindings), success: true }; },
      _run() { const result = sqlite.prepare(sql).run(...bindings); return { success: true, meta: { changes: Number(result.changes) } }; },
      async run() { return this._run(); },
    };
  }
  return {
    prepare,
    async batch(statements) {
      sqlite.exec('BEGIN IMMEDIATE');
      try { const results = []; for (const statement of statements) results.push(statement._run()); sqlite.exec('COMMIT'); return results; }
      catch (error) { sqlite.exec('ROLLBACK'); throw error; }
    },
    close() { sqlite.close(); },
    sqlite,
  };
}
export async function createTestAuthority() {
  const { publicKey, privateKey } = await generateKeyPair('ES256');
  const jwk = { ...await exportJWK(publicKey), kid: 'pilot-test', alg: 'ES256', use: 'sig' };
  const env = { AI_CONTROLLER_GENERATOR_ENABLED: 'true',
    OAUTH_ISSUER: 'https://identity.example.test/', OAUTH_AUDIENCE: 'https://cloud.example.test/mcp',
    OAUTH_JWKS_JSON: JSON.stringify({ keys: [jwk] }),
    OAUTH_AUTHORIZATION_ENDPOINT: 'https://identity.example.test/authorize',
    OAUTH_TOKEN_ENDPOINT: 'https://identity.example.test/token', OAUTH_MOBILE_CLIENT_ID: 'pilot-mobile',
  };
  async function token({ sub = 'owner', scope = CLOUD_SCOPES.join(' '), issuer = env.OAUTH_ISSUER, audience = env.OAUTH_AUDIENCE, expires = '1h' } = {}) {
    return new SignJWT({ scope }).setProtectedHeader({ alg: 'ES256', kid: 'pilot-test' }).setSubject(sub).setIssuer(issuer).setAudience(audience).setIssuedAt().setExpirationTime(expires).sign(privateKey);
  }
  return { env, token };
}
export function apiRequest(path, token, { method = 'GET', body } = {}) {
  return new Request(`https://cloud.example.test/v1${path}`, { method, headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body === undefined ? {} : { 'Content-Type': 'application/json' }) }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
}
