import { AI_CONTROLLER_GENERATOR_ENABLED } from '../features';
import { useEffect, useSyncExternalStore } from 'react';
import { Image, Linking, Pressable, ScrollView, StyleSheet, Text, View, useWindowDimensions } from 'react-native';
import { router } from 'expo-router';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';
import { StatusBar } from 'expo-status-bar';
import config from '../../../../config/monetization.json';
import { connection } from '../connection';
import { cloud } from '../cloud/store';
import { purchases } from '../purchases/store';
import { onboarding } from '../onboarding';
import { Button, Meter, Row, colors, fonts, scheme, ui } from '../ui/design';
import thumbleIcon from '../../assets/icon.png';

const PLAN_NAMES = Object.fromEntries(Object.entries(config.products).map(([key, id]) => [id, key.replace('family', 'Family ').replace(/^./, letter => letter.toUpperCase())]));
const shortDate = ms => new Date(ms).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });

function planSummary(purchase, now = Date.now()) {
  if (!purchase.loaded) return { label: 'Checking your plan…', detail: 'Asking the store', filled: 0, total: 0 };
  if (purchase.status !== 'active') return { label: 'No active plan', detail: 'Choose a plan to keep playing.', filled: 0, total: 0 };
  const name = PLAN_NAMES[purchase.productId] ?? 'Plan';
  if (!purchase.expiresAt) return { label: `${name} · never expires`, detail: 'Thanks for supporting Thumble.', filled: 0, total: 0 };
  const left = Math.max(0, Math.ceil((purchase.expiresAt - now) / 86_400_000));
  if (purchase.inTrial) return { label: `${name} · free trial`, detail: `Trial ends ${shortDate(purchase.expiresAt)}${purchase.willRenew ? ', then your plan starts' : ''}`, filled: Math.max(0, config.trialDays - left), total: config.trialDays };
  return { label: name, detail: `${purchase.willRenew ? 'Renews' : 'Ends'} ${shortDate(purchase.expiresAt)}`, filled: 0, total: 0 };
}

