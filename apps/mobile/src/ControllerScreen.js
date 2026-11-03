import { AI_CONTROLLER_GENERATOR_ENABLED } from './features';
import { useKeepAwake } from 'expo-keep-awake';
import { calibration } from './calibration';
import { usesPhoneCalibration } from './consoleport-sync';
import { connection } from './connection';
import { cloud } from './cloud/store';
import { purchases } from './purchases/store';
import { testContext } from './journey';
import { PRACTICE_STEPS } from './onboarding-core';
import { useSetup } from './use-setup';
import { Button as ThumbleButton, colors as thumble, fonts, ui } from './ui/design';
import ControllerChat, { useControllerChat } from './ControllerChat';
import thumbleIcon from '../assets/thumble-menu.png';
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react';
import { Animated, AppState, Image, Linking, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { router, useFocusEffect } from 'expo-router';
import { SafeAreaProvider, SafeAreaView, useSafeAreaInsets } from 'react-native-safe-area-context';
import { StatusBar } from 'expo-status-bar';
import { TouchController, xboxProfile, modifierPrefix, controlDisplay } from '@tapping/controller';

const glyph = { up: '↑', down: '↓', left: '←', right: '→', back: '▧', start: '≡' };
export const utilityArtwork = {
  cp_jump: require('../assets/consoleport/Jump.png'),
  cp_interact: require('../assets/consoleport/Target_Wide_Neutral.png'),
  cp_target: require('../assets/consoleport/Target_Wide_Enemy.png'),
  cp_bags: require('../assets/consoleport/Bags.png'),
  cp_map: require('../assets/consoleport/Map.png'),
  cp_menu: require('../assets/consoleport/Menu.png'),
};
// Profiles carry icon names, never arbitrary remote URLs.
const spellArtworkUri = icon => typeof icon === 'string' && /^[a-z0-9_]{1,128}$/.test(icon) && !icon.startsWith('cp_') ? `https://wow.zamimg.com/images/wow/icons/large/${icon}.jpg` : null;
function ControlLabel({ label }) {
  return label === 'Unbound' ? null : <Text numberOfLines={2} adjustsFontSizeToFit minimumFontScale={0.55} style={s.buttonLabel}>{label}</Text>;
}

export function ControlArtwork({ label, icon }) {
  const [loaded, setLoaded] = useState(false);
  const [failed, setFailed] = useState(false);
  const uri = spellArtworkUri(icon);
  const source = utilityArtwork[icon] ?? (uri ? { uri } : null);
  if (label === 'Unbound') return null;
  if (!source || failed) return <ControlLabel label={label} />;
  return <View style={s.artwork}>
    <Image accessible={false} source={source} resizeMode="cover" fadeDuration={0}
      onLoad={() => setLoaded(true)} onError={() => setFailed(true)}
      style={[s.artworkImage, !loaded && { opacity: 0 }]} />
    {!loaded && <ControlLabel label={label} />}
  </View>;
}

function Control({ control, size, visuals, onAccessiblePress, profile, prefix, chatState }) {
  const [pressed, setPressed] = useState(false);
  const [position] = useState(() => new Animated.ValueXY());
  const { frame } = control;
  const width = frame.width * size.width;
  const height = frame.height * size.height;
  const diameter = Math.min(width, height);
  useEffect(() => {
    visuals.set(control.id, value => {
      setPressed(value.pressed);
      position.setValue({ x: value.x * diameter * 0.24, y: -value.y * diameter * 0.24 });
    });
    return () => visuals.delete(control.id);
  }, [control.id, diameter, position, visuals]);
  const stick = control.type === 'stick';
  const shoulder = control.type === 'trigger' || ['lb', 'rb'].includes(control.id);
  const dpad = ['up', 'down', 'left', 'right'].includes(control.id);
  const face = ['a', 'b', 'x', 'y'].includes(control.id);
  const baseDisplay = controlDisplay(control, prefix, profile);
  const chatting = control.id === 'chat' && chatState !== 'idle';
  const display = chatting ? { ...baseDisplay, label: chatState === 'listening' ? 'Stop' : chatState === 'finishing' ? 'Finishing…' : 'Cancel' } : baseDisplay;
  const consolePort = profile.theme === 'consoleport' && !stick;
  return (
    <View pointerEvents="none" accessible accessibilityRole={stick ? 'adjustable' : 'button'}
      accessibilityLabel={display.label} accessibilityState={{ selected: pressed }}
      onAccessibilityTap={() => onAccessiblePress(control)}
      style={[s.control, { left: frame.x * size.width, top: frame.y * size.height, width, height }]}>
      {stick ? (
        <View style={[s.well, { width: diameter, height: diameter }, pressed && s.active]}>
          <Animated.View style={[s.cap, { width: diameter * 0.64, height: diameter * 0.64, transform: position.getTranslateTransform() }]}><View style={s.grip} /></Animated.View>
          <Text style={s.stickLabel}>{control.label}</Text>
        </View>
      ) : (
        <View style={[s.button, { width: shoulder && !consolePort ? width : diameter, height: shoulder && !consolePort ? height : diameter }, shoulder && !consolePort && s.shoulder, dpad && !consolePort && s.dpad, consolePort && s.consolePortButton, pressed && s.active, face && pressed && { borderColor: control.color }, chatting && s.chatActive]}>
          {consolePort ? <ControlArtwork key={`${display.icon ?? ''}:${display.label}`} label={display.label} icon={chatting ? undefined : display.icon} /> : <Text numberOfLines={2} adjustsFontSizeToFit minimumFontScale={0.55} style={[s.buttonLabel, control.color && { color: control.color }, face && { fontSize: control.label.length > 3 ? 14 : 22 }, dpad && { fontSize: 22 }]}>{chatting ? display.label : control.label === xboxProfile.controls.find(item => item.id === control.id)?.label ? (glyph[control.id] ?? control.label) : control.label}</Text>}
          {consolePort && <Text style={[s.badge, control.color && { color: control.color }]}>{control.badge}</Text>}
        </View>
      )}
    </View>
  );
}

export function WowSetupScreen() {
  return (
      <SafeAreaProvider><SafeAreaView style={s.screen} edges={['left', 'right', 'bottom']} accessibilityViewIsModal>
        <ScrollView contentContainerStyle={s.setupContent}>
          <Text style={s.detail}>Connect your computer first, then follow these steps to prepare WoW and ConsolePort. You can test the controller locally before entering the game.</Text>
          {[
            ['1. Prepare your computer', 'Install the receiver and connect both devices to the same Wi-Fi. Verify the virtual gamepad before starting WoW.'],
            ['2. Install ConsolePort', 'Select the WoW installation you play in CurseForge, install its matching ConsolePort release, then restart WoW and confirm the addon is enabled.'],
            ['3. Check in-game controls', 'Follow ConsolePort’s controller setup. Test movement, camera, targeting, jump and trigger modifiers. Configure your spells and actions in WoW.'],
          ].map(([title, detail]) => <View key={title} style={s.step}><Text style={s.stepTitle}>{title}</Text><Text style={s.detail}>{detail}</Text></View>)}
          <Pressable accessibilityRole="link" onPress={() => Linking.openURL('https://www.curseforge.com/wow/addons/console-port')} style={s.link}><Text style={s.action}>Open ConsolePort on CurseForge ↗</Text></Pressable>
        </ScrollView>
      </SafeAreaView></SafeAreaProvider>
  );
}

function Screen({ coach = false }) {
  useKeepAwake();
  const insets = useSafeAreaInsets();
  const network = useSyncExternalStore(connection.subscribe, connection.snapshot);
  const connected = network.phase === 'connected';
  const connecting = network.phase === 'connecting';
  const access = useSyncExternalStore(connection.subscribeAccess, connection.accessSnapshot);
  const chat = useControllerChat(network);
  const pauseChat = chat.pause;
  const layout = useSyncExternalStore(connection.subscribeProfile, connection.profileSnapshot);
  const cloudState = useSyncExternalStore(cloud.subscribe, cloud.snapshot);
  const macAdoption = AI_CONTROLLER_GENERATOR_ENABLED ? cloudState.macAdoption : null;
  const cloudSelection = AI_CONTROLLER_GENERATOR_ENABLED && network.phase === 'offline' ? cloudState.selected : null;
  const settings = useSyncExternalStore(calibration.subscribe, calibration.snapshot);
  const renderedProfile = useMemo(() => cloudSelection?.profile ?? (layout.revision === 0 || usesPhoneCalibration(layout.profile) ? calibration.standard(settings, layout.profile) : layout.profile), [cloudSelection, layout, settings]);
  useEffect(() => {
    const icons = new Set(renderedProfile.controls.flatMap(control => [control.icon, ...Object.values(control.layers ?? {}).map(layer => layer.icon)]));
    for (const icon of icons) {
      const uri = spellArtworkUri(icon);
      if (uri) void Image.prefetch(uri).catch(() => {});
    }
  }, [renderedProfile]);
  const hasChatControl = renderedProfile.controls.some(control => control.id === 'chat');
  const [size, setSize] = useState({ width: 0, height: 0 });
  const [visuals] = useState(() => new Map());
  const [prefix, setPrefix] = useState('');
  const [focused, setFocused] = useState(false);
  const [appActive, setAppActive] = useState(AppState.currentState === 'active');
  const [demoUsed, setDemoUsed] = useState(0);
  const remaining = access?.remaining ?? Math.max(0, 1800 - demoUsed);
  // With a plan the receiver unlocks after verification; an exhausted meter
  // means the computer has not accepted this phone's plan yet.
  const exhausted = network.phase === 'connected' && access && !access.pro && remaining <= 0;
  const [lost, setLost] = useState(false);
  const wasConnected = useRef(false);
  // Only a dropped link counts as lost; a remembered pairing means it was not a disconnect.
  useEffect(() => connection.subscribe(() => {
    const phase = connection.snapshot().phase;
    if (phase === 'connected') { wasConnected.current = true; setLost(false); }
    else if (phase === 'offline' && wasConnected.current && connection.remembered) { wasConnected.current = false; setLost(true); }
  }), []);
  const chatTouches = useRef(new Set());
  const [geometry] = useState(() => ({ x: 0, y: 0, width: 0, height: 0 }));
  const [controller] = useState(() => new TouchController(renderedProfile, {
    onState: (state, profile) => { connection.submit(state); setPrefix(modifierPrefix(profile, state)); },
    onVisual: (id, value) => visuals.get(id)?.(value),
  }));
  function openChat(control) {
    if (control.type !== 'button' || control.id !== 'chat') return false;
    chat.toggle();
    return true;
  }
  useLayoutEffect(() => {
    controller.releaseAll();
    controller.replaceProfile(renderedProfile);
    connection.acknowledgeLayout(layout.revision);
  }, [controller, layout, renderedProfile]);
  useEffect(() => {
    if (cloudSelection && focused && size.width > 0 && cloudState.foreground) void cloud.rendered(cloudSelection);
  }, [cloudSelection, focused, size.width, cloudState.foreground, cloudState.renderAttempt]);
  useEffect(() => {
    if (macAdoption && focused && size.width > 0 && network.phase === 'connected' && connection.session === macAdoption.pairing && layout.profile.id === macAdoption.profileId && layout.revision === macAdoption.activationRevision && !connection.layoutPending && !connection.recovering) {
      void cloud.rendered(macAdoption.selection, macAdoption);
    }
  }, [macAdoption, focused, size.width, layout, network, cloudState.renderAttempt]);
  useEffect(() => {
    const reset = () => { chatTouches.current.clear(); controller.releaseAll(); };
    connection.resetListeners.add(reset);
    const subscription = AppState.addEventListener('change', phase => {
      setAppActive(phase === 'active');
      if (phase !== 'active') { controller.releaseAll(); connection.pausePlay(); }
    });
    return () => { connection.resetListeners.delete(reset); subscription.remove(); controller.releaseAll(); };
  }, [controller]);
  useEffect(() => {
    controller.releaseAll();
    let current = true;
    void purchases.demoUsed().then(used => { if (current) setDemoUsed(used); }).catch(() => {});
    return () => { current = false; };
  }, [controller, network.phase]);
  useFocusEffect(useCallback(() => {
    setFocused(true);
    let current = true;
    void purchases.demoUsed().then(used => { if (current) setDemoUsed(used); }).catch(() => {});
    return () => { current = false; setFocused(false); pauseChat(); controller.releaseAll(); connection.pausePlay(); };
  }, [controller, pauseChat]));
  useEffect(() => {
    if (focused && appActive && network.phase === 'connected' && access && !access.enabled && !access.error && !connection.layoutPending && (access.pro || access.remaining > 0)) {
      controller.releaseAll();
      connection.resumePlay();
    }
  }, [focused, appActive, network.phase, network.detail, access, layout.revision, controller]);
  function touch(method, event) {
    if (!geometry.width || !geometry.height || connection.layoutPending || connection.recovering) return;
    connection.withTouch(() => {
    for (const item of event.nativeEvent.changedTouches) {
      if (chatTouches.current.has(item.identifier)) {
        if (method === 'up') chatTouches.current.delete(item.identifier);
        continue;
      }
      if (method === 'up') controller.up(item.identifier);
      else {
        const x = (item.pageX - geometry.x) / geometry.width, y = (item.pageY - geometry.y) / geometry.height;
        const hit = method === 'down' && [...renderedProfile.controls].reverse().find(control => x >= control.frame.x && x <= control.frame.x + control.frame.width && y >= control.frame.y && y <= control.frame.y + control.frame.height);
        if (hit && openChat(hit)) { chatTouches.current.add(item.identifier); continue; }
        controller[method](item.identifier, x, y);
      }
    }
    });
  }
  function accessiblePress(control) {
    if (control.type === 'stick' || connection.layoutPending || connection.recovering || openChat(control)) return;
    const id = `accessible-${control.id}`;
    controller.down(id, control.frame.x + control.frame.width / 2, control.frame.y + control.frame.height / 2);
    setTimeout(() => controller.up(id), 80);
  }
  return (
    <SafeAreaView style={s.screen} pointerEvents={focused ? 'auto' : 'none'} accessibilityElementsHidden={!focused} importantForAccessibility={focused ? 'auto' : 'no-hide-descendants'}>
      <StatusBar hidden />
      <View style={s.canvas} onLayout={event => { controller.setViewport(event.nativeEvent.layout.width, event.nativeEvent.layout.height); cloud.setViewport(event.nativeEvent.layout); setSize(event.nativeEvent.layout); const target = event.currentTarget; if (typeof target !== 'number') target.measureInWindow((x, y, width, height) => Object.assign(geometry, { x, y, width, height })); }}
        onStartShouldSetResponder={() => true}
        onResponderGrant={event => touch('down', event)} onResponderStart={event => touch('down', event)}
        onResponderMove={event => touch('move', event)} onResponderEnd={event => touch('up', event)}
        onResponderTerminationRequest={() => false}
        onResponderRelease={() => { chatTouches.current.clear(); controller.releaseAll(); }} onResponderTerminate={() => { chatTouches.current.clear(); controller.releaseAll(); }}>
        {size.width > 0 && renderedProfile.controls.map(control => <Control key={`${cloudSelection ? `cloud-${cloudSelection.profile.id}-${cloudSelection.revision}` : layout.revision}-${control.id}`} control={control} size={size} visuals={visuals} onAccessiblePress={accessiblePress} profile={renderedProfile} prefix={prefix} chatState={chat.state} />)}
      </View>
      <ControllerChat chat={chat} network={network} top={insets.top + (hasChatControl ? 8 : 52)} />
      {!coach && <View style={[s.chrome, { top: insets.top + 6, left: insets.left + 12, right: insets.right + 12 }]} pointerEvents="box-none">
        <Pressable accessibilityRole="button" testID="controller-connection"
          accessibilityLabel={connected ? `Computer connected${network.rtt != null ? `, ${network.rtt} millisecond round trip` : ''}` : connecting ? 'Connecting to computer' : 'Computer disconnected'}
          accessibilityHint={connected ? undefined : 'Scan your computer’s QR code to connect'} disabled={connected || connecting}
          onPress={() => { controller.releaseAll(); router.push({ pathname: '/pair', params: { scan: '1' } }); }}
          style={({ pressed }) => [s.pill, pressed && s.pressed]}>
          <Image source={thumbleIcon} style={s.pillIcon} accessible={false} />
          <View style={[s.lamp, { backgroundColor: connected ? thumble.accent : connecting ? thumble.surface : thumble.grip }]} />
          <Text style={s.pillText}>{connected ? (network.rtt != null ? `${network.rtt} MS RTT` : 'CONNECTED') : connecting ? 'CONNECTING' : 'OFFLINE'}</Text>
        </Pressable>
        <View style={{ flexDirection: 'row', gap: 8 }}>
          {!hasChatControl && <Pressable accessibilityRole="button" accessibilityLabel={chat.state === 'listening' ? 'Stop dictation' : 'Chat'} onPress={chat.toggle} style={({ pressed }) => [s.chip, pressed && s.pressed]}><Text style={s.chipText}>{chat.state === 'listening' ? 'Stop' : 'Chat'}</Text></Pressable>}
          <Pressable accessibilityRole="button" accessibilityLabel="Thumble menu" testID="controller-menu"
            onPress={() => { controller.releaseAll(); router.push('/controller-menu'); }}
            style={({ pressed }) => [s.chip, s.menuChip, pressed && s.pressed]}><Text style={s.chipText}>≡</Text></Pressable>
        </View>
      </View>}
      {coach && focused && <Coach profile={renderedProfile} size={size} insets={insets} online={connected} access={access} layout={layout} />}
      {exhausted && !coach && <View style={s.overlay}><ScrollView style={s.card} contentContainerStyle={{ gap: 10 }} accessibilityViewIsModal>
        <Text style={ui.label}>PLAN NOT VERIFIED YET</Text>
        <Text style={[ui.title, { fontSize: 26, lineHeight: 28 }]}>Your computer is waiting for your plan.</Text>
        <Text style={ui.muted}>Thumble checks your plan with the store before your computer unlocks the controller. Make sure this phone is online, then retry.</Text>
        {!!access.error && <Text style={ui.error}>{access.error}</Text>}
        <ThumbleButton onPress={() => { void purchases.refresh(); }}>Retry verification</ThumbleButton>
        <ThumbleButton secondary onPress={() => router.push('/pro')}>Plans and restore</ThumbleButton>
      </ScrollView></View>}
      {lost && !connected && !coach && <View style={s.overlay}><View style={s.card} accessibilityViewIsModal accessibilityRole="alert">
        <Text style={ui.label}>{connecting ? 'RECONNECTING…' : 'CONNECTION LOST'}</Text>
        <Text style={[ui.title, { fontSize: 28, lineHeight: 30 }]}>Connection lost. Nothing is held.</Text>
        <Text style={ui.muted}>Every button and stick was released the moment the link dropped, so your character has stopped. Check the receiver is open and both devices share Wi-Fi.</Text>
        <View style={{ flexDirection: 'row', gap: 10, flexWrap: 'wrap' }}>
          <ThumbleButton compact disabled={connecting} onPress={() => { void connection.reconnect().catch(() => {}); }}>Try again now</ThumbleButton>
          <ThumbleButton compact secondary onPress={() => { setLost(false); router.push({ pathname: '/pair', params: { scan: '1' } }); }}>Pair again</ThumbleButton>
          <ThumbleButton compact ghost onPress={() => setLost(false)}>Practice offline</ThumbleButton>
        </View>
      </View></View>}
      {network.phase === 'connected' && !!access?.error && !exhausted && <Text accessibilityRole="alert" style={s.accessError}>{access.error}</Text>}
    </SafeAreaView>
  );
}

export default function ControllerScreen({ coach = false }) { return <SafeAreaProvider><Screen coach={coach} /></SafeAreaProvider>; }

// The coached practice run: five prompts with the matching control ringed.
// Finishing records the same milestones as the former in-game checklist.
const coachTargets = { movement: ['left-stick'], camera: ['right-stick'], action: ['a'], modifier: ['modifier', 'a'], menu: ['start'] };
function Coach({ profile, size, insets, online, access, layout }) {
  const { state, save } = useSetup();
  const [index, setIndex] = useState(0);
  const [help, setHelp] = useState(false);
  const [error, setError] = useState('');
  const step = PRACTICE_STEPS[index];
  const modifier = profile.theme === 'consoleport' && profile.modifiers === undefined ? 'lt' : Object.values(profile.modifiers ?? {}).find(key => key !== 'none') ?? 'lt';
  const rings = step ? coachTargets[step.id].map(id => profile.controls.find(control => control.id === (id === 'modifier' ? modifier : id))).filter(Boolean) : [];
  async function next() {
    setHelp(false);
    if (index + 1 < PRACTICE_STEPS.length) { setIndex(index + 1); return; }
    const controlKey = testContext(access, layout), wowKey = testContext(access, layout, state.wowClient);
    if (!online || !controlKey) { setError('Connect your computer, then finish the last step again.'); return; }
    const saved = await save({ paired: true, controlsTested: true, controlsCheckContext: controlKey, wowTested: true, personalized: true, consolePortReady: true,
      wowChecks: Object.fromEntries(PRACTICE_STEPS.map(item => [item.id, true])), wowCheckContext: wowKey });
    if (saved) setIndex(PRACTICE_STEPS.length);
  }
  return <>
    {size.width > 0 && rings.map(control => {
      const w = control.frame.width * size.width, h = control.frame.height * size.height, d = Math.min(w, h) + 16;
      return <View key={control.id} pointerEvents="none" style={[s.ring, { left: 8 + insets.left + control.frame.x * size.width + w / 2 - d / 2, top: insets.top + control.frame.y * size.height + h / 2 - d / 2, width: d, height: d, borderRadius: d / 2 }]} />;
    })}
    <View style={[s.coach, { top: insets.top + 4, left: insets.left + 12, right: insets.right + 12 }]} accessibilityLiveRegion="polite">
      <Text style={s.coachTag}>{step ? `PRACTICE ${index + 1}/${PRACTICE_STEPS.length}` : '5/5'}</Text>
      <Text numberOfLines={2} style={s.coachText}>{error || (step ? (help ? step.fix : step.title) : 'You’re ready to play.')}</Text>
      {step ? <>
        <ThumbleButton compact ghost onPress={() => setHelp(!help)}>{help ? 'Back' : 'Not quite'}</ThumbleButton>
        <ThumbleButton compact onPress={next}>It worked</ThumbleButton>
        <Pressable accessibilityRole="button" onPress={() => { void save({ dismissed: true }).then(() => router.setParams({ practice: undefined })); }} style={{ minHeight: 44, justifyContent: 'center' }}><Text style={ui.label}>SKIP</Text></Pressable>
      </> : <ThumbleButton compact onPress={() => router.setParams({ practice: undefined })}>Go to controller</ThumbleButton>}
    </View>
  </>;
}

export const controllerStyles = StyleSheet.create({
  chrome: { position: 'absolute', height: 40, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  pill: { flexDirection: 'row', alignItems: 'center', gap: 8, height: 34, paddingLeft: 3, paddingRight: 10, borderRadius: 4, borderWidth: 2, borderColor: thumble.border, backgroundColor: thumble.surface, boxShadow: '2px 2px 0px #000000' },
  pillIcon: { width: 24, height: 24, borderRadius: 2 },
  lamp: { width: 10, height: 10, borderWidth: 2, borderColor: thumble.border },
  pillText: { fontFamily: fonts.label, fontSize: 11, color: thumble.text },
  chip: { minWidth: 44, height: 34, paddingHorizontal: 12, borderRadius: 4, borderWidth: 2, borderColor: thumble.border, backgroundColor: thumble.surface, alignItems: 'center', justifyContent: 'center', boxShadow: '2px 2px 0px #000000' },
  menuChip: { backgroundColor: thumble.accent },
  chipText: { fontFamily: fonts.pixel, fontSize: 15, color: thumble.text },
  pressed: { transform: [{ translateX: 2 }, { translateY: 2 }], boxShadow: 'none' },
  overlay: { position: 'absolute', top: 0, right: 0, bottom: 0, left: 0, backgroundColor: 'rgba(23,25,27,0.72)', alignItems: 'center', justifyContent: 'center', padding: 16 },
  card: { flexGrow: 0, width: '100%', maxWidth: 520, maxHeight: '100%', padding: 18, gap: 10, borderRadius: 6, borderWidth: 3, borderColor: thumble.border, backgroundColor: thumble.surface, boxShadow: '6px 6px 0px #000000' },
  coach: { position: 'absolute', minHeight: 48, flexDirection: 'row', alignItems: 'center', gap: 10, paddingHorizontal: 10, paddingVertical: 4, borderRadius: 4, borderWidth: 3, borderColor: thumble.border, backgroundColor: thumble.surface, boxShadow: '3px 3px 0px #000000' },
  coachTag: { fontFamily: fonts.label, fontSize: 11, color: thumble.accent, backgroundColor: thumble.text, paddingHorizontal: 6, paddingVertical: 3, overflow: 'hidden' },
  coachText: { flex: 1, fontFamily: fonts.bodyBold, fontSize: 14, lineHeight: 18, color: thumble.text },
  ring: { position: 'absolute', borderWidth: 4, borderColor: thumble.accent, outlineWidth: 2, outlineColor: thumble.surface, outlineStyle: 'solid' },
  demoOverlay: { position: 'absolute', alignSelf: 'center', top: '8%', bottom: '8%', width: '65%', maxWidth: 640, backgroundColor: '#141414', borderWidth: 1, borderColor: '#2E2E2E', borderRadius: 24, borderCurve: 'continuous' },
  demoContent: { padding: 24, gap: 12 },
  demoTitle: { color: '#EDEDED', fontSize: 28, letterSpacing: -0.6, fontWeight: '600' },
  demoDetail: { color: '#A1A1A1', fontSize: 14, lineHeight: 20 },
  demoAction: { minHeight: 48, borderRadius: 28, borderCurve: 'continuous', backgroundColor: '#1F1F1F', justifyContent: 'center', alignItems: 'center' },
  demoPrimary: { backgroundColor: '#EDEDED' },
  demoPrimaryText: { color: '#0A0A0A', fontSize: 16, fontWeight: '600' },
  timerButton: { position: 'absolute', minWidth: 64, minHeight: 44, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 8 },
  timerText: { color: '#a5adb5', fontSize: 14, fontWeight: '500', fontVariant: ['tabular-nums'] },
  timerLow: { color: '#efdf9d' },
  accessError: { position: 'absolute', bottom: 8, alignSelf: 'center', color: '#F1A59F', fontSize: 12 },
  screen: { flex: 1, backgroundColor: '#17191b' },
  action: { color: '#EDEDED', fontSize: 15, fontWeight: '600' },
  canvas: { flex: 1, marginHorizontal: 8 },
  control: { position: 'absolute', alignItems: 'center', justifyContent: 'center' },
  button: { borderRadius: 100, backgroundColor: '#292d31', borderWidth: 2, borderColor: '#393f44', alignItems: 'center', justifyContent: 'center' },
  consolePortButton: { borderWidth: 3, borderColor: '#77736b', backgroundColor: '#343537' },
  artwork: { width: '100%', height: '100%', borderRadius: 100, overflow: 'hidden', alignItems: 'center', justifyContent: 'center' },
  artworkImage: { position: 'absolute', width: '100%', height: '100%' },
  badge: { position: 'absolute', top: -16, color: '#efdf9d', fontSize: 12, fontWeight: '800', backgroundColor: '#17191b', paddingHorizontal: 4, borderRadius: 4 },
  stickLabel: { position: 'absolute', bottom: 5, color: '#a5adb5', fontSize: 10 },
  active: { backgroundColor: '#414a43', borderColor: '#b8e09e' },
  shoulder: { borderRadius: 14, borderCurve: 'continuous', backgroundColor: '#24282b' },
  dpad: { borderRadius: 9, borderCurve: 'continuous' },
  buttonLabel: { color: '#c8cdd2', fontSize: 13, fontWeight: '700', textAlign: 'center' },
  well: { borderRadius: 100, backgroundColor: '#111315', borderWidth: 2, borderColor: '#32383d', alignItems: 'center', justifyContent: 'center' },
  cap: { borderRadius: 100, backgroundColor: '#33383d', borderWidth: 2, borderColor: '#4b5259', alignItems: 'center', justifyContent: 'center' },
  grip: { width: '72%', height: '72%', borderRadius: 100, borderWidth: 1, borderColor: '#41484f', backgroundColor: '#292e33' },
  chatActive: { borderColor: '#efb0a3', backgroundColor: '#5a3430' },
  chatButton: { position: 'absolute', alignSelf: 'center', minWidth: 52, height: 44, alignItems: 'center', justifyContent: 'center' },
  menuButton: { position: 'absolute', width: 44, height: 44, alignItems: 'center', justifyContent: 'center' },
  connectionButton: { position: 'absolute', width: 44, height: 44, alignItems: 'center', justifyContent: 'center' },
  connectionDot: { width: 8, height: 8, borderRadius: 4 },
  connectionOnline: { backgroundColor: '#b8e09e', boxShadow: '0 0 8px 2px rgba(184, 224, 158, 0.45)' },
  connectionPending: { backgroundColor: '#efdf9d', boxShadow: '0 0 8px 2px rgba(239, 223, 157, 0.35)' },
  connectionOffline: { backgroundColor: '#F1A59F', boxShadow: '0 0 8px 2px rgba(241, 165, 159, 0.35)' },
  menuIcon: { width: 32, height: 32, borderRadius: 8 },
  setupContent: { padding: 24, gap: 24 },
  detail: { color: '#a5adb5', fontSize: 15, lineHeight: 22 },
  step: { gap: 6 },
  stepTitle: { color: '#f0f1f2', fontSize: 17, fontWeight: '600' },
  link: { padding: 16, borderRadius: 14, borderCurve: 'continuous', borderWidth: 1, borderColor: '#485144', alignSelf: 'flex-start' },
});
const s = controllerStyles;
