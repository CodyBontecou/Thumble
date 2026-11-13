import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { validateMonetization } from '../check-monetization-config.mjs';
const config = JSON.parse(readFileSync(new URL('../../config/monetization.json',import.meta.url)));
const app = JSON.parse(readFileSync(new URL('../../apps/mobile/app.json',import.meta.url))).expo;
test('current plan configuration passes without demo-era prices or allowance', () => {
  const plansOnly = structuredClone(config); delete plansOnly.demoSeconds;
  assert.deepEqual(validateMonetization(plansOnly,app),[]);
});
test('release config rejects missing plans, duplicate IDs, invalid prices and insecure verification', () => {
  for (const mutate of [c=>{delete c.products.weekly;},c=>{c.products.yearly=c.products.weekly;},c=>{[c.products.weekly,c.products.yearly]=[c.products.yearly,c.products.weekly];},c=>{c.listPricesUSD.lifetime=0;},c=>{c.entitlementServiceURL='http://localhost';},c=>{c.entitlementPublicKey='bad';}]) {
    const candidate = structuredClone(config); mutate(candidate);
    assert(validateMonetization(candidate,app).length);
  }
});
