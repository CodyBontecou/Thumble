import { useEffect, useState, useSyncExternalStore } from 'react';
import { Linking, ScrollView, Text, View, useWindowDimensions } from 'react-native';
import { router } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';
import { consolePortProfile, xboxProfile } from '@tapping/controller';
import { connection } from '../connection';
import { consolePortSyncView } from '../consoleport-sync';
import { testContext } from '../journey';
import { nativeGamepad, setupSignals } from '../onboarding-core';
import { useSetup } from '../use-setup';
import { BackButton, Button, Eyebrow, Lamp, colors, fonts, ui } from '../ui/design';

const LIGHTS = [
  { title: 'Paired with your computer', wait: 'Scan once, remembered after', done: 'Encrypted, on your home network' },
  { title: 'Gamepad live', wait: 'The receiver adds a virtual pad', done: 'Xbox-style controller ready' },
  { title: 'Labels for your game', wait: 'Spell sync for World of Warcraft, or button names', done: 'Labels ready' },
];
// WoW: Forever reads the gamepad natively, so there are no labels to sync.
const NATIVE_LIGHT = { title: 'Ready for WoW: Forever', wait: 'Built-in gamepad support', done: 'Built-in gamepad · no addons needed' };

export default function ConnectScreen() {
  const { state, save, error, setError } = useSetup();
  const network = useSyncExternalStore(connection.subscribe, connection.snapshot);
  const layout = useSyncExternalStore(connection.subscribeProfile, connection.profileSnapshot);
  const access = useSyncExternalStore(connection.subscribeAccess, connection.accessSnapshot);
  const online = network.phase === 'connected';
  const [catalog, setCatalog] = useState(null);
  const [busy, setBusy] = useState(false);
  const { width, height } = useWindowDimensions();
  const landscape = width > height;
  const context = testContext(access, layout);
  const sync = consolePortSyncView({ online, catalog, profile: layout.profile });
  const native = nativeGamepad(state);
  const lights3 = native ? [LIGHTS[0], LIGHTS[1], NATIVE_LIGHT] : LIGHTS;
  const { done, stage } = setupSignals({ state, online, recovering: connection.recovering, labelsFollowing: sync.following, context });

  useEffect(() => { connection.pausePlay(); }, []);
  useEffect(() => { if (state.loaded && online && !state.paired) void save({ paired: true }); }, [state.loaded, state.paired, online]); // eslint-disable-line react-hooks/exhaustive-deps
  // Poll the receiver while waiting for the first /reload. Make sure the
  // ConsolePort controller is active so the labels have somewhere to land
  // (WoW: Forever players get the Xbox-style controller instead).
  useEffect(() => {
    if (!online) return undefined;
    let active = true, pending = false;
    async function read() {
      if (!active || pending) return;
      pending = true;
      try {
        const result = await connection.requestProfiles();
        if (!active) return;
        setCatalog(result);
        if (connection.profileSnapshot().revision === 0) {
          const preset = nativeGamepad(state) ? xboxProfile : consolePortProfile;
          const standard = result.profiles.find(profile => profile.id === preset.id);
          if (standard) await connection.selectProfile(standard, result.activationRevision);
        }
      } catch (failure) { if (active) setError(failure.message); }
      finally { pending = false; }
    }
    void read();
    const timer = setInterval(() => { void read(); }, 4000);
    return () => { active = false; clearInterval(timer); };
  }, [online, setError, native]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    if (sync.following && context && state.wowSyncContext !== context) void save({ wowSyncStatus: 'confirmed', wowSyncContext: context });
  }, [sync.following, context, state.wowSyncContext]); // eslint-disable-line react-hooks/exhaustive-deps

  async function playForever() {
    setBusy(true);
    await save(previous => previous.wowClient === 'forever' ? {} : { wowClient: 'forever', consolePortReady: false, wowTested: false, wowChecks: {}, wowSyncStatus: '', wowSyncContext: '' });
    setBusy(false);
  }
  async function skipLabels() {
    setBusy(true);
    await save({ wowSyncStatus: 'skipped', wowSyncContext: context });
    setBusy(false);
  }
  function practice() { router.dismissTo('/'); }
  async function later() { if (await save({ dismissed: true })) router.dismissTo('/'); }

  const lights = <View style={{ gap: 8 }}>
    {lights3.map((light, index) => {
      const current = index === stage, on = done[index];
      return <View key={light.title} accessible accessibilityLabel={`${light.title}: ${on ? light.done : light.wait}`} style={[ui.card, { flexDirection: 'row', alignItems: 'center', gap: 12, padding: 10, ...(current ? {} : { boxShadow: 'none', transform: [{ translateX: 4 }, { translateY: 4 }] }), opacity: !on && !current ? 0.6 : 1 }]}>
        <Lamp state={on ? 'on' : current ? 'waiting' : 'off'} />
        <View style={{ flex: 1, gap: 1 }}><Text style={[ui.small, { fontFamily: fonts.bodyBold, fontSize: 14, color: colors.text }]}>{light.title}</Text><Text style={ui.muted}>{on ? light.done : light.wait}</Text></View>
      </View>;
    })}
  </View>;
  const detail = <View style={[ui.card, { flex: landscape ? 1 : 0, gap: 10 }]}>
    {stage === 0 && <>
      <Text style={ui.heading}>Scan the code on your computer</Text>
      <Text style={ui.muted}>Get Thumble Receiver from thumble.io, open it and choose Pair phone. Use the same Wi-Fi as this phone.</Text>
      <Button onPress={() => router.push('/pair?setup=1&returnTo=connect&scan=1')}>Scan pairing code</Button>
      <Button ghost compact onPress={() => router.push('/pair?setup=1&returnTo=connect')}>Paste invite link instead</Button>
    </>}
    {stage === 1 && <>
      <Eyebrow>Waiting on your computer…</Eyebrow>
      <Text style={[ui.heading, { fontSize: 22, lineHeight: 25 }]}>Thumble Receiver is plugging in your gamepad.</Text>
      <Text style={ui.muted}>{network.phase === 'connecting' ? 'Connecting securely…' : 'Open Thumble Receiver on your computer. Your computer sees an Xbox-style controller; a Mac may ask you to allow it once.'}</Text>
      {network.phase === 'offline' && <Button secondary compact onPress={() => { void connection.reconnect().catch(failure => setError(failure.message)); }}>Try again</Button>}
    </>}
    {stage === 2 && <>
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12 }}>
        <Text style={{ fontFamily: fonts.label, fontSize: 20, paddingHorizontal: 12, paddingVertical: 8, backgroundColor: colors.raised, color: colors.text, borderRadius: 8, overflow: 'hidden' }}>/reload</Text>
        <Text style={[ui.small, { flex: 1, fontFamily: fonts.bodyBold, fontSize: 15, lineHeight: 20, color: colors.text }]}>World of Warcraft? Type it in chat once your character has loaded.</Text>
      </View>
      <Text style={ui.label}>No labels? On your computer:</Text>
      <Text style={ui.muted}>1. Install ConsolePort and the Thumble addon in CurseForge{'\n'}2. Restart World of Warcraft and enable both at character select{'\n'}3. Another installation? Receiver → Choose World of Warcraft folder…</Text>
      <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
        <Button ghost compact onPress={() => { void Linking.openURL('https://www.curseforge.com/wow/addons/console-port'); }}>ConsolePort</Button>
        <Button ghost compact onPress={() => { void Linking.openURL('https://www.curseforge.com/wow/addons/thumble'); }}>Thumble addon</Button>
        <Button ghost compact disabled={busy || !context} onPress={skipLabels}>Play with button names</Button>
      </View>
      <Text style={ui.muted}>Not playing World of Warcraft? Choose Play with button names. WoW: Forever has built-in gamepad support, so it needs no addons.</Text>
      <Button secondary compact disabled={busy || !state.loaded} onPress={playForever}>I play WoW: Forever</Button>
      {!!sync.receiverDetail && <Text style={ui.small}>{sync.receiverDetail}</Text>}
    </>}
    {stage === 3 && <>
      <Eyebrow inverse>{!native && sync.character ? `${sync.character} · ConsolePort found` : 'All three lights on'}</Eyebrow>
      <Text style={[ui.heading, { fontSize: 26, lineHeight: 28 }]}>{native ? 'Your gamepad is live.' : 'Your controls are on your phone.'}</Text>
      <Text style={ui.muted}>Next, a one-minute practice run on the real controller. Stand somewhere quiet in game.</Text>
      {landscape && <Button onPress={practice} testID="connect-practice">Open controller</Button>}
    </>}
    {!!error && <Text accessibilityRole="alert" style={ui.error}>{error}</Text>}
  </View>;

  return <SafeAreaProvider><SafeAreaView style={{ flex: 1, backgroundColor: colors.background }}>
    <StatusBar style="dark" />
    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 10, minHeight: 44, paddingHorizontal: 20 }}>
      <BackButton onPress={() => router.canGoBack() ? router.back() : router.replace('/')} />
      <Text style={[ui.label, { flex: 1 }]}>SETUP · STEP {Math.min(stage + 1, 3)} OF 3</Text>
      <Button ghost compact onPress={later}>Later</Button>
    </View>
    {landscape ? <View style={{ flex: 1, flexDirection: 'row', gap: 20, padding: 20, paddingTop: 10 }}>
      <View style={{ width: 290, gap: 10 }}><Text accessibilityRole="header" style={[ui.title, { fontSize: 28, lineHeight: 30 }]}>Three lights and you’re in.</Text>{lights}</View>
      <ScrollView contentContainerStyle={{ flexGrow: 1 }}>{detail}</ScrollView>
    </View> : <ScrollView contentContainerStyle={{ padding: 20, paddingTop: 10, gap: 14, flexGrow: 1 }}>
      <Text accessibilityRole="header" style={[ui.title, { fontSize: 32, lineHeight: 33 }]}>Three lights and you’re in.</Text>
      {lights}
      {detail}
      <View style={{ flex: 1 }} />
      {stage === 3 && <Button onPress={practice} testID="connect-practice">Open controller</Button>}
    </ScrollView>}
  </SafeAreaView></SafeAreaProvider>;
}
