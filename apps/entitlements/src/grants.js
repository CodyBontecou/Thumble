import { sign, createPrivateKey } from 'node:crypto';
export const PRODUCT_ID = 'tapping_pro_lifetime';
export function createGrant({ receiverId, nonce, phoneId, pro }, privateKey, now = Date.now() / 1000) {
  if (!/^[a-f0-9-]{36}$/i.test(receiverId) || !/^[a-f0-9-]{36}$/i.test(nonce) || !/^[a-f0-9-]{36}$/i.test(phoneId) || typeof pro !== 'boolean') throw Error('Invalid receiver challenge');
  const payload = Buffer.from(JSON.stringify({ v: 1, productId: PRODUCT_ID, receiverId, nonce, phoneId, pro, issuedAt: now, expiresAt: now + 7 * 86400 }));
  return { payload: payload.toString('base64'), signature: sign(null, payload, createPrivateKey(privateKey)).toString('base64') };
}
