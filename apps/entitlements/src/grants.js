import { sign, createPrivateKey } from 'node:crypto';
import { Buffer } from 'node:buffer';
// The grant schema's entitlement name, recognized by every receiver. It stays
// the same for every plan; plan expiry is carried by expiresAt.
export const PRODUCT_ID = 'thumble_pro_lifetime';
export const LIFETIME_IDS = ['thumble_pro_lifetime', 'thumble_family_lifetime'];
export const SUBSCRIPTION_IDS = ['thumble_weekly', 'thumble_yearly', 'thumble_family_weekly', 'thumble_family_yearly'];
export const PLAN_IDS = [...LIFETIME_IDS, ...SUBSCRIPTION_IDS];
export function createGrant({ receiverId, nonce, phoneId, pro, until = null }, privateKey, now = Date.now() / 1000) {
  if (!/^[a-f0-9-]{36}$/i.test(receiverId) || !/^[a-f0-9-]{36}$/i.test(nonce) || !/^[a-f0-9-]{36}$/i.test(phoneId) || typeof pro !== 'boolean') throw Error('Invalid receiver challenge');
  const payload = Buffer.from(JSON.stringify({ v: 1, productId: PRODUCT_ID, receiverId, nonce, phoneId, pro, issuedAt: now, expiresAt: Number.isFinite(until) && until > now ? Math.min(until, now + 7 * 86400) : now + 7 * 86400 }));
  return { payload: payload.toString('base64'), signature: sign(null, payload, createPrivateKey(privateKey)).toString('base64') };
}
