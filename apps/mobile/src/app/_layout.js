import { AI_CONTROLLER_GENERATOR_ENABLED } from '../features';
import { Stack, router } from 'expo-router';
import { Pressable, Text, View } from 'react-native';
import { useFonts } from 'expo-font';
import { PixelifySans_500Medium, PixelifySans_700Bold } from '@expo-google-fonts/pixelify-sans';
import { Silkscreen_400Regular } from '@expo-google-fonts/silkscreen';
import { InterTight_400Regular, InterTight_500Medium, InterTight_700Bold } from '@expo-google-fonts/inter-tight';
import { colors, fonts } from '../ui/design';
export const unstable_settings = { anchor: 'index' };
function Done() { return <Pressable accessibilityRole="button" hitSlop={8} style={{ minHeight: 44, justifyContent: 'center' }} onPress={() => router.canGoBack() ? router.back() : router.replace('/')}><Text style={{ color: colors.text, fontFamily: fonts.label, fontSize: 12 }}>DONE</Text></Pressable>; }
const modal = { presentation: /** @type {const} */ ('modal'), headerShown: true, headerStyle: { backgroundColor: colors.background }, headerTintColor: colors.text, headerTitleStyle: { fontFamily: fonts.pixel, fontSize: 18, color: colors.text }, headerShadowVisible: false, headerBackVisible: false, headerRight: Done };
// Thumble-styled full screens own their safe areas and back buttons. The hard
// paywall and access screens cannot be swiped away.
const screen = { animation: /** @type {const} */ ('fade') };
const locked = { ...screen, gestureEnabled: false, fullScreenGestureEnabled: false };
export default function RootLayout() {
  const [loaded, failed] = useFonts({ PixelifySans_500Medium, PixelifySans_700Bold, Silkscreen_400Regular, InterTight_400Regular, InterTight_500Medium, InterTight_700Bold });
  // Fall back to system type rather than blocking the app if fonts fail.
  if (!loaded && !failed) return <View style={{ flex: 1, backgroundColor: colors.background }} />;
  // Explicit defaults let setup and settings rotate even while the landscape
  // controller remains mounted underneath. The native stack applies the lock
  // only when the controller route is visible and restores it on return.
  return <Stack screenOptions={{ orientation: 'default', headerShown: false, contentStyle: { backgroundColor: colors.background } }}>
    <Stack.Screen name="index" options={{ orientation: 'landscape', gestureEnabled: false, fullScreenGestureEnabled: false, contentStyle: { backgroundColor: '#17191b' } }} />
    <Stack.Screen name="welcome" options={locked} />
    <Stack.Screen name="pro" options={locked} />
    <Stack.Screen name="expired" options={locked} />
    <Stack.Screen name="connect" options={screen} />
    <Stack.Screen name="rotate" options={screen} />
    <Stack.Screen name="onboarding" options={screen} />
    <Stack.Protected guard={AI_CONTROLLER_GENERATOR_ENABLED}>
      <Stack.Screen name="journey" options={{ ...modal, title: 'AI to WoW' }} />
    </Stack.Protected>
    <Stack.Screen name="demo-info" options={{ presentation: 'transparentModal', animation: 'fade', contentStyle: { backgroundColor: 'transparent' } }} />
    <Stack.Screen name="controller-menu" options={{ presentation: 'transparentModal', animation: 'fade', contentStyle: { backgroundColor: 'transparent' } }} />
    <Stack.Screen name="setup-test" options={{ ...modal, title: 'Test controls' }} />
    <Stack.Protected guard={AI_CONTROLLER_GENERATOR_ENABLED}>
      <Stack.Screen name="agent-setup" options={{ ...modal, title: 'Connect your AI' }} />
    </Stack.Protected>
    <Stack.Screen name="first-layout" options={{ ...modal, title: 'Your first layout' }} />
    <Stack.Screen name="calibration" options={{ ...modal, title: 'Stick calibration' }} />
    <Stack.Screen name="controller-settings" options={{ ...modal, title: 'Controller settings' }} />
    <Stack.Screen name="cloud" options={{ ...modal, title: AI_CONTROLLER_GENERATOR_ENABLED ? 'Cloud controllers' : 'Cloud account' }} />
    <Stack.Screen name="profiles" options={{ ...modal, title: 'Controllers' }} />
    <Stack.Screen name="pair" options={{ ...modal, title: 'Pair computer' }} />
    <Stack.Screen name="wow-setup" options={{ ...modal, title: 'WoW setup' }} />
  </Stack>;
}
