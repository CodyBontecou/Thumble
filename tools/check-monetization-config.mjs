import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { PLAN_IDS } from '../apps/entitlements/src/grants.js';

export function validateMonetization(config, app) {
  const errors = [];
  const keys = ['weekly', 'yearly', 'lifetime', 'familyWeekly', 'familyYearly', 'familyLifetime'];
  const products = Object.fromEntries(keys.map(key => [key, key === 'lifetime' ? 'thumble_pro_lifetime' : `thumble_${key.replace(/[A-Z]/g, letter => '_' + letter.toLowerCase())}`]));
  if (config.productId !== 'thumble_pro_lifetime' || config.trialDays !== 7 ||
      keys.some(key => !PLAN_IDS.includes(config.products?.[key]) || config.products?.[key] !== products[key]) || new Set(Object.values(config.products ?? {})).size !== keys.length ||
      config.products?.lifetime !== config.productId) errors.push('Configure all six distinct plan products, the existing lifetime entitlement and the 7-day trial.');
  if (keys.some(key => !Number.isFinite(config.listPricesUSD?.[key]) || config.listPricesUSD[key] <= 0)) errors.push('Configure positive US list prices for every plan; actual purchase prices come from the store.');
  if (!/^[A-Za-z0-9+/]{43}=$/.test(config.entitlementPublicKey) || Buffer.from(config.entitlementPublicKey, 'base64').length !== 32) errors.push('Set the raw 32-byte Ed25519 entitlement public key.');
  for (const key of ['entitlementServiceURL', 'privacyURL', 'termsURL', 'supportURL']) {
    try { const url = new URL(config[key]); if (url.protocol !== 'https:' || url.username || url.password) throw Error(); }
    catch { errors.push(`Set a valid HTTPS ${key}.`); }
  }
  if (app.name !== 'Thumble' || app.ios.bundleIdentifier !== 'com.thumble.ios' || app.android.package !== 'com.thumble.android') errors.push('App name and production identifiers must match the Thumble store registrations.');
  return errors;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const config = JSON.parse(await readFile(new URL('../config/monetization.json', import.meta.url)));
  const app = JSON.parse(await readFile(new URL('../apps/mobile/app.json', import.meta.url))).expo;
  const errors = validateMonetization(config, app);
  if (errors.length) { console.error(errors.join('\n')); process.exitCode = 1; }
  else console.log('Local monetization configuration is complete. Store prices/products and live verification still need store testing.');
}
