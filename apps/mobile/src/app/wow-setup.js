import { useState, useSyncExternalStore } from 'react';
import { Linking, Share, Switch, Text, View } from 'react-native';
import { router } from 'expo-router';
import { xboxProfile } from '@tapping/controller';
import { connection } from '../connection';
import { WOW_CHECKS, WOW_CLIENTS, canCompleteWowSetup, wowClientName, wowSetupStep } from '../onboarding-core';
import { useSetup } from '../use-setup';
import { testContext } from '../journey';
import { Actions, Button, Columns, Eyebrow, Page, Row, colors, ui } from '../ui/design';

export default function WowSetupScreen() {
  const { state, save, error, setError } = useSetup();
  const network = useSyncExternalStore(connection.subscribe, connection.snapshot);
  const online = network.phase === 'connected';
  const layout = useSyncExternalStore(connection.subscribeProfile, connection.profileSnapshot);
  const access = useSyncExternalStore(connection.subscribeAccess, connection.accessSnapshot);
  const context = { controlKey: testContext(access, layout), wowKey: testContext(access, layout, state.wowClient) };
  const currentChecks = state.wowCheckContext === context.wowKey ? state.wowChecks : {};
  const [choosingClient, setChoosingClient] = useState(false);
  const [busy, setBusy] = useState(false);
  const [help, setHelp] = useState(false);
  const step = choosingClient ? 'client' : wowSetupStep(state, online, context);
  const client = wowClientName(state);
  const completedChecks = WOW_CHECKS.filter(check => currentChecks[check.id]).length;
  const stages = ['client', 'connect', 'controls', 'addon', 'game', 'ready'];
  const stage = stages.indexOf(step);
  async function choose(id) {
    setBusy(true);
    if (await save({ wowClient: id, ...(id !== state.wowClient ? { consolePortReady: false, wowTested: false, wowChecks: {} } : {}) })) setChoosingClient(false);
    setBusy(false);
  }
  async function prepareAddon() {
    setBusy(true);
    await save({ consolePortReady: true });
    setBusy(false);
  }
  async function standardControls() {
    setBusy(true); setError('');
    try {
      const catalog = await connection.requestProfiles();
      const standard = catalog.profiles.find(profile => profile.id === xboxProfile.id);
      if (!standard) throw Error('The standard controller is missing from your Mac. Restore it in the receiver before continuing.');
      await connection.selectProfile(standard, catalog.activationRevision);
      router.push('/setup-test?returnTo=wow');
    } catch (failure) { setError(failure.message); }
    finally { setBusy(false); }
  }
  async function finish() {
    if (!canCompleteWowSetup(state, connection.snapshot().phase === 'connected', context) || connection.layoutPending || connection.recovering) return;
    setBusy(true);
    await save(() => {
      if (connection.snapshot().phase !== 'connected' || testContext(connection.accessSnapshot(), connection.profileSnapshot(), state.wowClient) !== context.wowKey) throw Error('The active controller changed. Repeat the checks before finishing.');
      return { paired: true, wowTested: true, personalized: true };
    });
    setBusy(false);
  }
  async function keepControls() {
    if (await save({ personalized: true, profileId: '' })) router.dismissTo('/');
  }
  async function personalize(cloud = false) {
    if (await save({ layoutMode: 'consoleport', ...(state.layoutMode !== 'consoleport' ? { profileId: '', personalized: false } : {}) })) router.push(cloud ? '/cloud' : '/first-layout');
  }
  const instructions = `Set up ConsolePort for my ${client} installation on my Mac. In CurseForge, select the exact WoW installation I play, then install its matching ConsolePort version: https://www.curseforge.com/wow/addons/console-port . Restart WoW for a first install and enable ConsolePort at character selection. With Thumble Receiver running and my phone connected, follow ConsolePort's controller setup using standard Xbox-style button names. Then I will test movement, camera, an action, a modifier combination and menu navigation myself.`;
  const share = () => { void Share.share({ message: instructions }).catch(failure => setError(failure.message)); };
  const titles = { client: 'Which WoW\ndo you play?', connect: 'Connect your phone.\nKeep your Mac ready.', controls: 'Check the controller\nbefore the game.', addon: 'Set up ConsolePort\non your Mac.', game: 'Five quick checks.\nThen you’re ready.', ready: 'Your WoW setup\nis ready.' };
  return <Page footer={<Actions status={step === 'game' ? `${completedChecks} of ${WOW_CHECKS.length} in-game checks confirmed by you` : 'Your progress is saved on this phone.'}>
    <View style={{ flex: 1 }}>{step === 'client' ? <Button secondary disabled={!state.loaded} onPress={() => router.dismissTo('/onboarding')}>Set up later</Button>
      : step === 'connect' ? <Button disabled={!state.loaded} onPress={() => router.push('/pair?setup=1&returnTo=wow')}>Connect Mac</Button>
        : step === 'controls' ? <Button disabled={busy || !online} onPress={() => router.push('/setup-test?returnTo=wow')}>Test this controller</Button>
          : step === 'addon' ? <Button disabled={busy || !online} onPress={prepareAddon}>ConsolePort is ready in WoW</Button>
            : step === 'game' ? <Button disabled={busy || !canCompleteWowSetup(state, online, context)} onPress={finish}>Finish WoW setup</Button>
              : <Button disabled={busy} onPress={keepControls}>Keep my controls and play</Button>}</View>
  </Actions>}><Columns><View style={ui.column}>
    <Eyebrow>WOW + CONSOLEPORT · {step === 'ready' ? 'READY' : `STEP ${stage + 1} OF 5`}</Eyebrow>
    <Text accessibilityRole="header" style={ui.title}>{titles[step]}</Text>
    <Text style={ui.body}>{step === 'ready' ? 'You confirmed the essentials in-game. Keep familiar controls, or make a layout that fits your thumbs.' : 'Use your active controller. ConsolePort handles the in-game bindings; Thumble puts the controls on your phone.'}</Text>
    {!!state.wowClient && <Row title={client} detail="Change WoW installation" onPress={() => setChoosingClient(true)} />}
    {step !== 'client' && <View style={ui.card}>
      <Text style={ui.heading}>{online ? 'Mac connected' : 'Mac not connected'}</Text>
      <Text style={ui.small}>{online ? network.detail : 'Cloud previews work offline. Playing WoW needs Thumble Receiver and your phone connected on the same Wi-Fi.'}</Text>
    </View>}
    {!!error && <Text accessibilityRole="alert" style={ui.error}>{error}</Text>}
    <Text style={ui.small}>Every in-game action is yours. These checks are your confirmation; Thumble cannot inspect WoW.</Text>
  </View><View style={ui.column}>
    {step === 'client' && <View style={ui.card}><Text style={ui.heading}>Match your Battle.net selection</Text><Text style={ui.body}>Choose the installation you actually launch. Install ConsolePort for that same version in CurseForge.</Text>{WOW_CLIENTS.map(item => <Row key={item.id} title={item.name} detail={item.detail} trailing={state.wowClient === item.id ? '✓' : '›'} disabled={!state.loaded || busy} onPress={() => choose(item.id)} />)}</View>}
    {step === 'connect' && <View style={ui.card}><Text style={ui.heading}>One connection for your game</Text><Text style={ui.body}>Open Thumble Receiver on your Mac, then pair this phone. Leave the receiver running while you play.</Text><Text style={ui.body}>Already built a controller in ChatGPT? Connect your Mac, then choose Use this controller on Mac in Cloud controllers. Use a full gamepad so ConsolePort’s buttons and modifiers are available.</Text><Button secondary onPress={() => router.push('/profiles')}>Choose a standard controller</Button></View>}
    {step === 'controls' && <View style={ui.card}><Text style={ui.heading}>Try both sticks and every button</Text><Text style={ui.body}>Use the Mac control test before configuring WoW. Check neutral release, both triggers, shoulders and D-pad as well as A/B/X/Y.</Text><Text style={ui.small}>Active controller: {layout.profile.name}. Confirmations belong to this controller; changing it requires another check.</Text><Button secondary disabled={busy || !online} onPress={standardControls}>Switch to standard controls</Button></View>}
    {step === 'addon' && <View style={ui.card}><Text style={ui.heading}>Use the matching addon version</Text><Text style={ui.body}>On your Mac, select {client} in CurseForge and install ConsolePort. Restart WoW for a first installation, enable the addon at character selection, then follow its controller setup.</Text><Text style={ui.body}>Use standard Xbox-style button names. Keep the receiver running and the phone connected.</Text><Button secondary onPress={share}>Send setup steps to my Mac</Button><Button secondary onPress={() => { void Linking.openURL('https://www.curseforge.com/wow/addons/console-port').catch(failure => setError(failure.message)); }}>Open ConsolePort download</Button><Text style={ui.small}>Already installed? Confirm below once ConsolePort is enabled and its controller setup is finished.</Text></View>}
    {step === 'game' && <View style={ui.card}><Text style={ui.heading}>Try these in a quiet place</Text><Button secondary onPress={() => router.dismissTo('/')}>Open controller to test in WoW</Button><Text style={ui.small}>Return through Thumble menu → WoW setup. Your checks stay saved.</Text>{WOW_CHECKS.map(check => <View key={check.id} style={{ gap: 8, paddingVertical: 8 }}><View style={{ flexDirection: 'row', alignItems: 'center', gap: 16 }}><Text style={[ui.heading, { flex: 1 }]}>{check.title}</Text><Switch accessibilityLabel={check.title} disabled={busy || !online || !context.wowKey || connection.layoutPending || connection.recovering} value={currentChecks[check.id] === true} onValueChange={value => { void save(previous => {
      if (connection.snapshot().phase !== 'connected' || testContext(connection.accessSnapshot(), connection.profileSnapshot(), previous.wowClient) !== context.wowKey) throw Error('The active controller changed. Repeat this check.');
      return { wowCheckContext: context.wowKey, wowTested: false, wowChecks: { ...(previous.wowCheckContext === context.wowKey ? previous.wowChecks : {}), [check.id]: value } };
    }); }} trackColor={{ false: colors.border, true: colors.secondary }} /></View><Text style={ui.small}>{check.detail}</Text></View>)}</View>}
    {step === 'ready' && <View style={ui.card}><Text style={ui.heading}>Keep playing, or make it yours</Text><Text style={ui.body}>AI personalization is optional. The standard controller remains a complete starting point for ConsolePort.</Text><Button secondary onPress={() => { void personalize(true); }}>Design a WoW layout in ChatGPT</Button><Button secondary onPress={() => { void personalize(); }}>Match my character with a local agent</Button><Text style={ui.small}>Character matching uses a fresh Thumble Bridge export. Review and apply binding changes in WoW before syncing spell labels.</Text><Row title="Repeat the in-game checks" onPress={() => { void save({ wowTested: false, wowChecks: {} }); }} /></View>}
    {step !== 'client' && <View style={ui.card}><Row title={help ? 'Hide connection help' : 'Something isn’t working?'} trailing={help ? '−' : '+'} onPress={() => setHelp(!help)} />{help && <><Text style={ui.body}>No input: check the receiver and active profile on your Mac, then ConsolePort’s controller setup. Wrong action: check ConsolePort’s bindings for the current character. Reversed camera: use Stick calibration.</Text><Button secondary onPress={() => router.push('/pair?setup=1&returnTo=wow')}>Reconnect Mac</Button><Button secondary onPress={() => router.push('/calibration')}>Stick calibration</Button></>}</View>}
  </View></Columns></Page>;
}