export default function ControllerMenu() {
  const network = useSyncExternalStore(connection.subscribe, connection.snapshot);
  const layout = useSyncExternalStore(connection.subscribeProfile, connection.profileSnapshot);
  const cloudState = useSyncExternalStore(cloud.subscribe, cloud.snapshot);
  const purchase = useSyncExternalStore(purchases.subscribe, purchases.snapshot);
  // The store can answer before billing has connected at launch; ask again.
  useEffect(() => { void purchases.refresh(); }, []);
  const { width, height } = useWindowDimensions();
  const landscape = width > height;
  const online = network.phase === 'connected';
  const displayedProfile = AI_CONTROLLER_GENERATOR_ENABLED && network.phase === 'offline' ? cloudState.selected?.profile ?? layout.profile : layout.profile;
  const plan = planSummary(purchase);
  function close() { if (router.canGoBack()) router.back(); else router.replace('/'); }
  const items = [
    ['Edit layout', 'Move, resize, add and remap controls', '/layout-editor'],
    ['Controller settings', 'Layouts, WoW actions, label sync', '/controller-settings'],
    ['Stick calibration', 'Dead zone, invert look', '/calibration'],
    ['Controllers', displayedProfile.name, '/profiles'],
    ['Getting started', online ? 'Connected · set up WoW next' : 'Make it yours, connect, set up WoW', '/onboarding'],
    ['Replay the tour', 'Pick a preset, customize, connect', 'tour'],
    ['Plan & billing', plan.detail, '/pro'],
    ...(AI_CONTROLLER_GENERATOR_ENABLED ? [['AI to WoW', 'Connect your AI to a controller', '/journey'], ['Cloud controllers', 'Saved in your account', '/cloud']] : [['Cloud account', 'Sign in and manage your account', '/cloud']]),
  ];
  const status = <View style={[s.status, landscape ? { width: 290 } : {}]}>
    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 10 }}>
      <Image source={thumbleIcon} style={s.icon} accessible={false} />
      <View style={{ flex: 1 }}><Text style={{ fontFamily: fonts.bodyBold, fontSize: 17, color: colors.text }}>Thumble</Text><Text style={ui.muted}>Inputs released while open</Text></View>
    </View>
    <View style={s.tile}>
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}><View style={[s.dot, { backgroundColor: online ? colors.ok : network.phase === 'connecting' ? colors.warn : colors.grip }]} />
        <Text style={{ fontFamily: fonts.bodyBold, fontSize: 14, color: colors.text }}>{online ? `Computer${network.rtt != null ? ` · ${network.rtt} ms` : ' connected'}` : network.phase === 'connecting' ? 'Connecting…' : 'Not connected'}</Text></View>
      <Text numberOfLines={2} style={ui.muted}>{displayedProfile.name}{network.detail ? ` · ${network.detail}` : ''}</Text>
    </View>
    <View style={s.tile}>
      <Text style={{ fontFamily: fonts.bodyBold, fontSize: 14, color: colors.text }}>{plan.label}</Text>
      {plan.total > 0 && <Meter filled={plan.filled} total={plan.total} />}
      <Text style={ui.muted}>{plan.detail}</Text>
    </View>
    <View style={{ flex: landscape ? 1 : 0 }} />
    <Button onPress={close}>Back to WoW</Button>
  </View>;
  return <SafeAreaProvider><SafeAreaView style={[s.screen, landscape && { backgroundColor: 'rgba(0,0,0,0.55)' }]} accessibilityViewIsModal>
    <StatusBar hidden={landscape} style={scheme === 'light' ? 'dark' : 'light'} />
    {landscape && <Pressable style={StyleSheet.absoluteFill} accessibilityRole="button" accessibilityLabel="Dismiss Thumble menu" onPress={close} />}
    <View style={[s.panel, landscape ? s.panelLandscape : s.panelPortrait]}>
      {status}
      <ScrollView style={{ flex: 1 }} contentContainerStyle={{ gap: 10, paddingBottom: 4 }}>
        <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', minHeight: 28 }}>
          <Text style={ui.caption}>Menu</Text>
        </View>
        <View style={{ flexDirection: landscape ? 'row' : 'column', flexWrap: landscape ? 'wrap' : 'nowrap', gap: 10 }}>
          {items.map(([title, detail, path]) => <View key={path} style={landscape ? { width: '48%', flexGrow: 1 } : undefined}><Row title={title} detail={detail} onPress={() => path === 'tour' ? void onboarding.update({ tourDone: false, tourStage: '' }).then(() => router.replace('/')) : router.replace(path)} /></View>)}
        </View>
        <View style={{ flexDirection: 'row', gap: 10, flexWrap: 'wrap' }}>
          <Button ghost compact onPress={() => online ? (connection.disconnect(), close()) : router.replace('/pair?scan=1')}>{online ? 'Disconnect computer' : 'Connect computer'}</Button>
          <Button ghost compact onPress={() => { void Linking.openURL(config.supportURL); }}>Help</Button>
        </View>
      </ScrollView>
    </View>
  </SafeAreaView></SafeAreaProvider>;
}
const s = StyleSheet.create({
  screen: { flex: 1, backgroundColor: colors.background },
  panel: { flex: 1, gap: 16 },
  panelLandscape: { flexDirection: 'row', margin: 12, padding: 16, borderRadius: 22, borderCurve: 'continuous', backgroundColor: colors.background },
  panelPortrait: { padding: 16, paddingTop: 8 },
  status: { gap: 12 },
  tile: { padding: 12, gap: 6, borderRadius: 14, borderCurve: 'continuous', backgroundColor: colors.surface },
  dot: { width: 8, height: 8, borderRadius: 4 },
  icon: { width: 36, height: 36, borderRadius: 9 },
});
