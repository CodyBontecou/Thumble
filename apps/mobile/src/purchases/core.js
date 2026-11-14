// Hard paywall: weekly/yearly subscriptions with a store-run 7-day trial, plus
// Lifetime. Apple also offers Family variants; Google Play has none. Prices
// always come from the store catalog. An unavailable catalog shows no prices.
export const PLAN_KEYS = ['yearly', 'weekly', 'lifetime'];
const STATUSES = ['active', 'expired', 'billing', 'pending', 'free'];

/** Store-neutral view of the plans for one audience. */
export function planOptions({ catalog = [], config, audience = 'individual', platform = 'ios' }) {
  const family = audience === 'family' && platform === 'ios';
  const keyFor = plan => family ? `family${plan[0].toUpperCase()}${plan.slice(1)}` : plan;
  const byId = new Map(catalog.map(item => [item.id, item]));
  const weekly = byId.get(config.products[keyFor('weekly')]);
  const options = PLAN_KEYS.map(plan => {
    const key = keyFor(plan), id = config.products[key], item = byId.get(id);
    return {
      plan, id, family, available: !!item?.price,
      price: item?.price || '',
      amount: Number.isFinite(item?.amount) ? item.amount : null,
      currency: item?.currency || '',
      trial: plan !== 'lifetime' && !!item?.price && item.trialEligible === true,
      trialDays: item?.trialDays || config.trialDays || 7,
      perWeek: '', save: '',
    };
  });
  const yearly = options[0], weeklyAmount = weekly?.amount;
  if (yearly.available && weekly?.price && yearly.currency && yearly.currency === weekly.currency && Number.isFinite(yearly.amount) && Number.isFinite(weeklyAmount) && weeklyAmount > 0) {
    yearly.perWeek = formatAmount(yearly.amount / 52, yearly.currency);
    const save = Math.round((1 - yearly.amount / (weeklyAmount * 52)) * 100);
    if (save > 0) yearly.save = `SAVE ${save}%`;
  }
  return options;
}
function formatAmount(value, currency) {
  try { return new Intl.NumberFormat(undefined, { style: 'currency', currency, currencyDisplay: 'code' }).format(value); }
  catch { return ''; }
}
export const familyAvailable = platform => platform === 'ios';

/** What the root gate shows. Development builds without store access may pass. */
export function accessGate(state, { allowUnconfigured = false } = {}) {
  if (state.status === 'active') return 'open';
  if (!state.loaded) return 'loading';
  if (allowUnconfigured && (state.unavailable || state.devBypass)) return 'open';
  if (state.status === 'expired' || state.status === 'billing') return 'expired';
  return 'paywall';
}

export function createPurchaseStore(native, config, fetcher = fetch) {
  let state = { loaded: false, busy: false, status: 'unknown', productId: '', proof: '', platform: '', expiresAt: null, inTrial: false, willRenew: false, catalog: [], error: '', unavailable: !native };
  const listeners = new Set();
  let refreshing = null;
  let connector = null;
  let generation = 0;
  function update(value) { state = { ...state, ...value }; for (const listener of listeners) listener(); }
  function entitlement(value) {
    const status = STATUSES.includes(value.status) ? value.status : value.status === 'owned' ? 'active' : 'free';
    return {
      status, platform: value.platform || state.platform,
      productId: typeof value.productId === 'string' ? value.productId : '',
      expiresAt: Number.isFinite(value.expiresAt) ? value.expiresAt : null,
      inTrial: value.inTrial === true, willRenew: value.willRenew === true,
      ...(typeof value.proof === 'string' && value.proof ? { proof: value.proof } : {}),
    };
  }
  const ids = () => Object.values(config.products ?? { lifetime: config.productId });
  const purchases = {
    subscribe: listener => { listeners.add(listener); return () => listeners.delete(listener); },
    snapshot: () => state,
    attach(connection) { connector = connection; },
    async refresh() {
      if (refreshing || state.busy) return refreshing;
      const started = generation;
      refreshing = Promise.resolve().then(async () => {
        try {
          if (!native) throw Error('Install the updated app to enable purchases.');
          const [value, catalog] = await Promise.all([native.status(), native.catalog ? native.catalog(ids()).catch(() => null) : null]);
          if (started !== generation) return;
          update({ ...entitlement(value), catalog: Array.isArray(catalog) ? catalog : [], loaded: true, error: '', unavailable: !Array.isArray(catalog) || catalog.length === 0 });
          await purchases.verifyOnMac();
        } catch (error) { update({ loaded: true, catalog: [], unavailable: true, error: error.message }); }
      }).finally(() => { refreshing = null; });
      return refreshing;
    },
    async act(action, productId = '') {
      if (state.busy) return;
      ++generation;
      update({ busy: true, error: '' });
      try {
        if (!native) throw Error('Install the updated app to enable purchases.');
        const value = action === 'purchase' ? await native.purchase(productId) : await native[action]();
        if (value.status === 'cancelled') { update({ error: '' }); return; }
        update({ ...entitlement(value), loaded: true });
        if (value.status === 'pending') update({ error: 'Waiting for store approval. Your plan unlocks once payment is confirmed.' });
        else if (action === 'restore' && state.status !== 'active') update({ error: 'No active plan was found for this store account.' });
        else await purchases.verifyOnMac();
      } catch (error) { update({ error: error.message }); }
      finally { update({ busy: false }); }
    },
    buy: productId => purchases.act('purchase', productId),
    restore: () => purchases.act('restore'),
    // Development builds only: continue without a plan for simulator testing.
    bypass: () => update({ devBypass: true }),
    async verifyOnMac() {
      const access = connector?.accessSnapshot();
      if (!access || !state.proof) return;
      if (!config.entitlementServiceURL) throw Error('Purchase verification is not configured yet. Your store purchase can be restored later.');
      if (!config.entitlementServiceURL.startsWith('https://')) throw Error('Purchase verification requires a secure service.');
      const receiverId = access.receiverId, nonce = access.nonce, proof = state.proof;
      const response = await fetcher(`${config.entitlementServiceURL.replace(/\/$/, '')}/v1/grants`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ platform: state.platform, productId: state.productId || config.productId, proof: state.proof, receiverId, nonce, phoneId: connector.phoneId }), signal: AbortSignal.timeout(15000),
      });
      if (!response.ok) throw Error('Your plan could not be verified. Retry Restore Purchases.');
      const grant = await response.json();
      // Ignore a response for an old pairing, even when the new Computer has the same name.
      const current = connector?.accessSnapshot();
      if (state.proof !== proof || current?.receiverId !== receiverId || current?.nonce !== nonce) return;
      connector.sendGrant(grant);
    },
    async installationId() { if (!native) throw Error("Install the updated native app before pairing."); return await native.installationId(); },
    async demoUsed() { return native ? await native.demoUsed() : 0; },
    async rememberDemo(used) { if (native) await native.saveDemoUsed(used); },
    configured: () => !!native && config.entitlementServiceURL.startsWith('https://') && !!config.entitlementPublicKey,
  };

  return purchases;
}
