import { generateKeyPairSync } from 'node:crypto';
import { writeFile } from 'node:fs/promises';
import { isAbsolute } from 'node:path';
const destination = process.argv[2];
if (!destination || !isAbsolute(destination)) throw Error('Pass an absolute private-key path outside source control. Existing files are never overwritten.');
const pair = generateKeyPairSync('ed25519');
await writeFile(destination, pair.privateKey.export({ type: 'pkcs8', format: 'pem' }), { mode: 0o600, flag: 'wx' });
const publicKey = pair.publicKey.export({ type: 'spki', format: 'der' }).subarray(-32).toString('base64');
console.log(`Private key saved with mode 0600. Set entitlementPublicKey to: ${publicKey}`);
