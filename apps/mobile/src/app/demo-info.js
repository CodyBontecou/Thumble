import { useSyncExternalStore } from 'react';
import { Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { router, useLocalSearchParams } from 'expo-router';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';
import { StatusBar } from 'expo-status-bar';
import { connection } from '../connection';
import { purchases } from '../purchases/store';
import { formatDemoTime } from '../demo-time';
import { Button, colors, ui } from '../ui/design';

export default function DemoInfo() {
  const access = useSyncExternalStore(connection.subscribeAccess, connection.accessSnapshot);
  const purchase = useSyncExternalStore(purchases.subscribe, purchases.snapshot);
  const { remaining: savedRemaining } = useLocalSearchParams();
  const remaining = access?.remaining ?? (Number(savedRemaining) || 0);
  const pro = access?.pro || (!access && purchase.status === 'owned');
  function close() { if (router.canGoBack()) router.back(); else router.replace('/'); }
  return <SafeAreaProvider><SafeAreaView style={s.overlay} accessibilityViewIsModal>
    <StatusBar hidden />
    <Pressable style={StyleSheet.absoluteFill} accessibilityRole="button" accessibilityLabel="Dismiss free time information" onPress={close} />
    <View style={s.panel}>
      <View style={s.header}><Text style={ui.heading}>{pro ? 'Thumble Pro' : 'Your free controller time'}</Text><Pressable accessibilityRole="button" accessibilityLabel="Close free time information" onPress={close} style={s.close}><Text style={s.closeText}>Done</Text></Pressable></View>
      <ScrollView contentContainerStyle={s.content} contentInsetAdjustmentBehavior="automatic">
        <Text style={s.time}>{pro ? 'Unlimited' : formatDemoTime(remaining)}</Text>
        <Text style={ui.body}>{pro ? 'You have unlimited controller time. Enjoy every feature, for as long as you like.' : 'Try every feature free for 30 minutes across all sessions. Time counts down while you view the controller connected to your computer.'}</Text>
        {!pro && <Text style={ui.small}>Leaving the controller pauses the timer. Offline practice is always free. No automatic charge.</Text>}
      </ScrollView>
      {!pro && <View style={s.footer}><Button onPress={() => router.replace('/pro')}>Unlock Pro</Button><Text style={[ui.small, { textAlign: 'center' }]}>Unlimited controller time. One lifetime purchase.</Text></View>}
    </View>
  </SafeAreaView></SafeAreaProvider>;
}
const s = StyleSheet.create({
  overlay: { flex: 1, backgroundColor: '#000000AA', alignItems: 'center', justifyContent: 'center', paddingHorizontal: 24, paddingVertical: 8 },
  panel: { width: '100%', maxWidth: 440, maxHeight: '100%', backgroundColor: colors.background, borderRadius: 24, borderCurve: 'continuous', borderWidth: 1, borderColor: colors.border, overflow: 'hidden' },
  header: { paddingLeft: 24, paddingRight: 8, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', borderBottomWidth: StyleSheet.hairlineWidth, borderColor: colors.border },
  close: { minWidth: 64, minHeight: 52, alignItems: 'center', justifyContent: 'center' },
  closeText: { color: colors.text, fontSize: 16 },
  content: { padding: 24, gap: 16 },
  footer: { paddingHorizontal: 24, paddingBottom: 16, paddingTop: 8, gap: 8 },
  time: { color: colors.text, fontSize: 36, lineHeight: 40, fontWeight: '600', fontVariant: ['tabular-nums'], letterSpacing: -1 },
});
