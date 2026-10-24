import { useEffect, useSyncExternalStore } from 'react';
import { Text, View } from 'react-native';
import { router } from 'expo-router';
import { connection } from '../connection';
import { useSetup } from '../use-setup';
import { Button, Columns, Eyebrow, Page, Row, ui } from '../ui/design';
export default function OnboardingScreen() {
  const { state, save, error } = useSetup();
  const network = useSyncExternalStore(connection.subscribe, connection.snapshot);
  useEffect(() => { connection.pausePlay(); }, []);
  useEffect(() => { if (state.loaded && network.phase === 'connected' && !state.paired) void save({ paired: true }); }, [state.loaded, state.paired, network.phase]); // eslint-disable-line react-hooks/exhaustive-deps
  const milestones = [state.paired, state.controlsTested, state.wowTested, state.personalized];
  const complete = milestones.filter(Boolean).length;
  async function leave() { if (await save({ dismissed: true })) router.dismissTo('/'); }
  return <Page><Columns>
    <View style={ui.column}><Eyebrow>GETTING STARTED · {complete} OF 4 COMPLETE</Eyebrow><Text accessibilityRole="header" style={ui.title}>{complete ? 'Pick up where\nyou left off.' : 'From your phone\nto your first game.'}</Text><Text style={ui.body}>Connect your Mac, try the controls, then make them yours. Your progress is saved on this phone.</Text><Text style={ui.small}>Control and WoW checks are marked complete by you. Pairing alone does not verify the game.</Text><Button secondary disabled={!state.loaded} onPress={leave}>{complete === 4 ? 'Return to controller' : 'Set up later · use controller'}</Button>{!!error && <Text accessibilityRole="alert" style={ui.error}>{error}</Text>}</View>
    <View style={[ui.column, ui.card]}>
      <Row title="From your AI to WoW" detail="Connect your AI → receive a controller → use it on Mac → test in WoW" onPress={() => router.push('/journey')} />
      <Row title="Connect your Mac" detail={network.phase === 'connected' ? 'Connected now' : state.paired ? 'Previously paired · reconnect to continue' : 'Pair with the receiver on the same Wi-Fi'} trailing={state.paired ? '✓' : '1'} onPress={() => router.push('/pair?setup=1')} />
      <Row title="Test your controls" detail={state.controlsTested ? 'You confirmed movement, camera and buttons' : 'Try movement, camera, buttons and release'} trailing={state.controlsTested ? '✓' : '2'} onPress={() => router.push('/setup-test')} />
      <Row title="Set up WoW with ConsolePort" detail={state.wowTested ? 'Your in-game checks are complete' : 'Choose your game, prepare ConsolePort and test your controls'} trailing={state.wowTested ? '✓' : '3'} onPress={() => router.push('/wow-setup?setup=1')} />
      <Row title="Make your first layout" detail={state.personalized ? 'Your first layout is ready' : 'Keep familiar controls or create one with your AI'} trailing={state.personalized ? '✓' : '4'} onPress={() => router.push('/first-layout')} />
    </View>
  </Columns></Page>;
}
