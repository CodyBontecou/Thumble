import { useSyncExternalStore } from 'react';
import { Text, View } from 'react-native';
import { router, useLocalSearchParams } from 'expo-router';
import { connection } from '../connection';
import { useSetup } from '../use-setup';
import { Button, Columns, Eyebrow, Page, ui } from '../ui/design';
export default function SetupTest() {
  const { returnTo } = useLocalSearchParams();
  const network = useSyncExternalStore(connection.subscribe, connection.snapshot);
  const { state, save, error } = useSetup();
  const online = network.phase === 'connected';
  return <Page><Columns><View style={ui.column}><Eyebrow>TEST YOUR CONTROLS</Eyebrow><Text accessibilityRole="header" style={ui.title}>{'A quick check.\nThen you’re ready.'}</Text><Text style={ui.body}>{online ? network.detail : 'Connect your Mac to test the virtual controller. Offline practice does not verify Mac input.'}</Text><Button onPress={() => online ? router.dismissTo('/?practice=1') : router.push(returnTo === 'wow' ? '/pair?setup=1&returnTo=wow' : '/pair?setup=1')}>{online ? 'Open controller to test' : 'Connect Mac'}</Button><Text style={ui.small}>{returnTo === 'wow' ? 'Return through Thumble menu → WoW setup → Test controls.' : 'Return through the Thumble menu → Getting started → Test your controls.'}</Text></View><View style={[ui.column, ui.card]}><Text style={ui.heading}>Check on your Mac</Text><Text style={ui.body}>Move both sticks in every direction and let go. Try both triggers, ABXY, the D-pad and movement while pressing a button. Confirm the Mac receives input and everything returns to neutral.</Text><Text style={ui.small}>This is your confirmation of the test, not an automatic HID measurement.</Text><Button disabled={!state.loaded || !online} onPress={async () => { if (await save({ paired: true, controlsTested: true })) router.dismissTo(returnTo === 'wow' ? '/wow-setup' : '/onboarding'); }}>I tested the controls on my Mac</Button>{!!error && <Text accessibilityRole="alert" style={ui.error}>{error}</Text>}</View></Columns></Page>;
}
