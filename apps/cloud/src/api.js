import { CloudError, MAX_BODY_BYTES, SCOPES, requireId, requireRevision, requireScope, validateCloudProfile } from '@tapping/cloud-contracts';
import { authenticateAccount, authenticateDevice, getPublicConfig, sha256 } from './auth.js';

export function json(data, status = 200) {
  return Response.json(data, { status, headers: { 'Cache-Control': 'no-store' } });
}
export function errorResponse(error) {
  if (error instanceof CloudError) return json({ error: { code: error.code, message: error.message, ...(error.details === undefined ? {} : { details: error.details }) } }, error.status);
  console.error(JSON.stringify({ event: 'cloud_request_failed', name: error?.name || 'Error' }));
  return json({ error: { code: 'internal_error', message: 'The cloud service could not complete this request.' } }, 500);
}
async function body(request) {
  if (!request.headers.get('content-type')?.toLowerCase().startsWith('application/json')) throw new CloudError('invalid_request', 'Send an application/json body.');
  const reader = request.body?.getReader();
  if (!reader) throw new CloudError('invalid_request', 'A JSON body is required.');
  const chunks = []; let size = 0;
  while (true) {
    const { done, value } = await reader.read(); if (done) break;
    size += value.byteLength;
    if (size > MAX_BODY_BYTES) { await reader.cancel(); throw new CloudError('payload_too_large', 'The profile request is too large.', 413); }
    chunks.push(value);
  }
  try {
    const bytes = new Uint8Array(size); let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
    const value = JSON.parse(new TextDecoder().decode(bytes));
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error();
    return value;
  } catch { throw new CloudError('invalid_request', 'The request must contain a JSON object.'); }
}
function notFound() { throw new CloudError('not_found', 'This resource was not found.', 404); }
function deviceValue(row) {
  return { id: row.id, name: row.name, platform: row.platform, viewport: { width: row.width, height: row.height }, createdAt: row.created_at, lastSeenAt: row.last_seen_at, revokedAt: row.revoked_at };
}
function deliveryValue(row) {
  return { id: row.id, deviceId: row.device_id, profileId: row.profile_id, profileRevision: row.profile_revision, requestId: row.request_id, state: row.state, createdAt: row.created_at, updatedAt: row.updated_at, error: row.error };
}
function revisionValue(row) { return { profile: validateCloudProfile(JSON.parse(row.profile_json)), revision: row.revision, createdAt: row.created_at }; }
async function deviceOwned(db, accountId, id) {
  const row = await db.prepare('SELECT * FROM devices WHERE id = ? AND account_id = ? AND revoked_at IS NULL AND token_expires_at > ?').bind(id, accountId, new Date().toISOString()).first();
  if (!row) notFound(); return row;
}
async function getRevision(db, accountId, profileId, revision) {
  const row = revision === undefined
    ? await db.prepare('SELECT * FROM profile_revisions WHERE account_id = ? AND profile_id = ? ORDER BY revision DESC LIMIT 1').bind(accountId, profileId).first()
    : await db.prepare('SELECT * FROM profile_revisions WHERE account_id = ? AND profile_id = ? AND revision = ?').bind(accountId, profileId, revision).first();
  if (!row) notFound(); return row;
}
async function accountRoute(request, env, path) {
  const principal = await authenticateAccount(request, env), account = principal.accountId, db = env.DB;
  const method = request.method, now = new Date().toISOString();
  if (method === 'GET' && path.length === 1 && path[0] === 'me') return json({ accountId: account });
  if (path[0] === 'devices' && path.length === 1) {
    if (method === 'GET') {
      requireScope(principal, SCOPES.deviceRead);
      const { results } = await db.prepare('SELECT * FROM devices WHERE account_id = ? AND revoked_at IS NULL AND token_expires_at > ? ORDER BY created_at DESC').bind(account, now).all();
      return json({ devices: results.map(deviceValue) });
    }
    if (method === 'POST') {
      requireScope(principal, SCOPES.deviceManage); const value = await body(request);
      if (typeof value.name !== 'string' || !value.name.trim() || value.name.length > 100 || !['ios', 'android'].includes(value.platform) || !Number.isFinite(value.viewport?.width) || !Number.isFinite(value.viewport?.height) || value.viewport.width <= 0 || value.viewport.height <= 0 || value.viewport.width > 10000 || value.viewport.height > 10000) throw new CloudError('invalid_request', 'Provide a phone name, platform and valid logical viewport.');
      const id = crypto.randomUUID(), deviceToken = `td_${Array.from(crypto.getRandomValues(new Uint8Array(32)), b => b.toString(16).padStart(2, '0')).join('')}`, expiresAt = new Date(Date.now() + 30 * 86400000).toISOString();
      await db.prepare('INSERT INTO devices (id,account_id,name,platform,width,height,token_hash,token_expires_at,created_at,last_seen_at) VALUES (?,?,?,?,?,?,?,?,?,?)').bind(id, account, value.name.trim(), value.platform, value.viewport.width, value.viewport.height, await sha256(deviceToken), expiresAt, now, now).run();
      return json({ device: deviceValue(await deviceOwned(db, account, id)), deviceToken, expiresAt }, 201);
    }
  }
  if (path[0] === 'devices' && path.length === 2 && method === 'DELETE') {
    requireScope(principal, SCOPES.deviceManage); const id = requireId(path[1], 'deviceId'); await deviceOwned(db, account, id);
    await db.batch([
      db.prepare('UPDATE devices SET revoked_at = ? WHERE id = ? AND account_id = ?').bind(now, id, account),
      db.prepare("UPDATE deliveries SET state = 'superseded',updated_at = ? WHERE device_id = ? AND account_id = ? AND state IN ('queued','received')").bind(now, id, account),
    ]);
    return json({ revoked: true });
  }
  if (path[0] === 'profiles') {
    if (method === 'POST' && path.length === 1) {
      requireScope(principal, SCOPES.profileWrite); const value = await body(request), profile = validateCloudProfile(value.profile), expected = requireRevision(value.expectedRevision, true);
      if (!Number.isSafeInteger(expected + 1)) throw new CloudError('invalid_request', 'The next revision exceeds the supported range.');
      const row = await db.prepare('INSERT INTO profile_revisions (account_id,profile_id,revision,name,profile_json,created_at) SELECT ?,?,?,?,?,? WHERE COALESCE((SELECT MAX(revision) FROM profile_revisions WHERE account_id = ? AND profile_id = ?),0) = ? RETURNING *').bind(account, profile.id, expected + 1, profile.name, JSON.stringify(profile), now, account, profile.id, expected).first();
      if (!row) throw new CloudError('revision_conflict', 'The saved profile changed. Fetch the latest revision before saving again.', 409);
      return json(revisionValue(row), 201);
    }
    if (method === 'GET') {
      requireScope(principal, SCOPES.profileRead);
      if (path.length === 1) {
        const { results } = await db.prepare('SELECT p.profile_id AS id,p.name,p.revision,p.created_at AS updatedAt FROM profile_revisions p WHERE p.account_id = ? AND p.revision = (SELECT MAX(q.revision) FROM profile_revisions q WHERE q.account_id = p.account_id AND q.profile_id = p.profile_id) ORDER BY p.created_at DESC').bind(account).all();
        return json({ profiles: results });
      }
      if (path.length === 2 || (path.length === 4 && path[2] === 'revisions')) {
        const revision = path.length === 4 ? requireRevision(Number(path[3])) : undefined;
        return json(revisionValue(await getRevision(db, account, requireId(path[1], 'profileId'), revision)));
      }
    }
  }
  if (path[0] === 'deliveries') {
    if (method === 'GET' && path.length === 2) {
      requireScope(principal, SCOPES.deliveryRead);
      const row = await db.prepare('SELECT * FROM deliveries WHERE id = ? AND account_id = ?').bind(requireId(path[1], 'deliveryId'), account).first();
      if (!row) notFound(); return json({ delivery: deliveryValue(row) });
    }
    if (method === 'POST' && path.length === 1) {
      requireScope(principal, SCOPES.deliveryWrite); const value = await body(request);
      const deviceId = requireId(value.deviceId, 'deviceId'), profileId = requireId(value.profileId, 'profileId'), revision = requireRevision(value.profileRevision), requestId = requireId(value.requestId, 'requestId');
      const existing = await db.prepare('SELECT * FROM deliveries WHERE account_id = ? AND request_id = ?').bind(account, requestId).first();
      const check = row => { if (row.device_id !== deviceId || row.profile_id !== profileId || row.profile_revision !== revision) throw new CloudError('delivery_conflict', 'This requestId already targets a different delivery.', 409); return json({ delivery: deliveryValue(row) }, 201); };
      if (existing) return check(existing);
      await deviceOwned(db, account, deviceId); await getRevision(db, account, profileId, revision);
      const id = crypto.randomUUID();
      await db.batch([
        db.prepare("INSERT INTO deliveries (id,account_id,device_id,profile_id,profile_revision,request_id,state,created_at,updated_at) SELECT ?,?,?,?,?,?,'queued',?,? WHERE EXISTS(SELECT 1 FROM devices WHERE id = ? AND account_id = ? AND revoked_at IS NULL AND token_expires_at > ?) ON CONFLICT(account_id,request_id) DO NOTHING").bind(id, account, deviceId, profileId, revision, requestId, now, now, deviceId, account, now),
        db.prepare("UPDATE deliveries SET state = 'superseded',updated_at = ? WHERE device_id = ? AND account_id = ? AND id != ? AND state IN ('queued','received') AND EXISTS(SELECT 1 FROM deliveries WHERE id = ?)").bind(now, deviceId, account, id, id),
      ]);
      const row = await db.prepare('SELECT * FROM deliveries WHERE account_id = ? AND request_id = ?').bind(account, requestId).first();
      if (!row) notFound(); return check(row);
    }
  }
  notFound();
}
async function deviceRoute(request, env, path) {
  const deviceId = requireId(path[1], 'deviceId'), device = await authenticateDevice(request, env, deviceId), db = env.DB;
  if (request.method === 'GET' && path.length === 3) {
    const { results } = await db.prepare("SELECT * FROM deliveries WHERE device_id = ? AND account_id = ? AND state IN ('queued','received') ORDER BY created_at DESC LIMIT 1").bind(deviceId, device.account_id).all();
    return json({ deliveries: await Promise.all(results.map(async row => ({ delivery: deliveryValue(row), profile: revisionValue(await getRevision(db, device.account_id, row.profile_id, row.profile_revision)).profile }))) });
  }
  if (request.method === 'POST' && path.length === 5 && path[4] === 'ack') {
    const id = requireId(path[3], 'deliveryId'), value = await body(request), profileId = requireId(value.profileId, 'profileId'), revision = requireRevision(value.profileRevision);
    if (!['received', 'rendered', 'failed'].includes(value.state) || (value.error !== undefined && (typeof value.error !== 'string' || value.error.length > 500))) throw new CloudError('invalid_request', 'Provide a valid receipt state and bounded error description.');
    const row = await db.prepare('SELECT * FROM deliveries WHERE id = ? AND device_id = ? AND account_id = ?').bind(id, deviceId, device.account_id).first();
    if (!row) notFound();
    if (row.profile_id !== profileId || row.profile_revision !== revision) throw new CloudError('delivery_conflict', 'The receipt does not match this profile revision.', 409);
    if (row.state === value.state) return json({ delivery: deliveryValue(row) });
    const allowed = value.state === 'received' ? ['queued'] : value.state === 'failed' ? ['queued', 'received'] : ['received'];
    if (!allowed.includes(row.state)) throw new CloudError('delivery_conflict', 'This delivery cannot advance from its current state.', 409);
    const updated = await db.prepare('UPDATE deliveries SET state = ?,error = ?,updated_at = ? WHERE id = ? AND state = ? AND EXISTS(SELECT 1 FROM devices WHERE id = ? AND revoked_at IS NULL AND token_expires_at > ?) RETURNING *').bind(value.state, value.state === 'failed' ? (value.error || 'The phone could not render this profile.') : null, new Date().toISOString(), id, row.state, deviceId, new Date().toISOString()).first();
    if (!updated) {
      const current = await db.prepare('SELECT * FROM deliveries WHERE id = ? AND device_id = ?').bind(id, deviceId).first();
      if (current?.state === value.state) return json({ delivery: deliveryValue(current) });
      throw new CloudError('delivery_conflict', 'This delivery changed. Refresh its status.', 409);
    }
    return json({ delivery: deliveryValue(updated) });
  }
  notFound();
}
export async function handleApi(request, env) {
  try {
    const path = new URL(request.url).pathname.split('/').filter(Boolean);
    if (path[0] !== 'v1') notFound(); path.shift();
    if (request.method === 'GET' && path.length === 1 && path[0] === 'config') return json(getPublicConfig(request, env));
    if (!env.DB) throw new CloudError('not_configured', 'Cloud storage is not configured.', 503);
    if (path[0] === 'devices' && path[2] === 'deliveries') return await deviceRoute(request, env, path);
    return await accountRoute(request, env, path);
  } catch (error) { return errorResponse(error); }
}
