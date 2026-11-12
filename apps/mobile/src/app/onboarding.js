import { AI_CONTROLLER_GENERATOR_ENABLED } from '../features';
import { useEffect, useSyncExternalStore } from 'react';
import { Linking, Text, View } from 'react-native';
import { router } from 'expo-router';
import { connection } from '../connection';
import { onboarding } from '../onboarding';
import { useSetup } from '../use-setup';
import { Button, Columns, Eyebrow, Lamp, Page, Row, colors, fonts, ui } from '../ui/design';

/** Getting started: make it yours, connect your computer, then set up WoW. */
export default function OnboardingScreen() {
  const { state, save, error, setError } = useSetup();
  const network = useSyncExternalStore(connection.subscribe, connection.snapshot);
  useEffect(() => { connection.pausePlay(); }, []);
  useEffect(() => { if (state.loaded && network.phase === 'connected' && !state.paired) void save({ paired: true }); }, [state.loaded, state.paired, network.phase]); // eslint-disable-line react-hooks/exhaustive-deps
  const online = network.phase === 'connected';
  const steps = [
    { done: state.tourDone, title: 'Make it yours', detail: state.tourDone ? 'Layout chosen and customized' : 'Pick a layout, then move, resize and remap', onPress: () => void onboarding.update({ tourDone: false, tourStage: '' }).then(() => router.dismissTo('/')) },
    { done: state.paired, title: online ? 'Connected your computer' : 'Connect your computer', detail: online ? 'Connected now' : state.paired ? 'Previously paired · reconnect to continue' : 'Scan the code in Thumble Receiver', onPress: () => router.push('/pair?setup=1') },
    { done: state.wowTested, title: 'Set up WoW', detail: state.wowTested ? 'Your in-game checks are complete' : 'Pick your WoW version, then test in-game', onPress: () => router.push('/wow-setup?setup=1') },
  ];
  const complete = steps.filter(step => step.done).length;
  const next = steps.find(step => !step.done);
  async function leave() { if (await save({ dismissed: true })) router.dismissTo('/'); }
  return <Page><Columns>
    <View style={ui.column}>
      <Eyebrow>{complete ? `${complete} of ${steps.length} done` : 'Getting started'}</Eyebrow>
      <Text accessibilityRole="header" style={ui.title}>{complete ? 'Pick up where you left off.' : 'Get ready for Azeroth.'}</Text>
      <View style={{ flexDirection: 'row', gap: 6 }}>{steps.map(step => <View key={step.title} style={{ flex: 1, height: 4, borderRadius: 2, backgroundColor: step.done ? colors.accent : colors.raised }} />)}</View>
      <Text style={ui.body}>Three steps, about five minutes. Your progress is saved on this phone.</Text>
      <Button disabled={!state.loaded} onPress={next ? next.onPress : () => router.push('/wow-setup?setup=1')}>{next ? (next === steps[0] ? 'Start the tour' : next === steps[1] ? 'Connect my computer' : 'Continue WoW setup') : 'Review WoW setup'}</Button>
      <Button secondary disabled={!state.loaded} onPress={leave}>Open controller</Button>
      {!!error && <Text accessibilityRole="alert" style={ui.error}>{error}</Text>}
    </View>
    <View style={ui.column}>
      <View style={ui.group}>
        {steps.map((step, index) => <View key={step.title} style={index ? { borderTopWidth: 0.5, borderTopColor: colors.separator, marginLeft: 52 } : undefined}>
          <View style={{ flexDirection: 'row', alignItems: 'center', marginLeft: index ? -52 : 0 }}>
            <View style={{ paddingLeft: 16 }}><Lamp state={step.done ? 'on' : step === next ? 'waiting' : 'off'} /></View>
            <View style={{ flex: 1 }}><Row title={step.title} detail={step.detail} onPress={step.onPress} /></View>
          </View>
        </View>)}
      </View>
      <Text style={ui.caption}>Recommended</Text>
      <Row title="Thumble addon on CurseForge" detail="ConsolePort spell labels and gamepad recovery · not needed for WoW: Forever" trailing="↗" onPress={() => { void Linking.openURL('https://www.curseforge.com/wow/addons/thumble').catch(failure => setError(failure.message)); }} />
      {AI_CONTROLLER_GENERATOR_ENABLED && <Row title="From your AI to WoW" detail="Connect your AI → receive a controller → use it on computer → test in WoW" onPress={() => router.push('/journey')} />}
      <Text style={[ui.small, { fontFamily: fonts.body }]}>WoW checks are marked complete by you. Thumble can’t see inside the game.</Text>
    </View>
  </Columns></Page>;
}
