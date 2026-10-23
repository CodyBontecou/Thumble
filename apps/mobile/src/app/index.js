import { useEffect, useState } from 'react';
import { ActivityIndicator, View } from 'react-native';
import { Redirect } from 'expo-router';
import ControllerScreen from '../ControllerScreen';
import { onboarding } from '../onboarding';
import { colors } from '../ui/design';
export default function Index() {
  const [ready, setReady] = useState(/** @type {boolean | null} */ (null));
  useEffect(() => { let active = true; onboarding.isComplete().then(value => { if (active) setReady(value); }).catch(() => { if (active) setReady(false); }); return () => { active = false; }; }, []);
  if (ready === null) return <View style={{ flex: 1, alignItems: 'center', justifyContent: 'center', backgroundColor: colors.background }}><ActivityIndicator color={colors.text} /></View>;
  return ready ? <ControllerScreen /> : <Redirect href="/onboarding" />;
}
