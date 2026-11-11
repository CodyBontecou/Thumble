import * as SecureStore from 'expo-secure-store';
import * as Crypto from 'expo-crypto';

const secureOptions = { keychainAccessible: SecureStore.WHEN_UNLOCKED_THIS_DEVICE_ONLY };
async function eraseRecord(key) {
  const count = Number(await SecureStore.getItemAsync(key, secureOptions));
  if (Number.isSafeInteger(count) && count > 0 && count < 2000) {
    for (let index = 0; index < count; index++) await SecureStore.deleteItemAsync(`${key}.${index}`, secureOptions);
  }
  await SecureStore.deleteItemAsync(key, secureOptions);
}
// Small encrypted chunks work on platforms with limited per-item keychain sizes.
/** @param {string} pointer @param {string} [recordPrefix] @param {(value: any) => Promise<string>} [scopeFor] */
export function secureRecord(pointer, recordPrefix = pointer, scopeFor = async () => '') {
  return {
    async load() {
      const key = await SecureStore.getItemAsync(pointer, secureOptions);
      if (!key) return null;
      const count = Number(await SecureStore.getItemAsync(key, secureOptions));
      if (!Number.isSafeInteger(count) || count < 1 || count > 2000) throw Error('Invalid saved record.');
      const parts = [];
      for (let index = 0; index < count; index++) {
        const part = await SecureStore.getItemAsync(`${key}.${index}`, secureOptions);
        if (part == null) throw Error('Incomplete saved record.');
        parts.push(part);
      }
      return JSON.parse(parts.join(''));
    },
    async save(value) {
      const previous = await SecureStore.getItemAsync(pointer, secureOptions);
      if (!value) {
        await SecureStore.deleteItemAsync(pointer, secureOptions);
        if (previous) await eraseRecord(previous);
        return;
      }
      const scope = await scopeFor(value);
      const key = `${recordPrefix}.${scope ? scope + '.' : ''}${Crypto.randomUUID()}`;
      const chars = Array.from(JSON.stringify(value));
      const parts = [];
      for (let index = 0; index < chars.length; index += 350) parts.push(chars.slice(index, index + 350).join(''));
      try {
        await SecureStore.setItemAsync(key, String(parts.length), secureOptions);
        for (let index = 0; index < parts.length; index++) await SecureStore.setItemAsync(`${key}.${index}`, parts[index], secureOptions);
        await SecureStore.setItemAsync(pointer, key, secureOptions);
      } catch (failure) { await eraseRecord(key).catch(() => {}); throw failure; }
      if (previous) await eraseRecord(previous).catch(() => {});
    },
  };
}
