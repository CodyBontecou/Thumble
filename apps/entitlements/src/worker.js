import { createAppleVerifier, googleVerifier } from './stores.js';
import { Buffer } from 'node:buffer';
import { createPrivateKey, sign } from 'node:crypto';
import { createGrant } from './grants.js';

function json(value, status = 200) {
  return Response.json(value, { status, headers: { 'Cache-Control': 'no-store' } });
}

export function createWorker(appleFactory = createAppleVerifier) {
  const appleConfig = env => ({
    environment: env.APPLE_ENVIRONMENT,
    bundleId: env.APPLE_BUNDLE_ID, appId: env.APPLE_APP_ID,
    keyId: env.APPLE_KEY_ID, issuerId: env.APPLE_ISSUER_ID,
    signingKey: env.APPLE_PRIVATE_KEY,
    allowSandboxReview: env.APPLE_REVIEW_SANDBOX_ENABLED === 'true',
    roots: JSON.parse(env.APPLE_ROOT_CERTIFICATES_BASE64).map(value => Buffer.from(value, 'base64')),
  });
  return {
    async fetch(request, env) {
      const url = new URL(request.url);
      if (request.method === 'GET' && url.pathname === '/health') {
        try {
          await appleFactory(appleConfig(env));
          const key = createPrivateKey(env.GRANT_PRIVATE_KEY);
          if (key.asymmetricKeyType !== 'ed25519' || sign(null, Buffer.from('thumble-verifier-health'), key).length !== 64) throw Error('Invalid key');
          return json({ service: 'thumble-purchases', environment: env.APPLE_ENVIRONMENT, configured: true });
        } catch { return json({ service: 'thumble-purchases', configured: false }, 503); }
      }
      if (url.pathname !== '/v1/grants' || request.method !== 'POST') return json({}, 404);
      if (!(await env.PURCHASE_LIMITER.limit({ key: request.headers.get('CF-Connecting-IP') || 'unknown' })).success) return json({ error: 'Too many verification attempts. Try again shortly.' }, 429);
      if (!request.headers.get('content-type')?.startsWith('application/json')) return json({}, 415);
      if (Number(request.headers.get('content-length')) > 32768) return json({}, 413);
      try {
        const chunks = []; let size = 0;
        if (!request.body) return json({}, 400);
        for await (const chunk of request.body) {
          size += chunk.length;
          if (size > 32768) return json({}, 413);
          chunks.push(chunk);
        }
        const { platform, proof, receiverId, nonce, phoneId } = JSON.parse(Buffer.concat(chunks).toString());
        if (platform !== 'ios' && !(platform === 'android' && env.GOOGLE_PACKAGE_NAME && env.GOOGLE_CREDENTIALS_JSON)) return json({ error: 'This store is not configured.' }, 503);
        if (typeof proof !== 'string' || proof.length < 8 || proof.length > 24000 || ![receiverId, nonce, phoneId].every(value => typeof value === 'string' && /^[a-f0-9-]{36}$/i.test(value))) return json({}, 400);
        const verify = platform === 'ios' ? await appleFactory(appleConfig(env)) : googleVerifier({ packageName: env.GOOGLE_PACKAGE_NAME, credentials: JSON.parse(env.GOOGLE_CREDENTIALS_JSON) });
        const pro = await verify(proof);
        return json(createGrant({ receiverId, nonce, phoneId, pro }, env.GRANT_PRIVATE_KEY));
      } catch {
        // Purchase proofs and credentials must never appear in logs or error responses.
        return json({ error: 'Purchase verification failed. Retry Restore Purchases.' }, 422);
      }
    },
  };
}

export default createWorker();
