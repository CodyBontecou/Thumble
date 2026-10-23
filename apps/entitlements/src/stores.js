import { readFile } from 'node:fs/promises';
import { createSign } from 'node:crypto';
import { PRODUCT_ID } from './grants.js';

export function googleVerifier({ packageName, credentials, fetcher = fetch }) {
  let cachedToken, tokenDeadline = 0;
  return async token => {
    const now = Math.floor(Date.now() / 1000);
    if (!cachedToken || tokenDeadline <= now + 60) {
      const header = Buffer.from(JSON.stringify({ alg: 'RS256', typ: 'JWT' })).toString('base64url');
      const claims = Buffer.from(JSON.stringify({ iss: credentials.client_email, scope: 'https://www.googleapis.com/auth/androidpublisher', aud: 'https://oauth2.googleapis.com/token', iat: now, exp: now + 3600 })).toString('base64url');
      const input = `${header}.${claims}`;
      const signature = createSign('RSA-SHA256').update(input).sign(credentials.private_key, 'base64url');
      const response = await fetcher('https://oauth2.googleapis.com/token', { method: 'POST', body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: `${input}.${signature}` }), signal: AbortSignal.timeout(10000) });
      if (!response.ok) throw Error('Google authorization unavailable');
      const value = await response.json();
      if (typeof value.access_token !== 'string') throw Error('Invalid Google authorization');
      cachedToken = value.access_token; tokenDeadline = now + Math.min(3600, value.expires_in ?? 3600);
    }
    const base = `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${encodeURIComponent(packageName)}/purchases/products/${PRODUCT_ID}/tokens/${encodeURIComponent(token)}`;
    const headers = { Authorization: `Bearer ${cachedToken}` };
    const response = await fetcher(base, { headers, signal: AbortSignal.timeout(10000) });
    if (!response.ok) throw Error('Purchase could not be verified');
    const value = await response.json();
    if (value.purchaseState === 1) return false; // Google confirmed cancellation/refund.
    if (value.purchaseState !== 0 || value.consumptionState !== 0) throw Error('Purchase is pending or invalid');
    if (value.acknowledgementState === 0) {
      const ack = await fetcher(`${base}:acknowledge`, { method: 'POST', headers: { ...headers, 'Content-Type': 'application/json' }, body: '{}', signal: AbortSignal.timeout(10000) });
      if (!ack.ok) throw Error('Purchase acknowledgement failed; retry restore');
    }
    return true;
  };
}
export async function appleVerifier(env) {
  const { AppStoreServerAPIClient, SignedDataVerifier, Environment } = await import('@apple/app-store-server-library');
  const environment = env.APPLE_ENVIRONMENT === 'Sandbox' ? Environment.SANDBOX : Environment.PRODUCTION;
  const roots = await Promise.all(env.APPLE_ROOT_CERTIFICATES.split(',').map(path => readFile(path.trim())));
  const verifier = new SignedDataVerifier(roots, true, environment, env.APPLE_BUNDLE_ID, environment === Environment.PRODUCTION ? Number(env.APPLE_APP_ID) : undefined);
  const client = new AppStoreServerAPIClient(await readFile(env.APPLE_PRIVATE_KEY_FILE, 'utf8'), env.APPLE_KEY_ID, env.APPLE_ISSUER_ID, env.APPLE_BUNDLE_ID, environment);
  return async proof => {
    // Verify the caller's JWS before using its transaction ID in a store request.
    const transaction = await verifier.verifyAndDecodeTransaction(proof);
    if (transaction.productId !== PRODUCT_ID || !transaction.transactionId) throw Error('Wrong product');
    const latest = await client.getTransactionInfo(transaction.transactionId);
    const current = await verifier.verifyAndDecodeTransaction(latest.signedTransactionInfo);
    if (current.productId !== PRODUCT_ID || current.type !== 'Non-Consumable') throw Error('Wrong product type');
    return !current.revocationDate;
  };
}
