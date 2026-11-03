import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import { PLAN_IDS, createGrant } from './grants.js';
import { appleVerifier, googleVerifier } from './stores.js';

// Place behind HTTPS and a rate-limiting reverse proxy. Never log purchase proofs.
export function handler({ verifyApple, verifyGoogle, privateKey }) {
  return async (request, response) => {
    response.setHeader('Cache-Control', 'no-store');
    response.setHeader('Content-Type', 'application/json');
    if (request.method !== 'POST' || request.url !== '/v1/grants') { response.writeHead(404).end('{}'); return; }
    try {
      let length = 0, chunks = [];
      for await (const chunk of request) {
        length += chunk.length; if (length > 32768) { response.writeHead(413).end('{}'); return; } chunks.push(chunk);
      }
      const { platform, proof, receiverId, nonce, phoneId, productId = 'thumble_pro_lifetime' } = JSON.parse(Buffer.concat(chunks).toString());
      if (!PLAN_IDS.includes(productId) || typeof proof !== 'string' || proof.length < 8 || proof.length > 24000 || !/^[a-f0-9-]{36}$/i.test(receiverId) || !/^[a-f0-9-]{36}$/i.test(nonce) || !/^[a-f0-9-]{36}$/i.test(phoneId)) throw Error('Invalid request');
      const verify = platform === 'ios' ? verifyApple : platform === 'android' ? verifyGoogle : null;
      if (!verify) { response.writeHead(503).end(JSON.stringify({ error: 'This store is not configured yet.' })); return; }
      const result = await verify(proof, productId);
      const { pro, until } = typeof result === 'boolean' ? { pro: result, until: null } : result;
      const grant = createGrant({ receiverId, nonce, phoneId, pro, until }, privateKey);
      response.writeHead(200).end(JSON.stringify(grant));
    } catch { response.writeHead(422).end(JSON.stringify({ error: 'Purchase verification failed. Retry Restore Purchases.' })); }
  };
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const env = process.env;
  const privateKey = await readFile(env.TAPPING_GRANT_PRIVATE_KEY_FILE, 'utf8');
  const verifyApple = env.APPLE_BUNDLE_ID ? await appleVerifier(env) : null;
  const verifyGoogle = env.GOOGLE_PACKAGE_NAME ? googleVerifier({ packageName: env.GOOGLE_PACKAGE_NAME, credentials: JSON.parse(await readFile(env.GOOGLE_APPLICATION_CREDENTIALS, 'utf8')) }) : null;
  if (!verifyApple && !verifyGoogle) throw Error('Configure at least one native store');
  const server = createServer(handler({ verifyApple, verifyGoogle, privateKey }));
  server.requestTimeout = 30000; server.headersTimeout = 10000;
  server.listen(Number(env.PORT ?? 8788), '127.0.0.1');
}
