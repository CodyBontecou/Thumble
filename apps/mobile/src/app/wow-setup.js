import { AI_CONTROLLER_GENERATOR_ENABLED } from '../features';
import { useState, useSyncExternalStore } from 'react';
import { Linking, Share, Switch, Text, View } from 'react-native';
import { router } from 'expo-router';
import { consolePortProfile, xboxProfile } from '@tapping/controller';
import { connection } from '../connection';
import { WOW_CHECKS, WOW_CLIENTS, canCompleteWowSetup, nativeGamepad, wowClientName, wowSetupStages, wowSetupStep } from '../onboarding-core';
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
  const native = nativeGamepad(state);
  const stages = wowSetupStages(state);
  const stage = stages.indexOf(step);
  // Native gamepad clients read standard Xbox-style buttons; ConsolePort clients use its preset.
  const builtIn = native ? xboxProfile : consolePortProfile;
  const builtInName = native ? 'Xbox-style' : 'ConsolePort';
  async function choose(id) {
    setBusy(true);
    if (await save({ wowClient: id, ...(id !== state.wowClient ? { consolePortReady: false, wowTested: false, wowChecks: {}, wowSyncStatus: '', wowSyncContext: '' } : {}) })) setChoosingClient(false);
    setBusy(false);
  }
  async function prepareAddon() {
    setBusy(true);
    setError('');
    try {
      if (connection.profileSnapshot().revision === 0) {
        const catalog = await connection.requestProfiles();
        const standard = catalog.profiles.find(profile => profile.id === consolePortProfile.id);
        if (!standard) throw Error('Update Thumble Receiver on your computer to get the ConsolePort controller.');
        await connection.selectProfile(standard, catalog.activationRevision);
      }
      await save({ consolePortReady: true });
    } catch (failure) { setError(failure.message); }
    finally { setBusy(false); }
  }
  async function recordSync(status) {
    setBusy(true);
    await save(previous => {
      const current = testContext(connection.accessSnapshot(), connection.profileSnapshot(), previous.wowClient);
      if (connection.snapshot().phase !== 'connected' || !context.wowKey || current !== context.wowKey || connection.layoutPending || connection.recovering) throw Error('Wait for your controller to connect, then confirm the labels again.');
      return { wowSyncStatus: status, wowSyncContext: current };
    });
    setBusy(false);
  }
  async function standardControls() {
    setBusy(true); setError('');
    try {
      const catalog = await connection.requestProfiles();
      const standard = catalog.profiles.find(profile => profile.id === builtIn.id);
      if (!standard) throw Error('The standard controller is missing from your computer. Restore it in the receiver before continuing.');
      await connection.selectProfile(standard, catalog.activationRevision);
      await save({ controlsTested: false, wowTested: false, wowChecks: {}, controlsCheckContext: '', wowCheckContext: '' });
    } catch (failure) { setError(failure.message); }
    finally { setBusy(false); }
  }
  async function finish() {
    if (!canCompleteWowSetup(state, connection.snapshot().phase === 'connected', context) || connection.layoutPending || connection.recovering) return;
    setBusy(true);
    await save(previous => {
      if (!canCompleteWowSetup(previous, connection.snapshot().phase === 'connected', context) || connection.layoutPending || connection.recovering) throw Error('Complete all five checks for this controller before finishing.');
      if (connection.snapshot().phase !== 'connected' || testContext(connection.accessSnapshot(), connection.profileSnapshot(), state.wowClient) !== context.wowKey) throw Error('The active controller changed. Repeat the checks before finishing.');
      return { paired: true, controlsTested: true, controlsCheckContext: context.controlKey, wowTested: true, personalized: true };
    });
    setBusy(false);
  }
  async function keepControls() {
    if (await save({ personalized: true, profileId: '' })) router.dismissTo('/');
  }
  async function personalize(cloud = false) {
    const layoutMode = native ? 'familiar' : 'consoleport';
    if (await save({ layoutMode, ...(state.layoutMode !== layoutMode ? { profileId: '', personalized: false } : {}) })) router.push(cloud ? '/cloud' : '/first-layout');
  }
  const instructions = native ? `Set up ${client} on my computer for Thumble. WoW: Forever has built-in gamepad support, so no ConsolePort or Thumble addon is needed. Keep Thumble Receiver running with my phone connected so the computer sees an Xbox-style controller, launch ${client}, and check its Gamepad options in the game settings if the controller isn’t picked up. Then I will test movement, camera, an action, a modifier combination and menu navigation myself.` : `Set up WoW addons for my ${client} installation on my computer. Open the CurseForge app, choose World of Warcraft and the exact installation I play, then use Get More Addons to install its matching ConsolePort release: https://www.curseforge.com/wow/addons/console-port . Install Thumble (project 1763832) from https://www.curseforge.com/wow/addons/thumble using a release matching that client. The Thumble addon helps WoW rediscover the virtual gamepad after a receiver restart; ConsolePort handles bindings. Thumble 0.1.2 is approved for Classic Era 1.15.9; if no release matches my client, I can continue with ConsolePort. Restart WoW for a first install and enable the addons at character selection. Thumble addon guide: https://thumble.io/docs#thumble-addon . With Thumble Receiver running and my phone connected, follow ConsolePort's controller setup using standard Xbox-style button names. With Thumble 0.1.2 or later and an updated receiver, select ConsolePort controls on my phone, keep the receiver running, and type /reload in WoW after loading my character. Open the phone controller and compare its spell labels and held modifier layers with ConsolePort. If labels do not update, enable Automatically sync ConsolePort in the receiver, choose the correct WoW folder, and reload again. Return to WoW setup to confirm the labels match, or continue without synced labels if the addon is unavailable. Then I will test movement, camera, an action, a modifier combination and menu navigation myself.`;
  const share = () => { void Share.share({ message: instructions }).catch(failure => setError(failure.message)); };
  const titles = { client: 'Which WoW\ndo you play?', connect: 'Connect your phone.\nKeep your computer ready.', addon: 'Prepare your\nWoW addons.', sync: 'Reload WoW.\nCheck your phone labels.', game: 'Try your controls\nin WoW.', ready: 'Your WoW setup\nis ready.' };
  return <Page key={step} footer={<Actions status={step === 'game' ? `${completedChecks} of ${WOW_CHECKS.length} in-game checks confirmed by you` : 'Your progress is saved on this phone.'}>
    <View style={{ flex: 1 }}>{step === 'client' ? <Button secondary disabled={!state.loaded} onPress={() => router.dismissTo('/onboarding')}>Set up later</Button>
      : step === 'connect' ? <Button disabled={!state.loaded} onPress={() => router.push('/pair?setup=1&returnTo=wow')}>Connect computer</Button>
        : step === 'addon' ? <Button disabled={busy || !online} onPress={prepareAddon}>ConsolePort is ready in WoW</Button>
            : step === 'sync' ? <Button disabled={busy || !online || !context.wowKey || connection.layoutPending || connection.recovering} onPress={() => { void recordSync('confirmed'); }}>Phone labels match ConsolePort</Button>
            : step === 'game' ? <Button disabled={busy || !canCompleteWowSetup(state, online, context)} onPress={finish}>Finish WoW setup</Button>
              : <Button disabled={busy} onPress={keepControls}>Open WoW controller</Button>}</View>
  </Actions>}><Columns><View style={ui.column}>
    <Eyebrow>{native ? `${client} · built-in gamepad` : 'WoW + ConsolePort'} · {step === 'ready' ? 'Ready' : `Step ${stage + 1} of ${stages.length - 1}`}</Eyebrow>
    <Text accessibilityRole="header" style={ui.title}>{titles[step]}</Text>
    <Text style={ui.body}>{step === 'ready' ? `You confirmed the essentials in-game. Your ${native ? 'controller' : 'ConsolePort controller'} is ready to play.` : step === 'client' ? 'WoW: Forever has built-in gamepad support. Retail and Classic use the ConsolePort addon.' : native ? `${client} handles the in-game bindings with its built-in gamepad mode; Thumble puts the controls on your phone.` : 'Use your active controller. ConsolePort handles the in-game bindings; Thumble puts the controls on your phone.'}</Text>
    {!!state.wowClient && <Row title={client} detail="Change WoW installation" onPress={() => setChoosingClient(true)} />}
    {step !== 'client' && <View style={ui.card}>
      <Text style={ui.heading}>{online ? 'Computer connected' : 'Computer not connected'}</Text>
      <Text style={ui.small}>{online ? network.detail : 'Offline practice is available anytime. Playing WoW needs the receiver and this phone connected on the same Wi-Fi.'}</Text>
    </View>}
    {!!error && <Text accessibilityRole="alert" style={ui.error}>{error}</Text>}
    <Text style={ui.small}>Every in-game action is yours. These checks are your confirmation; Thumble cannot inspect WoW.</Text>
  </View><View style={ui.column}>
    {step === 'client' && <View style={ui.card}><Text style={ui.heading}>Choose the WoW client you launch</Text><Text style={ui.body}>WoW: Forever reads the gamepad on its own, with no addons. For other versions, ConsolePort must support that same client: use its matching addon release, and check the addon again when you change WoW versions.</Text>{WOW_CLIENTS.map(item => <Row key={item.id} title={item.name} detail={item.detail} trailing={state.wowClient === item.id ? '✓' : '›'} disabled={!state.loaded || busy} onPress={() => choose(item.id)} />)}</View>}
    {step === 'connect' && <View style={ui.card}><Text style={ui.heading}>One connection for your game</Text><Text style={ui.body}>Open Thumble Receiver on your computer, then pair this phone. Leave the receiver running while you play.</Text>{AI_CONTROLLER_GENERATOR_ENABLED && <Text style={ui.body}>Already built a controller in ChatGPT? Connect your computer, then choose Use this controller on computer in Cloud controllers. Use a full gamepad so every button and modifier is available.</Text>}<Button secondary onPress={() => router.push('/profiles')}>{native ? 'Choose controls' : 'Choose ConsolePort controls'}</Button></View>}
    {step === 'addon' && <>
      <View style={ui.card}><Text style={ui.heading}>1. Install ConsolePort</Text><Text style={ui.body}>On your computer, open the CurseForge app → World of Warcraft and select {client}. In Get More Addons, search for ConsolePort and install its matching release.</Text><Text style={ui.body}>Restart WoW after a first install, enable ConsolePort at character selection, then follow its controller setup. Use standard Xbox-style button names.</Text><Button secondary onPress={() => { void Linking.openURL('https://www.curseforge.com/wow/addons/console-port').catch(failure => setError(failure.message)); }}>Open ConsolePort on CurseForge</Button></View>
      <View style={ui.card}><Text style={ui.heading}>2. Add Thumble for recovery and spell labels</Text><Text style={ui.body}>In the same CurseForge installation, search for Thumble (project 1763832). Install a release matching your client and enable Thumble in WoW’s AddOns list.</Text><Text style={ui.body}>Thumble 0.1.2 or later syncs spell labels and modifier layers after /reload and helps WoW rediscover your computer gamepad after a receiver restart. ConsolePort still handles your action bindings. Type /thumble discovery in WoW chat to check recovery status.</Text><Text style={ui.small}>Thumble 0.1.2 is available on CurseForge for Classic Era 1.15.9. If it isn’t listed for your client, a compatible release may not be available yet. You can continue with ConsolePort; Thumble is recommended, not required.</Text><Button secondary onPress={() => { void Linking.openURL('https://www.curseforge.com/wow/addons/thumble').catch(failure => setError(failure.message)); }}>Install Thumble on CurseForge</Button></View>
      <Button secondary onPress={share}>Send setup steps to my computer</Button><Text style={ui.small}>Keep the receiver running and phone connected. Confirm below once ConsolePort is enabled and its controller setup is finished.</Text>
    </>}
    {step === 'sync' && <>
      <View style={ui.card}><Text style={ui.heading}>Reload after your character is loaded</Text><Text style={ui.body}>Keep Thumble Receiver running and this phone connected. With ConsolePort and Thumble 0.1.2 or later enabled, type /reload in WoW chat. Reload again after starting the receiver or changing spells or bindings.</Text><Text style={ui.small}>Use a ConsolePort controller on your phone. An updated receiver reads the saved labels after the reload; cooldowns are not live.</Text><Text style={ui.small}>Controller: {layout.profile.name}</Text><Button secondary disabled={busy || !online} onPress={standardControls}>Use built-in ConsolePort controls</Button></View>
      <View style={ui.card}><Text style={ui.heading}>Compare labels and modifier layers</Text><Text style={ui.body}>Open your phone controller. Compare its spell labels with ConsolePort in WoW, then hold each modifier and compare that layer. Return through Thumble menu → WoW setup to confirm they match.</Text><Button secondary onPress={() => router.dismissTo('/')}>Open controller to check labels</Button><Text style={ui.small}>Missing labels? In the receiver, enable Automatically sync ConsolePort. Use Choose WoW folder… for a different installation, check /thumble sync in WoW, then /reload again. Keep ConsolePort’s action bars enabled.</Text></View>
      <Text style={ui.small}>This is your visual confirmation. If the addon is unavailable or you prefer gamepad button names, you can test and play without synced labels.</Text><Button secondary disabled={busy || !online || !context.wowKey || connection.layoutPending || connection.recovering} onPress={() => { void recordSync('skipped'); }}>Continue without synced labels</Button>
    </>}
    {step === 'game' && <View style={ui.card}><Text style={ui.heading}>Five checks before you play</Text>{native ? <Text style={ui.small}>{client} picks up Thumble as an Xbox-style controller. If it doesn’t respond, check the Gamepad options in the game settings.</Text> : <><Text style={ui.small}>{state.wowSyncStatus === 'confirmed' ? 'You confirmed the phone labels match ConsolePort.' : 'Continuing without confirmed spell labels.'}</Text><Button secondary onPress={() => { void save({ wowSyncStatus: '', wowSyncContext: '' }); }}>Check phone labels again</Button></>}<Text style={ui.body}>Open WoW on your computer and test in a quiet place. Return here to tick each check once it works.</Text><Text style={ui.small}>Controller: {layout.profile.name}. {native ? 'Actions and modifier layers come from the game’s gamepad bindings.' : 'Actions and modifier layers come from your ConsolePort bindings.'}</Text><Button secondary disabled={busy || !online} onPress={standardControls}>Use built-in {builtInName} controls</Button><Button secondary onPress={() => router.dismissTo('/')}>Open controller to test in WoW</Button><Text style={ui.small}>Return through Thumble menu → WoW setup. Your checks stay saved.</Text>{WOW_CHECKS.map(check => <View key={check.id} style={{ gap: 8, paddingVertical: 8 }}><View style={{ flexDirection: 'row', alignItems: 'center', gap: 16 }}><Text style={[ui.heading, { flex: 1 }]}>{check.title}</Text><Switch accessibilityLabel={check.title} disabled={busy || !online || !context.wowKey || connection.layoutPending || connection.recovering} value={currentChecks[check.id] === true} onValueChange={value => { void save(previous => {
      if (connection.snapshot().phase !== 'connected' || testContext(connection.accessSnapshot(), connection.profileSnapshot(), previous.wowClient) !== context.wowKey) throw Error('The active controller changed. Repeat this check.');
      return { wowCheckContext: context.wowKey, wowTested: false, wowChecks: { ...(previous.wowCheckContext === context.wowKey ? previous.wowChecks : {}), [check.id]: value } };
    }); }} trackColor={{ false: colors.border, true: colors.secondary }} /></View><Text style={ui.small}>{check.detail}</Text></View>)}</View>}
    {step === 'ready' && <View style={ui.card}><Text style={ui.heading}>Your WoW controller is ready.</Text><Text style={ui.body}>Keep WoW and the receiver open on your computer. Set spells, targeting and modifier layers {native ? 'in the game’s gamepad settings' : 'in ConsolePort'} as you play.</Text><Text style={ui.small}>To adjust your sticks or revisit setup, open the Thumble menu on your controller.</Text>{!native && <Row title="Check phone labels again" onPress={() => { void save({ wowSyncStatus: '', wowSyncContext: '', wowTested: false }); }} />}<Row title="Repeat the in-game checks" onPress={() => { void save({ wowTested: false, wowChecks: {} }); }} />{AI_CONTROLLER_GENERATOR_ENABLED && <><Button secondary onPress={() => { void personalize(true); }}>Design a WoW layout with my AI</Button><Button secondary onPress={() => { void personalize(); }}>Match my character with a local agent</Button></>}</View>}
    {step !== 'client' && <View style={ui.card}><Row title={help ? 'Hide connection help' : 'Something isn’t working?'} trailing={help ? '−' : '+'} onPress={() => setHelp(!help)} />{help && native && <><Text style={ui.body}>No input: check the receiver and active profile on your computer, then the Gamepad options in {client}’s settings. Release your controls and allow a few seconds to reconnect after a receiver restart.</Text><Text style={ui.body}>Wrong action: check the game’s gamepad bindings. Reversed camera: use Stick calibration.</Text><Button secondary onPress={() => router.push('/pair?setup=1&returnTo=wow')}>Reconnect computer</Button><Button secondary onPress={() => router.push('/calibration')}>Stick calibration</Button></>}{help && !native && <><Text style={ui.body}>No input: check the receiver and active profile on your computer, then ConsolePort’s controller setup. The latest Thumble addon refreshes virtual gamepad discovery automatically after a receiver restart, outside combat. Release your controls and allow a few seconds to reconnect. If you do not use the addon or WoW still does not respond, pause the controller, enter /console GamePadEnable 0 followed by /console GamePadEnable 1 in WoW chat, then resume and test in a quiet place.</Text><Text style={ui.body}>Wrong action: check ConsolePort’s bindings for the current character. Reversed camera: use Stick calibration.</Text><Button secondary onPress={() => router.push('/pair?setup=1&returnTo=wow')}>Reconnect computer</Button><Button secondary onPress={() => router.push('/calibration')}>Stick calibration</Button></>}</View>}
  </View></Columns></Page>;
}
