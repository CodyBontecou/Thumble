import { AI_CONTROLLER_GENERATOR_ENABLED } from '../features';
import { useEffect, useSyncExternalStore } from 'react';
import { Linking, Text, View } from 'react-native';
import { router } from 'expo-router';
import { connection } from '../connection';
import { useSetup } from '../use-setup';
import { Button, Columns, Eyebrow, Page, Row, ui } from '../ui/design';
export default function OnboardingScreen() {
  const { state, save, error, setError } = useSetup();
  const network = useSyncExternalStore(connection.subscribe, connection.snapshot);
  useEffect(() => { connection.pausePlay(); }, []);
  useEffect(() => { if (state.loaded && network.phase === 'connected' && !state.paired) void save({ paired: true }); }, [state.loaded, state.paired, network.phase]); // eslint-disable-line react-hooks/exhaustive-deps
  const milestones = [state.paired, state.controlsTested, state.wowTested, ...(AI_CONTROLLER_GENERATOR_ENABLED ? [state.personalized] : [])];
  const complete = milestones.filter(Boolean).length;
  async function leave() { if (await save({ dismissed: true })) router.dismissTo('/'); }
  return <Page><Columns>
    <View style={ui.column}><Eyebrow>YOUR WOW SETUP · {complete} OF {milestones.length} COMPLETE</Eyebrow><Text accessibilityRole="header" style={ui.title}>{complete ? 'Pick up where\nyou left off.' : 'Get ready\nfor Azeroth.'}</Text><Text style={ui.body}>Pair your phone, prepare ConsolePort and the recommended Thumble addon, reload WoW to check your phone labels, then test the controls in-game. Your setup progress stays saved here.</Text><Text style={ui.small}>Control and WoW checks are marked complete by you. Pairing alone does not verify the game.</Text><Button disabled={!state.loaded} onPress={() => router.push('/wow-setup?setup=1')}>{complete === milestones.length ? 'Review WoW setup' : complete ? 'Continue WoW setup' : 'Set up WoW'}</Button><Button secondary disabled={!state.loaded} onPress={leave}>{network.phase === 'connected' ? 'Open controller' : 'Try offline controls'}</Button>{!!error && <Text accessibilityRole="alert" style={ui.error}>{error}</Text>}</View>
    <View style={[ui.column, ui.card]}>
      {AI_CONTROLLER_GENERATOR_ENABLED && <Row title="From your AI to WoW" detail="Connect your AI → receive a controller → use it on computer → test in WoW" onPress={() => router.push('/journey')} />}
      <Row title="Pair your phone with your computer" detail={network.phase === 'connected' ? 'Connected now' : state.paired ? 'Previously paired · reconnect to continue' : 'Pair with the receiver on the same Wi-Fi'} trailing={state.paired ? '✓' : '1'} onPress={() => router.push('/pair?setup=1')} />
      <Row title="Check movement, camera and actions" detail={state.controlsTested ? 'You confirmed movement, camera and buttons' : 'Try movement, camera, buttons and release'} trailing={state.controlsTested ? '✓' : '2'} onPress={() => router.push('/wow-setup?setup=1')} />
      <Row title="Thumble addon on CurseForge" detail="Recommended for spell labels and virtual gamepad recovery · opens installation guide" onPress={() => { void Linking.openURL('https://thumble.io/docs#thumble-addon').catch(failure => setError(failure.message)); }} />
      <Row title="Set up WoW with ConsolePort" detail={state.wowTested ? 'Your in-game checks are complete' : 'Choose your game, prepare ConsolePort and test your controls'} trailing={state.wowTested ? '✓' : '3'} onPress={() => router.push('/wow-setup?setup=1')} />
      {AI_CONTROLLER_GENERATOR_ENABLED && <Row title="Make your first layout" detail={state.personalized ? 'Your first layout is ready' : 'Keep familiar controls or create one with your AI'} trailing={state.personalized ? '✓' : '4'} onPress={() => router.push('/first-layout')} />}
    </View>
  </Columns></Page>;
}
