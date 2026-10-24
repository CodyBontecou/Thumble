import { useKeepAwake } from 'expo-keep-awake';
import { calibration } from './calibration';
import { connection } from './connection';
import { cloud } from './cloud/store';
import ControllerChat, { useControllerChat } from './ControllerChat';
import thumbleIcon from '../assets/thumble-menu.png';
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react';
import { Animated, AppState, Image, Linking, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { router, useFocusEffect } from 'expo-router';
import { SafeAreaProvider, SafeAreaView, useSafeAreaInsets } from 'react-native-safe-area-context';
import { StatusBar } from 'expo-status-bar';
import { TouchController, xboxProfile, modifierPrefix, controlDisplay } from '@tapping/controller';

const glyph = { up: '↑', down: '↓', left: '←', right: '→', back: '▧', start: '≡' };
// App Store v1 uses text and built-in symbols; no remote game artwork is loaded.
function ControlLabel({ label }) {
  return label === 'Unbound' ? null : <Text numberOfLines={2} adjustsFontSizeToFit minimumFontScale={0.55} style={s.buttonLabel}>{label}</Text>;
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
          {consolePort ? <ControlLabel label={display.label} /> : <Text numberOfLines={2} adjustsFontSizeToFit minimumFontScale={0.55} style={[s.buttonLabel, control.color && { color: control.color }, face && { fontSize: control.label.length > 3 ? 14 : 22 }, dpad && { fontSize: 22 }]}>{chatting ? display.label : control.label === xboxProfile.controls.find(item => item.id === control.id)?.label ? (glyph[control.id] ?? control.label) : control.label}</Text>}
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
          <Text style={s.detail}>Connect your Mac first, then follow these steps to prepare WoW and ConsolePort. You can test the controller locally before entering the game.</Text>
          {[
            ['1. Prepare your Mac', 'Install the receiver and connect both devices to the same Wi-Fi. Verify the virtual gamepad before starting WoW.'],
            ['2. Install ConsolePort', 'Select the Forever installation in CurseForge, install the matching addon release, then restart WoW and confirm the addon is enabled.'],
            ['3. Check in-game controls', 'Follow ConsolePort’s controller setup. Test movement, camera, targeting, jump and trigger modifiers. Configure your spells and actions in WoW.'],
          ].map(([title, detail]) => <View key={title} style={s.step}><Text style={s.stepTitle}>{title}</Text><Text style={s.detail}>{detail}</Text></View>)}
          <Pressable accessibilityRole="link" onPress={() => Linking.openURL('https://www.curseforge.com/wow/addons/console-port')} style={s.link}><Text style={s.action}>Open ConsolePort on CurseForge ↗</Text></Pressable>
        </ScrollView>
      </SafeAreaView></SafeAreaProvider>
  );
}

