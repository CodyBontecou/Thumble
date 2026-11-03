import { useCallback, useSyncExternalStore } from 'react';
import { ActivityIndicator, Text, View } from 'react-native';
import { router, useFocusEffect, useLocalSearchParams } from 'expo-router';
import ControllerScreen from '../ControllerScreen';
import { onboarding } from '../onboarding';
import { setupComplete } from '../onboarding-core';
import { purchases } from '../purchases/store';
import { accessGate } from '../purchases/core';
import { useSetup } from '../use-setup';
import { Button, colors, ui } from '../ui/design';

// Hard paywall: Welcome, then a plan, then setup. Development builds without a
// store catalog may continue so the controller can be tested on simulators.
const gateOptions = { allowUnconfigured: __DEV__ };
export default function Index() {
  const { practice } = useLocalSearchParams();
  const { state, error, setError } = useSetup();
  const purchase = useSyncExternalStore(purchases.subscribe, purchases.snapshot);
  const gate = accessGate(purchase, gateOptions);
  useFocusEffect(useCallback(() => {
    if (!state.loaded || gate === 'loading') return;
    if (!state.welcomeSeen) router.push('/welcome');
    else if (gate === 'paywall') router.push('/pro');
    else if (gate === 'expired') router.push('/expired');
    else if (!state.dismissed && !setupComplete(state) && !practice) router.push('/connect');
  }, [state, gate, practice]));
  if (!state.loaded || gate === 'loading') return <View style={{ flex: 1, padding: 24, gap: 16, alignItems: 'center', justifyContent: 'center', backgroundColor: colors.background }}>{error ? <><Text accessibilityRole="alert" style={ui.error}>{error}</Text><Button onPress={() => { setError(''); void onboarding.load().catch(failure => setError(failure.message)); }}>Retry loading setup</Button></> : <ActivityIndicator color={colors.text} />}</View>;
  if (gate !== 'open') return <View style={{ flex: 1, backgroundColor: '#17191b' }} />;
  // Keep the real controller mounted beneath setup so incoming profiles render
  // and acknowledge normally. Its focus handler releases input while covered.
  return <ControllerScreen coach={practice === 'coach'} />;
}
