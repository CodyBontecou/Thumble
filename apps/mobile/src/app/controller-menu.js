import { useSyncExternalStore } from 'react';
import { Image, Pressable, ScrollView, StyleSheet, Text, View, useWindowDimensions } from 'react-native';
import { router } from 'expo-router';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';
import { StatusBar } from 'expo-status-bar';
import { connection } from '../connection';
import { Button, Eyebrow, Row, colors, ui } from '../ui/design';
import thumbleIcon from '../../assets/thumble-menu.png';
export default function ControllerMenu() {
  const network = useSyncExternalStore(connection.subscribe, connection.snapshot);
  const access = useSyncExternalStore(connection.subscribeAccess, connection.accessSnapshot);
  const layout = useSyncExternalStore(connection.subscribeProfile, connection.profileSnapshot);
  const { width } = useWindowDimensions();
  const online = network.phase === 'connected';
  function close() { if (router.canGoBack()) router.back(); else router.replace('/'); }
  return <SafeAreaProvider><SafeAreaView style={s.overlay} accessibilityViewIsModal>
    <StatusBar hidden />
    <Pressable style={StyleSheet.absoluteFill} accessibilityRole="button" accessibilityLabel="Dismiss controller menu" onPress={close} />
    <View style={s.panel}>
      <View style={s.heading}><Image source={thumbleIcon} style={s.icon} accessible={false} /><Text style={s.brand}>thumble.</Text><Pressable accessibilityRole="button" onPress={close} style={s.done}><Text style={{ color: colors.text, fontSize: 16 }}>Done</Text></Pressable></View>
      <ScrollView contentContainerStyle={{ padding: 16, gap: 16, flexDirection: width >= 680 ? 'row' : 'column' }}>
        <View style={[s.summary, { flex: 1 }]}><Eyebrow>{online ? 'CONNECTED TO YOUR MAC' : 'YOUR CONTROLLER'}</Eyebrow><Text style={[ui.title, { fontSize: 28, lineHeight: 32 }]}>{layout.profile.name}</Text>
          <Text style={ui.small}>{network.detail}{network.rtt != null ? ` · ${network.rtt} ms` : ''}</Text>
          <Button onPress={() => online ? (connection.disconnect(), close()) : router.replace('/pair')} secondary={online}>{online ? 'Disconnect Mac' : 'Connect Mac'}</Button>
          <Text style={ui.small}>{access?.pro ? 'PRO · UNLIMITED PLAY' : access ? `${Math.ceil(access.remaining / 60)} minutes of demo remaining` : '30-minute total controller demo'}</Text>
        </View>
        <View style={{ flex: 1.15, gap: 4 }}>
          <Row title="Profiles" detail="Choose your saved controller" onPress={() => router.replace('/profiles')} />
          <Row title="Stick calibration" onPress={() => router.replace('/calibration')} />
          <Row title="WoW setup" onPress={() => router.replace('/wow-setup')} />
          <Row title={access?.pro ? 'Thumble Pro' : 'Unlock Thumble Pro'} detail={access?.pro ? 'Manage your purchase' : 'Remove the 30-minute limit.'} onPress={() => router.replace('/pro')} />
          <Row title="Getting started" onPress={() => router.replace('/onboarding')} />
        </View>
      </ScrollView>
    </View>
  </SafeAreaView></SafeAreaProvider>;
}
const s = StyleSheet.create({ overlay: { flex: 1, backgroundColor: '#000000AA', alignItems: 'center', justifyContent: 'center', paddingHorizontal: 24, paddingVertical: 8 }, panel: { width: '100%', maxWidth: 840, maxHeight: '100%', borderRadius: 24, borderCurve: 'continuous', borderWidth: 1, borderColor: colors.border, backgroundColor: colors.background, overflow: 'hidden' }, heading: { flexDirection: 'row', alignItems: 'center', paddingLeft: 24, paddingRight: 12, borderBottomWidth: StyleSheet.hairlineWidth, borderColor: colors.border }, icon: { width: 28, height: 28, borderRadius: 8, marginRight: 12 }, brand: { flex: 1, color: colors.text, fontSize: 22, letterSpacing: -0.8, fontWeight: '600' }, done: { minWidth: 64, minHeight: 52, alignItems: 'center', justifyContent: 'center' }, summary: { backgroundColor: colors.surface, borderRadius: 16, borderCurve: 'continuous', padding: 24, gap: 16, alignSelf: 'flex-start' } });
