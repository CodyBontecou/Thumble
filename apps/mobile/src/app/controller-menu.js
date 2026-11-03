import { AI_CONTROLLER_GENERATOR_ENABLED } from '../features';
import { useSyncExternalStore } from 'react';
import { Image, Linking, Pressable, ScrollView, StyleSheet, Text, View, useWindowDimensions } from 'react-native';
import { router } from 'expo-router';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';
import { StatusBar } from 'expo-status-bar';
import config from '../../../../config/monetization.json';
import { connection } from '../connection';
import { cloud } from '../cloud/store';
import { purchases } from '../purchases/store';
import { Button, Meter, Row, colors, fonts, ui } from '../ui/design';
import thumbleIcon from '../../assets/icon.png';

const PLAN_NAMES = Object.fromEntries(Object.entries(config.products).map(([key, id]) => [id, key.replace('family', 'Family ').replace(/^./, letter => letter.toUpperCase())]));
const shortDate = ms => new Date(ms).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });

function planSummary(purchase, now = Date.now()) {
  if (purchase.status !== 'active') return { label: 'NO ACTIVE PLAN', detail: 'Choose a plan to keep playing.', filled: 0, total: 0 };
  const name = (PLAN_NAMES[purchase.productId] ?? 'Plan').toUpperCase();
  if (!purchase.expiresAt) return { label: `${name} · NEVER EXPIRES`, detail: 'Thanks for supporting Thumble.', filled: 0, total: 0 };
  const left = Math.max(0, Math.ceil((purchase.expiresAt - now) / 86_400_000));
  if (purchase.inTrial) return { label: `${name} · FREE TRIAL`, detail: `Trial ends ${shortDate(purchase.expiresAt)}${purchase.willRenew ? ', then your plan starts' : ''}`, filled: Math.max(0, config.trialDays - left), total: config.trialDays };
  return { label: name, detail: `${purchase.willRenew ? 'Renews' : 'Ends'} ${shortDate(purchase.expiresAt)}`, filled: 0, total: 0 };
}

export default function ControllerMenu() {
  const network = useSyncExternalStore(connection.subscribe, connection.snapshot);
  const layout = useSyncExternalStore(connection.subscribeProfile, connection.profileSnapshot);
  const cloudState = useSyncExternalStore(cloud.subscribe, cloud.snapshot);
  const purchase = useSyncExternalStore(purchases.subscribe, purchases.snapshot);
  const { width, height } = useWindowDimensions();
  const landscape = width > height;
  const online = network.phase === 'connected';
  const displayedProfile = AI_CONTROLLER_GENERATOR_ENABLED && network.phase === 'offline' ? cloudState.selected?.profile ?? layout.profile : layout.profile;
  const plan = planSummary(purchase);
  function close() { if (router.canGoBack()) router.back(); else router.replace('/'); }
  const items = [
    ['Setup', online ? 'Paired · gamepad live' : 'Pair and check your three lights', '/connect'],
    ['Stick calibration', 'Dead zone, invert look', '/calibration'],
    ['Controllers', displayedProfile.name, '/profiles'],
    ['Practice run', 'Redo the five-move test', landscape ? '/?practice=coach' : '/rotate'],
    ['Label sync', 'ConsolePort, chat and dictation', '/controller-settings'],
    ['Plan & billing', plan.detail, '/pro'],
    ...(AI_CONTROLLER_GENERATOR_ENABLED ? [['AI to WoW', 'Connect your AI to a controller', '/journey'], ['Cloud controllers', 'Saved in your account', '/cloud']] : [['Cloud account', 'Sign in and manage your account', '/cloud']]),
  ];
  const status = <View style={[s.status, landscape ? { width: 280 } : {}]}>
    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 10 }}>
      <Image source={thumbleIcon} style={s.icon} accessible={false} />
      <Text style={{ fontFamily: fonts.pixel, fontSize: 22, color: colors.surface, flex: 1 }}>thumble<Text style={{ color: colors.accent }}>.</Text></Text>
    </View>
    <Text style={[ui.label, { color: colors.accent }]}>{online ? `● CONNECTED${network.rtt != null ? ` · ${network.rtt} MS RTT` : ''}` : network.phase === 'connecting' ? '● CONNECTING…' : '● NOT CONNECTED'}</Text>
    <Text style={{ fontFamily: fonts.pixel, fontSize: 22, lineHeight: 24, color: colors.surface }}>{displayedProfile.name}</Text>
    <Text style={[ui.small, { color: '#CFC6B5' }]}>{network.detail}</Text>
    <View style={{ gap: 6 }}>
      <Text style={[ui.label, { color: colors.surface, fontSize: 10 }]}>{plan.label}</Text>
      {plan.total > 0 && <Meter inverse filled={plan.filled} total={plan.total} />}
      <Text style={[ui.small, { color: '#CFC6B5' }]}>{plan.detail}</Text>
    </View>
    <View style={{ flex: landscape ? 1 : 0 }} />
    <Pressable accessibilityRole="button" onPress={close} style={({ pressed }) => [s.back, pressed && { opacity: 0.8 }]}><Text style={{ fontFamily: fonts.pixel, fontSize: 17, color: colors.text }}>Back to WoW</Text></Pressable>
  </View>;
  return <SafeAreaProvider><SafeAreaView style={[s.screen, landscape && { backgroundColor: '#000000AA' }]} accessibilityViewIsModal>
    <StatusBar hidden={landscape} style="dark" />
    {landscape && <Pressable style={StyleSheet.absoluteFill} accessibilityRole="button" accessibilityLabel="Dismiss Thumble menu" onPress={close} />}
    <View style={[s.panel, landscape ? s.panelLandscape : s.panelPortrait]}>
      {status}
      <ScrollView style={{ flex: 1 }} contentContainerStyle={{ gap: 10, paddingBottom: 4 }}>
        <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', minHeight: 28 }}>
          <Text style={ui.label}>MENU · INPUTS RELEASED WHILE OPEN</Text>
        </View>
        <View style={{ flexDirection: landscape ? 'row' : 'column', flexWrap: 'wrap', gap: 10 }}>
          {items.map(([title, detail, path]) => <View key={path} style={landscape ? { width: '48%', flexGrow: 1 } : undefined}><Row title={title} detail={detail} onPress={() => router.replace(path)} /></View>)}
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
  panelLandscape: { flexDirection: 'row', margin: 12, padding: 14, borderRadius: 6, borderWidth: 3, borderColor: colors.border, backgroundColor: colors.background, boxShadow: '6px 6px 0px #000000' },
  panelPortrait: { padding: 20, paddingTop: 8 },
  status: { padding: 16, gap: 10, borderRadius: 6, backgroundColor: colors.text, boxShadow: `5px 5px 0px ${colors.muted}` },
  icon: { width: 40, height: 40, borderRadius: 6 },
  back: { minHeight: 48, borderRadius: 4, borderWidth: 3, borderColor: colors.surface, backgroundColor: colors.accent, alignItems: 'center', justifyContent: 'center' },
});
