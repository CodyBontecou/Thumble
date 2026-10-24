import { readFile } from 'node:fs/promises';
const config = JSON.parse(await readFile(new URL('../config/monetization.json', import.meta.url)));
const app = JSON.parse(await readFile(new URL('../apps/mobile/app.json', import.meta.url))).expo;
const errors = [];
if (config.productId !== 'thumble_pro_lifetime' || config.demoSeconds !== 1800 || config.basePriceUSD !== 19.99) errors.push('Product, demo allowance or US base price differs from the implementation.');
if (!/^[A-Za-z0-9+/]{43}=$/.test(config.entitlementPublicKey) || Buffer.from(config.entitlementPublicKey, 'base64').length !== 32) errors.push('Set the raw 32-byte Ed25519 entitlement public key.');
for (const key of ['entitlementServiceURL', 'privacyURL', 'termsURL', 'supportURL']) {
  try { const url = new URL(config[key]); if (url.protocol !== 'https:' || url.username || url.password) throw Error(); }
  catch { errors.push(`Set a valid HTTPS ${key}.`); }
}
if (app.name !== 'Thumble' || app.ios.bundleIdentifier !== 'com.thumble.ios' || app.android.package !== 'com.thumble.android') errors.push('App name and production identifiers must match the Thumble store registrations.');
if (errors.length) { console.error(errors.join('\n')); process.exitCode = 1; }
else console.log('Local monetization configuration is complete. Store prices/products and live verification still need store testing.');
