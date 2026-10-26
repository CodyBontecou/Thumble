import { useSyncExternalStore } from 'react';
import { Text, View } from 'react-native';
import { router } from 'expo-router';
import { connection } from '../connection';
import { cloud } from '../cloud/store';
import { cloudJourney } from '../journey';
import { useSetup } from '../use-setup';
import { Actions, Button, Columns, Eyebrow, Page, ui } from '../ui/design';

export default function JourneyScreen() {
  const { state: setup, error } = useSetup();
  const state = useSyncExternalStore(cloud.subscribe, cloud.snapshot);
  const network = useSyncExternalStore(connection.subscribe, connection.snapshot);
  const layout = useSyncExternalStore(connection.subscribeProfile, connection.profileSnapshot);
  const access = useSyncExternalStore(connection.subscribeAccess, connection.accessSnapshot);
  const journey = cloudJourney({ cloud: state, setup, network, layout, access, pairing: connection.session, layoutPending: connection.layoutPending, recovering: connection.recovering });
  return <Page footer={<Actions status="Your progress is saved. Controls stay paused during setup."><View style={{ flex: 1 }}><Button disabled={!setup.loaded || !state.loaded} onPress={() => router.push(journey.route)}>{journey.action}</Button></View></Actions>}>
    <Columns><View style={ui.column}><Eyebrow>AI TO WOW · {journey.complete} OF 4 COMPLETE</Eyebrow><Text accessibilityRole="header" style={ui.title}>{journey.tested ? 'Your controller.\nReady to play.' : 'From your AI\nto your first game.'}</Text><Text style={ui.body}>Create in ChatGPT or your preferred AI, receive it here, then use it with ConsolePort on your computer.</Text><Text style={ui.small}>A delivery confirms the phone connection. Computer readiness requires its acknowledgement. Only your in-game checks confirm WoW.</Text>{!!error && <Text accessibilityRole="alert" style={ui.error}>{error}</Text>}<Button secondary onPress={() => router.push('/first-layout')}>Use a local agent or familiar controls</Button></View>
    <View style={ui.column}>{journey.steps.map((step, index) => <View key={step.id} testID={`journey-${step.id}`} style={ui.card}><Text accessibilityRole="header" style={ui.heading}>{step.done ? '✓' : index + 1} · {step.title}</Text><Text style={ui.body}>{step.detail}</Text></View>)}</View></Columns>
  </Page>;
}
