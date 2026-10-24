import { CloudError, SCOPES, requireId, requireScope } from '@tapping/cloud-contracts';
import { authenticateAccount, bearerToken, sha256 } from './auth.js';

export const PAIRING_SESSION_MS = 10 * 60_000;
export const PAIRING_FRESH_MS = 30_000;
const unavailable = () => new CloudError('pairing_unavailable', 'On your Mac, choose Pair through ChatGPT… in the Thumble Receiver menu, sign in to the same Thumble account, then ask for the QR code again.', 404);
export async function cleanPairingSessions(env, now = Date.now()) {
  await env.DB.batch([
    env.DB.prepare('DELETE FROM receiver_pairing_sessions WHERE session_expires_at <= ?').bind(now),
    env.DB.prepare('UPDATE receiver_pairing_sessions SET png = NULL,code_expires_at = NULL WHERE code_expires_at <= ? OR updated_at <= ?').bind(now, now - PAIRING_FRESH_MS),
  ]);
}
function validPng(value) {
  if (typeof value !== 'string' || value.length > 100_000 || !/^[A-Za-z0-9+/]+={0,2}$/.test(value)) return false;
  try {
    const bytes = Uint8Array.from(atob(value), c => c.charCodeAt(0));
    if (bytes.length < 33 || ![137,80,78,71,13,10,26,10].every((byte, i) => bytes[i] === byte) || String.fromCharCode(...bytes.slice(12,16)) !== 'IHDR') return false;
    const view = new DataView(bytes.buffer), width = view.getUint32(16), height = view.getUint32(20);
    return width >= 128 && width <= 2048 && width === height;
  } catch { return false; }
}

/** Receiver writes require their own expiring capability; account reads never expose it. */
export async function handlePairingApi(request, env, path, { body, json }) {
  const now = Date.now();
  if (path[0] === 'pairing-code' && path.length === 1 && request.method === 'GET') {
    const principal = await authenticateAccount(request, env);
    requireScope(principal, SCOPES.pairingRead);
    const id = new URL(request.url).searchParams.get('receiverId');
    if (id !== null) requireId(id, 'receiverId');
    const { results } = await env.DB.prepare('SELECT id,name,connected,png,code_expires_at FROM receiver_pairing_sessions WHERE account_id = ? AND session_expires_at > ? AND updated_at > ? ORDER BY id LIMIT 5').bind(principal.accountId, now, now - PAIRING_FRESH_MS).all();
    const candidates = results.filter(row => !id || row.id === id);
    if (!candidates.length) throw unavailable();
    if (candidates.length > 1) throw new CloudError('choose_receiver', 'Ask which Mac to pair, then call show_pairing_code with its receiverId.', 409, { receivers: candidates.map(({ id, name }) => ({ receiverId: id, name })) });
    const row = candidates[0];
    if (row.connected) throw new CloudError('already_paired', 'This Mac already has a paired phone. It has not been disconnected. Use the receiver menu to disconnect only if you want to pair another phone.', 409);
    if (!row.png || row.code_expires_at <= now) throw unavailable();
    return json({ receiverId: row.id, name: row.name, expiresAt: row.code_expires_at, png: row.png });
  }
  if (path[0] !== 'receiver-pairing') throw unavailable();
  if (path.length === 1 && request.method === 'POST') {
    const principal = await authenticateAccount(request, env);
    requireScope(principal, SCOPES.pairingManage);
    const value = await body(request);
    if (Object.keys(value).some(key => key !== 'name') || typeof value.name !== 'string' || !value.name.trim() || value.name.length > 100) throw new CloudError('invalid_request', 'Provide a Mac name.');
    await cleanPairingSessions(env, now);
    const receiverId = crypto.randomUUID(), publisherToken = `rp_${Array.from(crypto.getRandomValues(new Uint8Array(32)), b => b.toString(16).padStart(2, '0')).join('')}`;
    const expiresAt = now + PAIRING_SESSION_MS;
    const inserted = await env.DB.prepare('INSERT INTO receiver_pairing_sessions (id,account_id,name,publisher_hash,session_expires_at,updated_at) SELECT ?,?,?,?,?,? WHERE (SELECT COUNT(*) FROM receiver_pairing_sessions WHERE account_id = ?) < 4').bind(receiverId, principal.accountId, value.name.trim(), await sha256(publisherToken), expiresAt, now, principal.accountId).run();
    if (!inserted.meta.changes) throw new CloudError('pairing_limit', 'Stop an existing ChatGPT pairing session before starting another.', 409);
    return json({ receiverId, publisherToken, expiresAt }, 201);
  }
  if (path.length !== 2 || !['PUT', 'DELETE'].includes(request.method)) throw new CloudError('not_found', 'This resource was not found.', 404);
  const id = requireId(path[1], 'receiverId'), hash = await sha256(bearerToken(request));
  const session = await env.DB.prepare('SELECT id FROM receiver_pairing_sessions WHERE id = ? AND publisher_hash = ? AND session_expires_at > ?').bind(id, hash, now).first();
  if (!session) throw new CloudError('unauthorized', 'ChatGPT pairing sharing expired or was stopped. Start it again from the receiver menu.', 401);
  if (request.method === 'DELETE') {
    await env.DB.prepare('DELETE FROM receiver_pairing_sessions WHERE id = ? AND publisher_hash = ?').bind(id, hash).run();
    return json({ revoked: true });
  }
  const value = await body(request);
  if (Object.keys(value).some(key => !['sequence','connected','png','expiresAt'].includes(key)) || !Number.isSafeInteger(value.sequence) || value.sequence < 1 || typeof value.connected !== 'boolean') throw new CloudError('invalid_request', 'Provide an ordered receiver status.');
  if (value.connected ? value.png != null || value.expiresAt != null : !validPng(value.png) || !Number.isSafeInteger(value.expiresAt) || value.expiresAt <= now || value.expiresAt > now + 120_000) throw new CloudError('invalid_request', 'Provide a current pairing PNG, or clear it when a phone connects.');
  const updated = await env.DB.prepare('UPDATE receiver_pairing_sessions SET sequence = ?,connected = ?,png = ?,code_expires_at = ?,updated_at = ? WHERE id = ? AND publisher_hash = ? AND session_expires_at > ? AND sequence < ?').bind(value.sequence, value.connected ? 1 : 0, value.connected ? null : value.png, value.connected ? null : value.expiresAt, now, id, hash, now, value.sequence).run();
  if (!updated.meta.changes) throw new CloudError('pairing_conflict', 'A newer receiver status has already been accepted.', 409);
  return json({ accepted: true });
}
