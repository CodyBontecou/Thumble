import { APIError } from 'better-auth/api';
import { decryptOAuthToken } from 'better-auth/oauth2';
import { CloudError } from '@tapping/cloud-contracts';
import { generateAppleClientSecret } from './apple.js';

export const FRESH_SESSION_SECONDS = 300;
export async function cloudAccountId(issuer, subject) {
  const bytes = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(`${issuer}\n${subject}`)));
  return Array.from(bytes, byte => byte.toString(16).padStart(2, '0')).join('');
}
async function first(db, sql, values) {
  const statement = db.prepare(sql);
  // Better Auth also supports Node's native SQLite for local integration tests.
  return typeof statement.bind === 'function' ? statement.bind(...values).first() : statement.get(...values);
}
export async function assertActiveIdentity(env, issuer, subject) {
  const accountId = await cloudAccountId(issuer, subject);
  const user = await first(env.DB, 'SELECT id FROM user WHERE id = ? AND NOT EXISTS (SELECT 1 FROM cloud_deleted_accounts WHERE account_id = ?)', [subject, accountId]);
  if (!user) throw new CloudError('account_deleted', 'This account was deleted. Its saved credentials can be cleared from this phone.', 401);
}
async function atomic(env, entries) {
  if (typeof env.DB.batch === 'function') return env.DB.batch(entries.map(([sql, values]) => env.DB.prepare(sql).bind(...values)));
  env.DB.exec('BEGIN IMMEDIATE');
  try { for (const [sql, values] of entries) env.DB.prepare(sql).run(...values); env.DB.exec('COMMIT'); }
  catch (error) { env.DB.exec('ROLLBACK'); throw error; }
}
async function revokeApple(env, context, account) {
  try {
    const storedToken = account.refreshToken || account.accessToken;
    if (!storedToken) throw new Error('Missing provider credential');
    const token = await decryptOAuthToken(storedToken, context);
    const secret = await generateAppleClientSecret(env);
    const response = await fetch('https://appleid.apple.com/auth/revoke', {
      method: 'POST', redirect: 'error', signal: AbortSignal.timeout(8000),
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ client_id: env.APPLE_CLIENT_ID, client_secret: secret, token, token_type_hint: account.refreshToken ? 'refresh_token' : 'access_token' }),
    });
    await response.body?.cancel();
    if (!response.ok) throw new Error('Provider revocation rejected');
  } catch {
    console.warn(JSON.stringify({ event: 'apple_revocation_failed' }));
    throw new APIError('SERVICE_UNAVAILABLE', { code: 'APPLE_REVOCATION_FAILED', message: 'Apple access could not be revoked. Your account is still available. Sign in with Apple again and retry deletion.' });
  }
}
export async function prepareAccountDeletion(env, { user, request, context, issuer }) {
  const accountId = await cloudAccountId(issuer, user.id);
  if (!request || request.headers.get('x-thumble-account-id') !== accountId) throw new APIError('FORBIDDEN', { code: 'ACCOUNT_MISMATCH', message: 'The signed-in account changed. Reopen account settings before deleting.' });
  const accounts = await context.adapter.findMany({ model: 'account', where: [{ field: 'userId', value: user.id }] });
  // Nothing is erased or tombstoned until each Apple credential is revoked.
  for (const account of accounts.filter(value => value.providerId === 'apple')) await revokeApple(env, context, account);
  await atomic(env, [
    ['INSERT OR IGNORE INTO cloud_deleted_accounts (account_id,deleted_at) VALUES (?,?)', [accountId, new Date().toISOString()]],
    ['DELETE FROM deliveries WHERE account_id = ?', [accountId]],
    ['DELETE FROM receiver_pairing_sessions WHERE account_id = ?', [accountId]],
    ['DELETE FROM devices WHERE account_id = ?', [accountId]],
    ['DELETE FROM profile_revisions WHERE account_id = ?', [accountId]],
    ['DELETE FROM verification WHERE CASE WHEN json_valid(value) THEN json_extract(value, \'$.userId\') = ? OR json_extract(value, \'$.link.userId\') = ? ELSE 0 END', [user.id, user.id]],
  ]);
  // Better Auth subsequently removes accounts, sessions and the user. Existing
  // OAuth tokens/consents cascade from that user via the generated schema.
}

export async function completeAccountDeletion(env, user) {
  // Catch authorization codes issued by requests already in flight before the
  // user DELETE. The migration's insert guard prevents later orphaned codes.
  await atomic(env, [["DELETE FROM verification WHERE CASE WHEN json_valid(value) THEN json_extract(value, '$.userId') = ? OR json_extract(value, '$.link.userId') = ? ELSE 0 END", [user.id, user.id]]]);
}
