import { useSyncExternalStore } from 'react';
import { Text, View } from 'react-native';
import { router, useLocalSearchParams } from 'expo-router';
import { connection } from '../connection';
import { useSetup } from '../use-setup';
import { testContext } from '../journey';
import { Button, Columns, Eyebrow, Page, ui } from '../ui/design';
export default function SetupTest() {
  const { returnTo } = useLocalSearchParams();
  const network = useSyncExternalStore(connection.subscribe, connection.snapshot);
  const layout = useSyncExternalStore(connection.subscribeProfile, connection.profileSnapshot);
  const access = useSyncExternalStore(connection.subscribeAccess, connection.accessSnapshot);
  const { state, save, error, setError } = useSetup();
  const online = network.phase === 'connected';
  const context = testContext(access, layout);
  async function confirm() {
    const current = testContext(connection.accessSnapshot(), connection.profileSnapshot());
    if (connection.snapshot().phase !== 'connected' || !current || connection.layoutPending || connection.recovering) { setError('Reconnect and wait for this controller to be ready before confirming.'); return; }
    if (await save(() => {
      if (testContext(connection.accessSnapshot(), connection.profileSnapshot()) !== current || connection.snapshot().phase !== 'connected') throw Error('The active controller changed. Test it again before confirming.');
      return { paired: true, controlsTested: true, controlsCheckContext: current };
    })) router.dismissTo(returnTo === 'wow' ? '/wow-setup' : '/onboarding');
  }
  return <Page><Columns><View style={ui.column}><Eyebrow>Test your controls</Eyebrow><Text accessibilityRole="header" style={ui.title}>{'A quick check.\nThen you’re ready.'}</Text><Text style={ui.body}>{online ? network.detail : 'Connect your computer to test the virtual controller. Offline practice does not verify computer input.'}</Text><Button onPress={() => online ? router.dismissTo('/?practice=1') : router.push(returnTo === 'wow' ? '/pair?setup=1&returnTo=wow' : '/pair?setup=1')}>{online ? 'Open controller to test' : 'Connect computer'}</Button><Text style={ui.small}>{returnTo === 'wow' ? 'Return through Thumble menu → WoW setup → Test controls.' : 'Return through the Thumble menu → Getting started → Test your controls.'}</Text></View><View style={[ui.column, ui.card]}><Text style={ui.heading}>Check on your computer</Text><Text style={ui.body}>Move both sticks in every direction and let go. Try both triggers, ABXY, the D-pad and movement while pressing a button. Confirm the Computer receives input and everything returns to neutral.</Text><Text style={ui.small}>This is your confirmation of the test, not an automatic HID measurement.</Text><Button disabled={!state.loaded || !online || !context || connection.layoutPending || connection.recovering} onPress={confirm}>I tested the controls on my computer</Button>{!!error && <Text accessibilityRole="alert" style={ui.error}>{error}</Text>}</View></Columns></Page>;
}
