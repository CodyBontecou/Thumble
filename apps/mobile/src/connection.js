import { AppState, PermissionsAndroid, Platform } from 'react-native';
import native from '../modules/tapping-link';
import { purchases } from './purchases/store';
import { Connection } from './connection-core';

export const connection = new Connection(native, { beforeConnect: async () => {
  if (Platform.OS === 'android' && Number(Platform.Version) >= 37) {
    const result = await PermissionsAndroid.request(PermissionsAndroid.PERMISSIONS.ACCESS_LOCAL_NETWORK);
    if (result !== PermissionsAndroid.RESULTS.GRANTED) throw new Error('Allow local network access to connect to your Mac.');
  }
  connection.phoneId = await purchases.installationId();
  connection.demoUsed = await purchases.demoUsed();
  if (AppState.currentState !== 'active') throw new Error('Open Thumble before connecting to your Mac.');
} });
AppState.addEventListener('change', phase => {
  // Permission dialogs briefly make iOS inactive. The controller releases held
  // controls on inactivity; keep pairing alive until the app is backgrounded.
  if (phase === 'background' && connection.snapshot().phase !== 'offline') connection.disconnect('Practice · Mac disconnected');
});

purchases.initialize(connection);
let lastPairing = '', lastDebit = -1;
connection.subscribeAccess(() => {
  const access = connection.accessSnapshot();
  if (!access) { lastPairing = ''; return; }
  if (!access.pro && Math.floor(1800 - access.remaining) !== lastDebit) {
    lastDebit = Math.floor(1800 - access.remaining);
    // Mirror actual consumed time; pre-debit reservations are conservative on crashes.
    void purchases.rememberDemo(lastDebit).catch(() => connection.pausePlay());
  }
  const pairing = `${access.receiverId}:${access.nonce}`;
  if (lastPairing !== pairing) {
    lastPairing = pairing;
    void purchases.verifyOnMac().catch(() => {});
  }
});
