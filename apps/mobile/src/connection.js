import { AppState, PermissionsAndroid, Platform } from 'react-native';
import * as SecureStore from 'expo-secure-store';
import native from '../modules/tapping-link';
import { purchases } from './purchases/store';
import { Connection } from './connection-core';

export const connection = new Connection(native, { beforeConnect: async () => {
  if (Platform.OS === 'android' && Number(Platform.Version) >= 37) {
    const result = await PermissionsAndroid.request(PermissionsAndroid.PERMISSIONS.ACCESS_LOCAL_NETWORK);
    if (result !== PermissionsAndroid.RESULTS.GRANTED) throw new Error('Allow local network access to connect to your computer.');
  }
  connection.phoneId = await purchases.installationId();
  if (AppState.currentState !== 'active') throw new Error('Open Thumble before connecting to your computer.');
} });
const pairingKey = 'thumble.receiver.reconnect.v1';
const secureOptions = { keychainAccessible: SecureStore.WHEN_UNLOCKED_THIS_DEVICE_ONLY };
connection.pairingStorage = {
  async load() {
    const value = await SecureStore.getItemAsync(pairingKey, secureOptions);
    try { return value ? JSON.parse(value) : null; } catch { return null; }
  },
  async save(value) {
    if (value) await SecureStore.setItemAsync(pairingKey, JSON.stringify(value), secureOptions);
    else await SecureStore.deleteItemAsync(pairingKey, secureOptions);
  },
};
let retry = null, delay = 500;
function restoreConnection() {
  if (AppState.currentState !== 'active' || retry || connection.snapshot().phase !== 'offline') return;
  retry = setTimeout(() => {
    retry = null;
    if (AppState.currentState === 'active') void connection.reconnect().catch(() => {});
  }, delay);
  delay = Math.min(delay * 2, 10000);
}
connection.subscribe(() => {
  if (connection.snapshot().phase === 'connected') delay = 500;
  else if (connection.snapshot().phase === 'offline' && connection.remembered) restoreConnection();
});
AppState.addEventListener('change', phase => {
  if (phase === 'background') {
    if (retry) { clearTimeout(retry); retry = null; }
    connection.suspend();
  } else if (phase === 'active') { delay = 500; restoreConnection(); }
});
restoreConnection();

purchases.initialize(connection);
let lastPairing = '';
connection.subscribeAccess(() => {
  const access = connection.accessSnapshot();
  if (!access) { lastPairing = ''; return; }
  const pairing = `${access.receiverId}:${access.nonce}`;
  if (lastPairing !== pairing) {
    lastPairing = pairing;
    void purchases.verifyOnMac().catch(() => {});
  }
});
