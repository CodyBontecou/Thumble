import { useCallback, useRef } from 'react';
import { ActivityIndicator, Text, View } from 'react-native';
import { router, useFocusEffect, useLocalSearchParams } from 'expo-router';
import ControllerScreen from '../ControllerScreen';
import { onboarding } from '../onboarding';
import { setupComplete } from '../onboarding-core';
import { useSetup } from '../use-setup';
import { Button, colors, ui } from '../ui/design';
export default function Index() {
  const { practice } = useLocalSearchParams();
  const { state, error, setError } = useSetup();
  const entryHandled = useRef(false);
  useFocusEffect(useCallback(() => {
    if (!state.loaded || entryHandled.current) return;
    entryHandled.current = true;
    if (!state.dismissed && !setupComplete(state) && practice !== '1') router.push(state.welcomeSeen ? '/onboarding' : '/welcome');
  }, [state, practice]));
  if (!state.loaded) return <View style={{ flex: 1, padding: 24, gap: 16, alignItems: 'center', justifyContent: 'center', backgroundColor: colors.background }}>{error ? <><Text accessibilityRole="alert" style={ui.error}>{error}</Text><Button onPress={() => { setError(''); void onboarding.load().catch(failure => setError(failure.message)); }}>Retry loading setup</Button></> : <ActivityIndicator color={colors.text} />}</View>;
  // Keep the real controller mounted beneath setup so incoming profiles render
  // and acknowledge normally. Its focus handler releases input while covered.
  return <ControllerScreen />;
}