function Screen() {
  useKeepAwake();
  const insets = useSafeAreaInsets();
  const network = useSyncExternalStore(connection.subscribe, connection.snapshot);
  const access = useSyncExternalStore(connection.subscribeAccess, connection.accessSnapshot);
  const chat = useControllerChat(network);
  const pauseChat = chat.pause;
  const layout = useSyncExternalStore(connection.subscribeProfile, connection.profileSnapshot);
  const cloudState = useSyncExternalStore(cloud.subscribe, cloud.snapshot);
  const macAdoption = cloudState.macAdoption;
  const cloudSelection = network.phase === 'offline' ? cloudState.selected : null;
  const settings = useSyncExternalStore(calibration.subscribe, calibration.snapshot);
  const renderedProfile = useMemo(() => cloudSelection?.profile ?? (layout.revision === 0 ? calibration.standard(settings) : layout.profile), [cloudSelection, layout, settings]);
  const hasChatControl = renderedProfile.controls.some(control => control.id === 'chat');
  const [size, setSize] = useState({ width: 0, height: 0 });
  const [visuals] = useState(() => new Map());
  const [prefix, setPrefix] = useState('');
  const [focused, setFocused] = useState(true);
  const chatTouches = useRef(new Set());
  const [geometry] = useState(() => ({ x: 0, y: 0, width: 0, height: 0 }));
  const [controller] = useState(() => new TouchController(renderedProfile, {
    onState: state => { connection.submit(state); setPrefix(modifierPrefix(connection.snapshot().phase === 'offline' ? cloud.snapshot().selected?.profile ?? connection.profileSnapshot().profile : connection.profileSnapshot().profile, state)); },
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
    const subscription = AppState.addEventListener('change', phase => { if (phase !== 'active') controller.releaseAll(); });
    return () => { connection.resetListeners.delete(reset); subscription.remove(); controller.releaseAll(); };
  }, [controller]);
  useEffect(() => { controller.releaseAll(); }, [controller, network.phase]);
  useFocusEffect(useCallback(() => {
    setFocused(true);
    return () => { setFocused(false); pauseChat(); controller.releaseAll(); connection.pausePlay(); };
  }, [controller, pauseChat]));
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
      {!hasChatControl && <Pressable accessibilityRole="button" accessibilityLabel={chat.state === 'listening' ? 'Stop dictation' : 'Chat'} onPress={chat.toggle} style={[s.chatButton, { top: insets.top + 4 }]}><Text style={s.action}>{chat.state === 'listening' ? 'Stop' : 'Chat'}</Text></Pressable>}
      {network.phase === 'connected' && access && !access.enabled && <ScrollView style={s.demoOverlay} contentContainerStyle={s.demoContent}>
        <Text style={s.demoTitle}>{access.pro ? 'Ready to play' : access.remaining <= 0 ? 'Your demo has ended' : access.remaining >= 1799 ? 'Try the full controller' : 'Controller paused'}</Text>
        <Text style={s.demoDetail}>{access.pro ? 'Resume from neutral controls.' : access.remaining <= 0 ? 'Unlock Pro to keep playing without a time limit. All features are included in the demo.' : `${Math.ceil(access.remaining / 60)} minutes remaining across all sessions. Setup and practice are free. Controls stop when time runs out. No automatic charge.`}</Text>
        {!!access.error && <Text style={s.demoDetail}>{access.error}</Text>}
        {(access.pro || access.remaining > 0) && <Pressable accessibilityRole="button" style={[s.demoAction, s.demoPrimary]} onPress={() => connection.resumePlay()}><Text style={s.demoPrimaryText}>{access.pro || access.remaining < 1799 ? 'Resume controller' : 'Start 30-minute demo'}</Text></Pressable>}
        {!access.pro && <Pressable accessibilityRole="button" style={s.demoAction} onPress={() => router.push('/pro')}><Text style={s.action}>View Pro</Text></Pressable>}
        <Pressable accessibilityRole="button" style={s.demoAction} onPress={() => connection.disconnect()}><Text style={s.action}>Continue in practice mode</Text></Pressable>
      </ScrollView>}
      {network.phase === 'connected' && access?.enabled && !access.pro && <Text pointerEvents="none" style={s.demoRemaining}>{access.remaining <= 300 ? `Demo: ${Math.ceil(access.remaining / 60)} min left` : ''}</Text>}
      <Pressable accessibilityRole="button" accessibilityLabel="Thumble menu" testID="controller-menu"
        onPress={() => { controller.releaseAll(); router.push('/controller-menu'); }}
        style={({ pressed }) => [s.menuButton, { right: insets.right + 8, top: insets.top + 4 }, pressed && { opacity: 0.65 }]}>
        <Image source={thumbleIcon} style={s.menuIcon} accessible={false} />
      </Pressable>
    </SafeAreaView>
  );
}

export default function ControllerScreen() { return <SafeAreaProvider><Screen /></SafeAreaProvider>; }

const s = StyleSheet.create({
  demoOverlay: { position: 'absolute', alignSelf: 'center', top: '8%', bottom: '8%', width: '65%', maxWidth: 640, backgroundColor: '#141414', borderWidth: 1, borderColor: '#2E2E2E', borderRadius: 24, borderCurve: 'continuous' },
  demoContent: { padding: 24, gap: 12 },
  demoTitle: { color: '#EDEDED', fontSize: 28, letterSpacing: -0.6, fontWeight: '600' },
  demoDetail: { color: '#A1A1A1', fontSize: 14, lineHeight: 20 },
  demoAction: { minHeight: 48, borderRadius: 28, borderCurve: 'continuous', backgroundColor: '#1F1F1F', justifyContent: 'center', alignItems: 'center' },
  demoPrimary: { backgroundColor: '#EDEDED' },
  demoPrimaryText: { color: '#0A0A0A', fontSize: 16, fontWeight: '600' },
  demoRemaining: { position: 'absolute', bottom: 4, alignSelf: 'center', color: '#efdf9d', fontSize: 12, fontVariant: ['tabular-nums'] },
  screen: { flex: 1, backgroundColor: '#17191b' },
  action: { color: '#EDEDED', fontSize: 15, fontWeight: '600' },
  canvas: { flex: 1, marginHorizontal: 8 },
  control: { position: 'absolute', alignItems: 'center', justifyContent: 'center' },
  button: { borderRadius: 100, backgroundColor: '#292d31', borderWidth: 2, borderColor: '#393f44', alignItems: 'center', justifyContent: 'center' },
  consolePortButton: { borderWidth: 3, borderColor: '#77736b', backgroundColor: '#343537' },
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
  menuIcon: { width: 32, height: 32, borderRadius: 8 },
  setupContent: { padding: 24, gap: 24 },
  detail: { color: '#a5adb5', fontSize: 15, lineHeight: 22 },
  step: { gap: 6 },
  stepTitle: { color: '#f0f1f2', fontSize: 17, fontWeight: '600' },
  link: { padding: 16, borderRadius: 14, borderCurve: 'continuous', borderWidth: 1, borderColor: '#485144', alignSelf: 'flex-start' },
});
