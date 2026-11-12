import { AI_CONTROLLER_GENERATOR_ENABLED } from './features';
import { useKeepAwake } from 'expo-keep-awake';
import { calibration } from './calibration';
import { usesPhoneCalibration } from './consoleport-sync';
import { connection } from './connection';
import { cloud } from './cloud/store';
import { purchases } from './purchases/store';
import { useSetup } from './use-setup';
import { Button as ThumbleButton, fonts, pad } from './ui/design';
import Tour from './Tour';
import ControllerChat, { useControllerChat } from './ControllerChat';
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react';
import { Animated, AppState, Linking, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { router, useFocusEffect } from 'expo-router';
import { SafeAreaProvider, SafeAreaView, useSafeAreaInsets } from 'react-native-safe-area-context';
import { StatusBar } from 'expo-status-bar';
import { TouchController, xboxProfile, modifierPrefix, controlDisplay } from '@tapping/controller';

const glyph = { up: '↑', down: '↓', left: '←', right: '→', back: '▧', start: '≡' };
// Store builds show text labels only: no WoW spell or ConsolePort artwork.
function ControlLabel({ label }) {
  return label === 'Unbound' ? null : <Text numberOfLines={2} adjustsFontSizeToFit minimumFontScale={0.55} style={s.buttonLabel}>{label}</Text>;
}

export function ControlArtwork({ label, icon: _icon }) {
  return <ControlLabel label={label} />;
}

export function Control({ control, size, visuals, onAccessiblePress, profile, prefix, chatState }) {
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
  const rectangular = ['key', 'mouse', 'trackpad'].includes(control.type);
  const consolePort = profile.theme === 'consoleport' && !stick && !rectangular;
  return (
    <View pointerEvents="none" accessible accessibilityRole={stick ? 'adjustable' : 'button'}
      accessibilityLabel={display.label} accessibilityState={{ selected: pressed }}
      onAccessibilityTap={() => onAccessiblePress(control)}
      style={[s.control, { left: frame.x * size.width, top: frame.y * size.height, width, height }]}>
      {stick ? (
        <View style={[s.well, { width: diameter, height: diameter }, pressed && s.active]}>
          <Animated.View style={[s.cap, { width: diameter * 0.64, height: diameter * 0.64, transform: position.getTranslateTransform() }]}><View style={s.grip} /></Animated.View>
          <Text style={s.stickLabel}>{baseDisplay.label}</Text>
        </View>
      ) : (
        <View style={[s.button, { width: (shoulder && !consolePort) || rectangular ? width : diameter, height: (shoulder && !consolePort) || rectangular ? height : diameter }, ((shoulder && !consolePort) || rectangular) && s.shoulder, dpad && !consolePort && s.dpad, consolePort && s.consolePortButton, pressed && s.active, face && pressed && { borderColor: control.color }, chatting && s.chatActive]}>
          {consolePort ? <ControlArtwork key={`${display.icon ?? ''}:${display.label}`} label={display.label} icon={chatting ? undefined : display.icon} /> : <Text numberOfLines={2} adjustsFontSizeToFit minimumFontScale={0.55} style={[s.buttonLabel, control.color && { color: control.color }, face && { fontSize: control.label.length > 3 ? 14 : 22 }, dpad && { fontSize: 22 }]}>{chatting || control.customLabel ? display.label : control.label === xboxProfile.controls.find(item => item.id === control.id)?.label ? (glyph[control.id] ?? control.label) : control.label}</Text>}
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
          <Text style={s.detail}>Connect your computer first, then follow these steps to prepare World of Warcraft. WoW: Forever has built-in gamepad support; other versions use ConsolePort. You can test the controller locally before entering the game.</Text>
          {[
            ['1. Prepare your computer', 'Install the receiver and connect both devices to the same Wi-Fi. Verify the virtual gamepad before starting World of Warcraft.'],
            ['2. Install ConsolePort (not needed for WoW: Forever)', 'Select the World of Warcraft installation you play in CurseForge, install its matching ConsolePort release, then restart World of Warcraft and confirm the addon is enabled.'],
            ['3. Check in-game controls', 'Follow ConsolePort’s controller setup, or the Gamepad options in WoW: Forever. Test movement, camera, targeting, jump and trigger modifiers. Configure your spells and actions in World of Warcraft.'],
          ].map(([title, detail]) => <View key={title} style={s.step}><Text style={s.stepTitle}>{title}</Text><Text style={s.detail}>{detail}</Text></View>)}
          <Pressable accessibilityRole="link" onPress={() => Linking.openURL('https://www.curseforge.com/wow/addons/console-port')} style={s.link}><Text style={s.action}>Open ConsolePort on CurseForge ↗</Text></Pressable>
        </ScrollView>
      </SafeAreaView></SafeAreaProvider>
  );
}

function Screen({ tour = false }) {
  const coach = tour;
  const { state: setup, save: saveSetup } = useSetup();
  const [pill, setPill] = useState(/** @type {any} */ (null));
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
  const hasChatControl = renderedProfile.controls.some(control => control.id === 'chat');
  const [size, setSize] = useState({ width: 0, height: 0 });
  const [visuals] = useState(() => new Map());
  const [prefix, setPrefix] = useState('');
  const [focused, setFocused] = useState(false);
  const [appActive, setAppActive] = useState(AppState.currentState === 'active');
  // With a plan the receiver unlocks after verification; until then the
  // computer has not accepted this phone's plan. There is no free demo time.
  const exhausted = network.phase === 'connected' && access && !access.pro;
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
  }, [controller, network.phase]);
  useFocusEffect(useCallback(() => {
    setFocused(true);
    return () => { setFocused(false); pauseChat(); controller.releaseAll(); connection.pausePlay(); };
  }, [controller, pauseChat]));
  useEffect(() => {
    if (focused && appActive && network.phase === 'connected' && access && !access.enabled && !access.error && !connection.layoutPending && access.pro) {
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
    if (['stick', 'trackpad'].includes(control.type) || connection.layoutPending || connection.recovering || openChat(control)) return;
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
      {/* Chat sits in the reserved top-centre slot and the menu in the reserved
          top-right corner, so neither covers a control; the pill sits below. */}
      <View style={[s.chrome, { top: insets.top + 6, left: insets.left + 8, right: insets.right + 8 }]} pointerEvents="box-none">
        {!hasChatControl && <Pressable accessibilityRole="button" accessibilityLabel={chat.state === 'listening' ? 'Stop dictation' : 'Chat'} onPress={chat.toggle} style={({ pressed }) => [s.chip, s.chatChip, pressed && s.pressed]}><Text style={s.chipText}>{chat.state === 'listening' ? 'Stop' : 'Chat'}</Text></Pressable>}
        <Pressable accessibilityRole="button" accessibilityLabel="Thumble menu" testID="controller-menu"
          onPress={() => { controller.releaseAll(); router.push('/controller-menu'); }}
          style={({ pressed }) => [s.chip, s.menuChip, pressed && s.pressed]}><Text style={[s.chipText, { fontSize: 18 }]}>≡</Text></Pressable>
      </View>
      <View style={[s.pillRow, { top: insets.top + (hasChatControl ? 8 : 50), left: insets.left, right: insets.right }]} pointerEvents="box-none">
        <Pressable accessibilityRole="button" testID="controller-connection"
          accessibilityLabel={connected ? `Computer connected${network.rtt != null ? `, ${network.rtt} millisecond round trip` : ''}` : connecting ? 'Connecting to computer' : 'Computer disconnected'}
          accessibilityHint={connected ? undefined : 'Scan your computer’s QR code to connect'} disabled={connected || connecting}
          onPress={() => { controller.releaseAll(); router.push({ pathname: '/pair', params: { scan: '1' } }); }}
          onLayout={event => { const l = event.nativeEvent.layout; setPill({ x: insets.left + l.x, y: insets.top + (hasChatControl ? 8 : 50) + l.y, width: l.width, height: l.height }); }}
          style={({ pressed }) => [s.pill, pressed && s.pressed]}>
          <View style={[s.lamp, { backgroundColor: connected ? '#30D158' : connecting ? '#FFD60A' : '#8E8E93' }]} />
          <Text style={s.pillText}>{connected ? (network.rtt != null ? `Computer · ${network.rtt} ms` : 'Computer connected') : connecting ? 'Connecting…' : 'Not connected · tap to pair'}</Text>
        </Pressable>
      </View>
      {coach && focused && setup.loaded && <Tour state={setup} save={saveSetup} connected={connected} connecting={connecting} rtt={network.rtt ?? null} pill={pill} onRelease={() => controller.releaseAll()} />}
      {exhausted && !coach && <View style={s.overlay}><ScrollView style={s.card} contentContainerStyle={{ gap: 10 }} accessibilityViewIsModal>
        <Text style={[s.ovTag, { color: pad.y }]}>Plan not verified yet</Text>
        <Text style={s.ovTitle}>Your computer is waiting for your plan.</Text>
        <Text style={s.ovBody}>Thumble checks your plan with the store before your computer unlocks the controller. Make sure this phone is online, then retry.</Text>
        {!!access.error && <Text style={s.ovError}>{access.error}</Text>}
        <ThumbleButton onPress={() => { void purchases.refresh(); }}>Retry verification</ThumbleButton>
        <ThumbleButton secondary onPress={() => router.push('/pro')}>Plans and restore</ThumbleButton>
      </ScrollView></View>}
      {lost && !connected && !coach && <View style={s.overlay}><View style={s.card} accessibilityViewIsModal accessibilityRole="alert">
        <Text style={[s.ovTag, { color: connecting ? pad.y : pad.b }]}>{connecting ? 'Reconnecting…' : 'Connection lost'}</Text>
        <Text style={s.ovTitle}>Nothing is held. Your character has stopped.</Text>
        <Text style={s.ovBody}>Every button and stick was released the moment the link dropped, so your character has stopped. Check the receiver is open and both devices share Wi-Fi.</Text>
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

export default function ControllerScreen({ tour = false }) { return <SafeAreaProvider><Screen tour={tour} /></SafeAreaProvider>; }

export const controllerStyles = StyleSheet.create({
  chrome: { position: 'absolute', height: 40 },
  pillRow: { position: 'absolute', alignItems: 'center' },
  chatChip: { position: 'absolute', left: '50%', marginLeft: -26, width: 52, paddingHorizontal: 0 },
  pill: { flexDirection: 'row', alignItems: 'center', gap: 8, height: 32, paddingHorizontal: 12, borderRadius: 16, borderCurve: 'continuous', backgroundColor: 'rgba(118,118,128,0.24)' },
  lamp: { width: 7, height: 7, borderRadius: 4 },
  pillText: { fontFamily: fonts.bodyBold, fontSize: 12, color: pad.text },
  chip: { minWidth: 44, height: 34, paddingHorizontal: 12, borderRadius: 17, borderCurve: 'continuous', backgroundColor: 'rgba(118,118,128,0.24)', alignItems: 'center', justifyContent: 'center' },
  menuChip: { position: 'absolute', right: 0, width: 44 },
  chipText: { fontFamily: fonts.bodyBold, fontSize: 14, color: pad.text },
  pressed: { opacity: 0.6 },
  overlay: { position: 'absolute', top: 0, right: 0, bottom: 0, left: 0, backgroundColor: 'rgba(0,0,0,0.72)', alignItems: 'center', justifyContent: 'center', padding: 16 },
  card: { flexGrow: 0, width: '100%', maxWidth: 520, maxHeight: '100%', padding: 20, gap: 10, borderRadius: 20, borderCurve: 'continuous', backgroundColor: '#2C2C2E' },
  ovTag: { fontFamily: fonts.bodyBold, fontSize: 13, color: pad.ring },
  ovTitle: { fontFamily: fonts.bodyBold, fontSize: 24, lineHeight: 29, letterSpacing: -0.4, color: pad.text },
  ovBody: { fontFamily: fonts.body, fontSize: 14, lineHeight: 20, color: pad.muted },
  ovError: { fontFamily: fonts.bodyMedium, fontSize: 14, lineHeight: 20, color: pad.b },
  accessError: { position: 'absolute', bottom: 8, alignSelf: 'center', color: '#FF6961', fontSize: 12, fontFamily: fonts.bodyMedium },
  screen: { flex: 1, backgroundColor: pad.ground },
  action: { color: pad.text, fontSize: 15, fontFamily: fonts.bodyBold },
  canvas: { flex: 1, marginHorizontal: 8 },
  control: { position: 'absolute', alignItems: 'center', justifyContent: 'center' },
  button: { borderRadius: 100, backgroundColor: pad.key, borderWidth: 2, borderColor: 'transparent', alignItems: 'center', justifyContent: 'center' },
  consolePortButton: { borderWidth: 2, borderColor: '#48484A', backgroundColor: pad.key },
  badge: { position: 'absolute', top: -16, color: pad.y, fontSize: 12, fontFamily: fonts.bodyBold, backgroundColor: pad.ground, paddingHorizontal: 4, borderRadius: 4 },
  stickLabel: { position: 'absolute', bottom: 6, color: pad.muted, fontSize: 10, fontFamily: fonts.bodyMedium },
  active: { backgroundColor: pad.keyPressed, borderColor: pad.ring },
  shoulder: { borderRadius: 12, borderCurve: 'continuous' },
  dpad: { borderRadius: 9, borderCurve: 'continuous' },
  buttonLabel: { color: pad.text, fontSize: 13, fontFamily: fonts.bodyBold, textAlign: 'center' },
  well: { borderRadius: 100, backgroundColor: pad.well, alignItems: 'center', justifyContent: 'center' },
  cap: { borderRadius: 100, backgroundColor: pad.cap, alignItems: 'center', justifyContent: 'center', boxShadow: '0px 4px 12px rgba(0,0,0,0.4)' },
  grip: { width: '70%', height: '70%', borderRadius: 100, backgroundColor: 'rgba(255,255,255,0.06)' },
  chatActive: { borderColor: '#FF6961', backgroundColor: '#5A3226' },
  setupContent: { padding: 24, gap: 24 },
  detail: { color: pad.muted, fontSize: 15, lineHeight: 22, fontFamily: fonts.body },
  step: { gap: 6 },
  stepTitle: { color: pad.text, fontSize: 17, fontFamily: fonts.bodyBold },
  link: { padding: 16, borderRadius: 14, borderCurve: 'continuous', backgroundColor: pad.key, alignSelf: 'flex-start' },
});
const s = controllerStyles;
