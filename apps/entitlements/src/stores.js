import { readFile } from 'node:fs/promises';
import { Buffer } from 'node:buffer';
import { createSign } from 'node:crypto';
import { LIFETIME_IDS, PLAN_IDS, SUBSCRIPTION_IDS } from './grants.js';

// Verifiers resolve to { pro, until } where until is a subscription's expiry in seconds.
export function googleVerifier({ packageName, credentials, fetcher = fetch, clock = () => Date.now() }) {
  let cachedToken, tokenDeadline = 0;
  return async (token, productId = 'thumble_pro_lifetime') => {
    if (!PLAN_IDS.includes(productId) || productId.startsWith('thumble_family_')) throw Error('Wrong product');
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
    const headers = { Authorization: `Bearer ${cachedToken}` };
    const app = `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${encodeURIComponent(packageName)}/purchases`;
    if (SUBSCRIPTION_IDS.includes(productId)) {
      const response = await fetcher(`${app}/subscriptionsv2/tokens/${encodeURIComponent(token)}`, { headers, signal: AbortSignal.timeout(10000) });
      if (!response.ok) throw Error('Purchase could not be verified');
      const value = await response.json();
      const item = value.lineItems?.find(line => line.productId === productId);
      if (!item) throw Error('Wrong product');
      const until = Date.parse(item.expiryTime) / 1000;
      const pro = ['SUBSCRIPTION_STATE_ACTIVE', 'SUBSCRIPTION_STATE_IN_GRACE_PERIOD'].includes(value.subscriptionState) && until * 1000 > clock();
      if (pro && value.acknowledgementState === 'ACKNOWLEDGEMENT_STATE_PENDING') {
        const ack = await fetcher(`${app}/subscriptions/${productId}/tokens/${encodeURIComponent(token)}:acknowledge`, { method: 'POST', headers: { ...headers, 'Content-Type': 'application/json' }, body: '{}', signal: AbortSignal.timeout(10000) });
        if (!ack.ok) throw Error('Purchase acknowledgement failed; retry restore');
      }
      return { pro, until: pro ? until : null };
    }
    const base = `${app}/products/${productId}/tokens/${encodeURIComponent(token)}`;
    const response = await fetcher(base, { headers, signal: AbortSignal.timeout(10000) });
    if (!response.ok) throw Error('Purchase could not be verified');
    const value = await response.json();
    if (value.purchaseState === 1) return { pro: false, until: null }; // Google confirmed cancellation/refund.
    if (value.purchaseState !== 0 || value.consumptionState !== 0) throw Error('Purchase is pending or invalid');
    if (value.acknowledgementState === 0) {
      const ack = await fetcher(`${base}:acknowledge`, { method: 'POST', headers: { ...headers, 'Content-Type': 'application/json' }, body: '{}', signal: AbortSignal.timeout(10000) });
      if (!ack.ok) throw Error('Purchase acknowledgement failed; retry restore');
    }
    return { pro: true, until: null };
  };
}
export async function appleVerifier(env) {
  const roots = await Promise.all(env.APPLE_ROOT_CERTIFICATES.split(',').map(path => readFile(path.trim())));
  return createAppleVerifier({
    environment: env.APPLE_ENVIRONMENT,
    roots,
    bundleId: env.APPLE_BUNDLE_ID,
    appId: env.APPLE_APP_ID,
    keyId: env.APPLE_KEY_ID,
    issuerId: env.APPLE_ISSUER_ID,
    signingKey: await readFile(env.APPLE_PRIVATE_KEY_FILE, 'utf8'),
    allowSandboxReview: env.APPLE_REVIEW_SANDBOX_ENABLED === 'true',
  });
}

// Accept secret bindings directly in hosted runtimes; never write keys to public assets.
export async function createAppleVerifier(config) {
  const { AppStoreServerAPIClient, SignedDataVerifier, Environment } = await import('@apple/app-store-server-library');
  if (!['Sandbox', 'Production'].includes(config.environment)) throw Error('Invalid Apple environment');
  if (!config.roots?.length || !config.signingKey || !config.keyId || !config.issuerId || !config.bundleId) throw Error('Apple verification is not configured');
  const environment = config.environment === 'Sandbox' ? Environment.SANDBOX : Environment.PRODUCTION;
  if (environment === Environment.PRODUCTION && (!Number.isSafeInteger(Number(config.appId)) || Number(config.appId) <= 0)) throw Error('Invalid Apple app ID');
  const forEnvironment = value => ({
    verifier: new SignedDataVerifier(config.roots, true, value, config.bundleId, value === Environment.PRODUCTION ? Number(config.appId) : undefined),
    client: new AppStoreServerAPIClient(config.signingKey, config.keyId, config.issuerId, config.bundleId, value),
  });
  const primary = forEnvironment(environment);
  const review = environment === Environment.PRODUCTION && config.allowSandboxReview === true ? forEnvironment(Environment.SANDBOX) : null;
  return proof => verifyAppleTransaction(proof, primary, review);
}

export async function verifyAppleTransaction(proof, primary, review = null, now = () => Date.now()) {
  const { VerificationException, VerificationStatus } = await import('@apple/app-store-server-library');
  let selected = primary, transaction;
  try {
    // Apple verifies the certificate chain, signature and bundle before environment.
    transaction = await primary.verifier.verifyAndDecodeTransaction(proof);
  } catch (error) {
    if (!review || !(error instanceof VerificationException) || error.status !== VerificationStatus.INVALID_ENVIRONMENT) throw error;
    selected = review;
    // Sandbox is an explicitly configured review path, never a signature bypass.
    transaction = await review.verifier.verifyAndDecodeTransaction(proof);
  }
  if (!PLAN_IDS.includes(transaction.productId) || !transaction.transactionId) throw Error('Wrong product');
  const latest = await selected.client.getTransactionInfo(transaction.transactionId);
  const current = await selected.verifier.verifyAndDecodeTransaction(latest.signedTransactionInfo);
  if (current.productId !== transaction.productId || current.transactionId !== transaction.transactionId) throw Error('Wrong product or transaction');
  if (LIFETIME_IDS.includes(current.productId)) {
    if (current.type !== 'Non-Consumable') throw Error('Wrong product or transaction');
    return { pro: !current.revocationDate, until: null };
  }
  if (current.type !== 'Auto-Renewable Subscription') throw Error('Wrong product or transaction');
  const until = Number(current.expiresDate) / 1000;
  const pro = !current.revocationDate && Number.isFinite(until) && until * 1000 > now();
  return { pro, until: pro ? until : null };
}
