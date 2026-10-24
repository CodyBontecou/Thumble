import { assertProfile } from '@tapping/controller';
export const API_VERSION = 1;
export const MCP_PROTOCOL_VERSION = '2025-11-25';
export const SCOPES = Object.freeze({ profileRead: 'profiles:read', profileWrite: 'profiles:write', deviceRead: 'devices:read', deviceManage: 'devices:manage', deliveryWrite: 'deliveries:write', deliveryRead: 'deliveries:read', pairingRead: 'pairing:read', pairingManage: 'pairing:manage' });
export const CLOUD_SCOPES = Object.values(SCOPES);
export const MAX_BODY_BYTES = 262144;
export const DELIVERY_STATES = ['queued', 'received', 'rendered', 'failed', 'superseded'];
export const ID_PATTERN = '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,79}$';
export const PROFILE_ID_PATTERN = '^[a-z0-9][a-z0-9-]{0,63}$';
export class CloudError extends Error {
  constructor(code, message, status = 400, details = undefined) { super(message); this.name = 'CloudError'; this.code = code; this.status = status; this.details = details; }
}
export function requireId(value, name = 'id') {
  if (typeof value !== 'string' || !new RegExp(ID_PATTERN).test(value)) throw new CloudError('invalid_request', `Invalid ${name}.`);
  return value;
}
export function requireRevision(value, allowZero = false) {
  if (!Number.isSafeInteger(value) || value < (allowZero ? 0 : 1)) throw new CloudError('invalid_request', 'Invalid revision.');
  return value;
}
export function validateCloudProfile(profile) {
  try { return assertProfile(profile); } catch (error) { throw new CloudError('invalid_profile', error.message); }
}
export function requireScope(principal, scope) {
  if (principal?.kind !== 'account' || !principal.scopes?.includes(scope)) throw new CloudError('forbidden', 'This connection does not have the required permission.', 403);
}
export function validServiceUrl(value, allowLocalhost = false) {
  try { const url = new URL(value); return !url.username && !url.password && !url.search && !url.hash && (url.protocol === 'https:' || (allowLocalhost && url.protocol === 'http:' && ['localhost', '127.0.0.1', '::1', '[::1]', '10.0.2.2'].includes(url.hostname))); } catch { return false; }
}
export function deliveryMatches(delivery, profileId, revision) {
  return delivery?.profileId === profileId && delivery.profileRevision === revision && delivery.state === 'rendered';
}
