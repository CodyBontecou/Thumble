export function createPurchaseStore(native, config, fetcher = fetch) {
  let state = { busy: false, status: 'unknown', price: '', error: '', proof: '', platform: '' };
  const listeners = new Set();
  let refreshing = null;
  let connector = null;
  let generation = 0;
  function update(value) { state = { ...state, ...value }; for (const listener of listeners) listener(); }
  const purchases = {
    subscribe: listener => { listeners.add(listener); return () => listeners.delete(listener); },
    snapshot: () => state,
    attach(connection) { connector = connection; },
    async refresh() {
      if (refreshing || state.busy) return refreshing;
      const started = generation;
      refreshing = Promise.resolve().then(async () => {
        try {
          if (!native) throw Error('Install the updated app to enable native purchases.');
          const value = await native.status();
          if (started !== generation) return;
          update({ ...value, error: '' });
          await purchases.verifyOnMac();
        } catch (error) { update({ error: error.message }); }
      }).finally(() => { refreshing = null; });
      return refreshing;
    },
    async act(action) {
      if (state.busy) return;
      ++generation;
      update({ busy: true, error: '' });
      try {
        if (!native) throw Error('Install the updated app to enable native purchases.');
        const value = await native[action]();
        if (value.status === 'cancelled') { update({ error: '' }); return; }
        update(value);
        if (value.status === 'pending') update({ error: 'Awaiting store approval. Pro will unlock after payment is confirmed.' });
        else if (value.status === 'free' && !value.proof) update({ error: 'No Pro purchase was found for this store account.' });
        else await purchases.verifyOnMac();
      } catch (error) { update({ error: error.message }); }
      finally { update({ busy: false }); }
    },
    async verifyOnMac() {
      const access = connector?.accessSnapshot();
      if (!access || !state.proof) return;
      if (!config.entitlementServiceURL) throw Error('Purchase verification is not configured yet. Your store purchase can be restored later.');
      if (!config.entitlementServiceURL.startsWith('https://')) throw Error('Purchase verification requires a secure service.');
      const receiverId = access.receiverId, nonce = access.nonce, proof = state.proof;
      const response = await fetcher(`${config.entitlementServiceURL.replace(/\/$/, '')}/v1/grants`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ platform: state.platform, proof: state.proof, receiverId, nonce, phoneId: connector.phoneId }), signal: AbortSignal.timeout(15000),
      });
      if (!response.ok) throw Error('Your purchase could not be verified. Retry Restore Purchases.');
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
