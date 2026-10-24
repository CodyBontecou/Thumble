import { AppState, Platform } from 'react-native';
import * as AuthSession from 'expo-auth-session';
import * as SecureStore from 'expo-secure-store';
import * as Crypto from 'expo-crypto';
import * as WebBrowser from 'expo-web-browser';
import { validServiceUrl } from '@tapping/cloud-contracts';
import { validViewport } from '@tapping/controller';
import { CloudController } from './core';
import { authorizationConfig, codeExchangeConfig, refreshConfig, tokenFields, validateCloudConfig } from './oauth';
import { connection } from '../connection';
import { CLOUD_REDIRECT_PATH, CLOUD_REDIRECT_URI } from './redirect';
import { accountDeletionUrl, ACCOUNT_RETURN_URI } from './account';

WebBrowser.maybeCompleteAuthSession();
const pointer = 'thumble.cloud.v1';
const secureOptions = { keychainAccessible: SecureStore.WHEN_UNLOCKED_THIS_DEVICE_ONLY };
async function eraseRecord(key) {
  const count = Number(await SecureStore.getItemAsync(key, secureOptions));
  if (Number.isSafeInteger(count) && count > 0 && count < 2000) {
    for (let index = 0; index < count; index++) await SecureStore.deleteItemAsync(`${key}.${index}`, secureOptions);
  }
  await SecureStore.deleteItemAsync(key, secureOptions);
}
// Small encrypted chunks work on platforms with limited per-item keychain sizes.
const storage = {
  async load() {
    const key = await SecureStore.getItemAsync(pointer, secureOptions);
    if (!key) return null;
    const count = Number(await SecureStore.getItemAsync(key, secureOptions));
    if (!Number.isSafeInteger(count) || count < 1 || count > 2000) throw Error('Invalid saved cloud record.');
    const parts = [];
    for (let index = 0; index < count; index++) {
      const part = await SecureStore.getItemAsync(`${key}.${index}`, secureOptions);
      if (part == null) throw Error('Incomplete saved cloud record.');
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
    const scope = await Crypto.digestStringAsync(Crypto.CryptoDigestAlgorithm.SHA256, `${value.session.service}\n${value.session.accountId}`);
    const key = `thumble.cloud.${scope}.${Crypto.randomUUID()}`;
    const chars = Array.from(JSON.stringify(value));
    const parts = [];
    for (let index = 0; index < chars.length; index += 350) parts.push(chars.slice(index, index + 350).join(''));
    try {
      await SecureStore.setItemAsync(key, String(parts.length), secureOptions);
      for (let index = 0; index < parts.length; index++) await SecureStore.setItemAsync(`${key}.${index}`, parts[index], secureOptions);
      await SecureStore.setItemAsync(pointer, key, secureOptions);
    } catch (failure) { await eraseRecord(key).catch(() => {}); throw failure; }
    if (previous) await eraseRecord(previous);
  },
};
export const cloud = new CloudController({ storage, allowLocalhost: __DEV__, refreshToken: async session => {
  const result = await AuthSession.refreshAsync(refreshConfig(session), session.auth);
  return tokenFields(result, session);
} });

export const cloudRedirectUri = AuthSession.makeRedirectUri({ native: CLOUD_REDIRECT_URI, scheme: 'thumble', path: CLOUD_REDIRECT_PATH });
let signingIn = false;
export async function signInCloud(service) {
  if (signingIn) return false;
  if (!validServiceUrl(service, __DEV__)) throw Error('Enter an HTTPS cloud service URL.');
  if (!validViewport(cloud.viewport)) throw Error('Turn your phone sideways once to measure the controller area, then connect your account.');
  signingIn = true;
  try {
    const response = await fetch(`${service.replace(/\/$/, '')}/v1/config`);
    const config = await response.json();
    if (!response.ok) throw Error(config.error?.message || 'This service is not ready for sign-in.');
    const auth = validateCloudConfig(config, service, __DEV__);
    const request = new AuthSession.AuthRequest(authorizationConfig(auth, cloudRedirectUri));
    await request.makeAuthUrlAsync(auth);
    const result = await request.promptAsync(auth);
    if (result.type === 'cancel' || result.type === 'dismiss') return false;
    if (result.type !== 'success' || !result.params.code || !request.codeVerifier) throw Error('Sign-in did not finish. Try again.');
    const tokens = await AuthSession.exchangeCodeAsync(codeExchangeConfig(auth, cloudRedirectUri, result.params.code, request.codeVerifier, result.params.iss), auth);
    await cloud.connect(service, { ...tokenFields(tokens), auth, mcpUrl: config.mcpUrl }, { name: Platform.OS === 'ios' ? 'My iPhone' : 'My Android phone', platform: Platform.OS, viewport: { ...cloud.viewport } });
    return true;
  } finally { signingIn = false; }
}

export async function checkAccountDeletion() {
  const before = cloud.snapshot().session;
  try { return await cloud.verifyAccountDeletion(); }
  catch (failure) {
    if (before && cloud.snapshot().session === before) cloud.update({ error: `Could not confirm account deletion: ${failure.message}` });
    return false;
  }
}
export async function manageCloudAccount() {
  const session = await cloud.accountSession();
  if (!session) return;
  const url = accountDeletionUrl(session);
  await WebBrowser.openAuthSessionAsync(url, ACCOUNT_RETURN_URI);
  // A callback URL or browser dismissal is never proof of deletion. The
  // resource server must explicitly reject this account as account_deleted.
  await checkAccountDeletion();
}

let timer = null;
function environment() {
  cloud.setEnvironment({ foreground: AppState.currentState === 'active', lanOffline: connection.snapshot().phase === 'offline' });
  if (timer) { clearInterval(timer); timer = null; }
  if (cloud.snapshot().foreground && cloud.snapshot().session) {
    void cloud.poll();
    timer = setInterval(() => { void cloud.poll(); }, 3000);
  }
}
AppState.addEventListener('change', environment);
connection.subscribe(() => cloud.setEnvironment({ lanOffline: connection.snapshot().phase === 'offline' }));
let sessionKey = '';
cloud.subscribe(() => {
  const nextKey = cloud.snapshot().session?.device.id || '';
  if (sessionKey !== nextKey) { sessionKey = nextKey; environment(); }
});
void cloud.load().then(environment);
