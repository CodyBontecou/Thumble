import { Stack, router } from 'expo-router';
import { useSyncExternalStore } from 'react';
import { Pressable, Text } from 'react-native';
import { connection } from '../connection';
import { cloud } from '../cloud/store';
import { colors } from '../ui/design';
export const unstable_settings = { anchor: 'index' };
function Done() { return <Pressable accessibilityRole="button" hitSlop={8} style={{ minHeight: 44, justifyContent: 'center' }} onPress={() => router.canGoBack() ? router.back() : router.replace('/')}><Text style={{ color: colors.text, fontSize: 16, fontWeight: '500' }}>Done</Text></Pressable>; }
const modal = { presentation: /** @type {const} */ ('modal'), headerShown: true, headerStyle: { backgroundColor: colors.background }, headerTintColor: colors.text, headerShadowVisible: false, headerBackVisible: false, headerRight: Done };
export default function RootLayout() {
  const network = useSyncExternalStore(connection.subscribe, connection.snapshot);
  const cloudState = useSyncExternalStore(cloud.subscribe, cloud.snapshot);
  // Explicit defaults let setup and settings rotate even while the connected
  // controller remains mounted underneath. The native stack applies the lock
  // only when the controller route is visible and restores it on return.
  return <Stack screenOptions={{ orientation: 'default', headerShown: false, contentStyle: { backgroundColor: colors.background } }}>
    <Stack.Screen name="index" options={{ orientation: network.phase === 'connected' || cloudState.selected ? 'landscape' : 'default', gestureEnabled: false, fullScreenGestureEnabled: false }} />
    <Stack.Screen name="welcome" options={{ animation: 'fade' }} />
    <Stack.Screen name="onboarding" options={{ animation: 'fade' }} />
    <Stack.Screen name="journey" options={{ ...modal, title: 'AI to WoW' }} />
    <Stack.Screen name="controller-menu" options={{ presentation: 'transparentModal', animation: 'fade', contentStyle: { backgroundColor: 'transparent' } }} />
    <Stack.Screen name="setup-test" options={{ ...modal, title: 'Test controls' }} />
    <Stack.Screen name="agent-setup" options={{ ...modal, title: 'Connect your AI' }} />
    <Stack.Screen name="first-layout" options={{ ...modal, title: 'Your first layout' }} />
    <Stack.Screen name="calibration" options={{ ...modal, title: 'Stick calibration' }} />
    <Stack.Screen name="pro" options={{ ...modal, title: 'Thumble Pro' }} />
    <Stack.Screen name="cloud" options={{ ...modal, title: 'Cloud controllers' }} />
    <Stack.Screen name="profiles" options={{ ...modal, title: 'Profiles' }} />
    <Stack.Screen name="pair" options={{ ...modal, title: 'Connect Mac' }} />
    <Stack.Screen name="wow-setup" options={{ ...modal, title: 'WoW setup' }} />
  </Stack>;
}
