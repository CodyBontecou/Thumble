import { AppState } from 'react-native';
import { requireOptionalNativeModule } from 'expo-modules-core';
import config from '../../../../config/monetization.json';
import { createPurchaseStore } from './core';

const native = requireOptionalNativeModule('TappingPurchases');
const store = createPurchaseStore(native, config);
let initialized = false;
export const purchases = {
  ...store,
  initialize(connection) {
    store.attach(connection);
    if (initialized) return;
    initialized = true;
    native?.addListener('purchaseChanged', () => { void store.refresh(); });
    AppState.addEventListener('change', phase => { if (phase === 'active') void store.refresh(); });
    void store.refresh();
  },
};
