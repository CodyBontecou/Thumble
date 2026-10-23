import { Stack, router } from 'expo-router';
import { Pressable, Text } from 'react-native';
import { colors } from '../ui/design';
export const unstable_settings = { anchor: 'index' };
function Done() { return <Pressable accessibilityRole="button" hitSlop={8} style={{ minHeight: 44, justifyContent: 'center' }} onPress={() => router.canGoBack() ? router.back() : router.replace('/')}><Text style={{ color: colors.text, fontSize: 16, fontWeight: '500' }}>Done</Text></Pressable>; }
const modal = { presentation: /** @type {const} */ ('modal'), headerShown: true, headerStyle: { backgroundColor: colors.background }, headerTintColor: colors.text, headerShadowVisible: false, headerBackVisible: false, headerRight: Done };
export default function RootLayout() {
  return <Stack screenOptions={{ headerShown: false, contentStyle: { backgroundColor: colors.background } }}>
    <Stack.Screen name="index" options={{ gestureEnabled: false, fullScreenGestureEnabled: false }} />
    <Stack.Screen name="onboarding" options={{ animation: 'fade' }} />
    <Stack.Screen name="controller-menu" options={{ presentation: 'transparentModal', animation: 'fade', contentStyle: { backgroundColor: 'transparent' } }} />
    <Stack.Screen name="calibration" options={{ ...modal, title: 'Stick calibration' }} />
    <Stack.Screen name="pro" options={{ ...modal, title: 'Thumble Pro' }} />
    <Stack.Screen name="profiles" options={{ ...modal, title: 'Profiles' }} />
    <Stack.Screen name="pair" options={{ ...modal, title: 'Connect Mac' }} />
    <Stack.Screen name="wow-setup" options={{ ...modal, title: 'WoW setup' }} />
  </Stack>;
}
