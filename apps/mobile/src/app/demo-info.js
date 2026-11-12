import { useSyncExternalStore } from 'react';
import { Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { router, useLocalSearchParams } from 'expo-router';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';
import { StatusBar } from 'expo-status-bar';
import { connection } from '../connection';
import { purchases } from '../purchases/store';
import { formatDemoTime } from '../demo-time';
import { Button, fonts, pad } from '../ui/design';

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
      <View style={s.header}><Text style={s.heading}>{pro ? 'Thumble Pro' : 'Your free controller time'}</Text><Pressable accessibilityRole="button" accessibilityLabel="Close free time information" onPress={close} style={s.close}><Text style={s.closeText}>Done</Text></Pressable></View>
      <ScrollView contentContainerStyle={s.content} contentInsetAdjustmentBehavior="automatic">
        <Text style={s.time}>{pro ? 'Unlimited' : formatDemoTime(remaining)}</Text>
        <Text style={s.body}>{pro ? 'You have unlimited controller time. Enjoy every feature, for as long as you like.' : 'Try every feature free for 30 minutes across all sessions. Time counts down while you view the controller connected to your computer.'}</Text>
        {!pro && <View style={s.meter}><View style={[s.meterFill, { width: `${Math.max(0, Math.min(1, remaining / 1800)) * 100}%` }]} /></View>}
        {!pro && <Text style={s.small}>Leaving the controller pauses the timer. Offline practice is always free, and nothing charges automatically.</Text>}
      </ScrollView>
      {!pro && <View style={s.footer}><Button onPress={() => router.replace('/pro')}>See plans</Button></View>}
    </View>
  </SafeAreaView></SafeAreaProvider>;
}
const s = StyleSheet.create({
  overlay: { flex: 1, backgroundColor: 'rgba(0,0,0,0.6)', alignItems: 'center', justifyContent: 'center', paddingHorizontal: 24, paddingVertical: 8 },
  panel: { width: '100%', maxWidth: 440, maxHeight: '100%', backgroundColor: '#2C2C2E', borderRadius: 20, borderCurve: 'continuous', overflow: 'hidden' },
  header: { paddingLeft: 22, paddingRight: 8, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  close: { minWidth: 64, minHeight: 48, alignItems: 'center', justifyContent: 'center' },
  closeText: { color: pad.ring, fontSize: 16, fontFamily: fonts.bodyBold },
  heading: { color: pad.ring, fontFamily: fonts.bodyBold, fontSize: 13 },
  body: { color: pad.muted, fontFamily: fonts.body, fontSize: 14, lineHeight: 20 },
  small: { color: pad.muted, fontFamily: fonts.body, fontSize: 12, lineHeight: 17 },
  meter: { height: 6, borderRadius: 3, backgroundColor: '#48484A', overflow: 'hidden' },
  meterFill: { height: 6, borderRadius: 3, backgroundColor: pad.accent },
  content: { paddingHorizontal: 22, paddingBottom: 12, gap: 12 },
  footer: { paddingHorizontal: 22, paddingBottom: 18, paddingTop: 4, gap: 8 },
  time: { color: pad.text, fontSize: 40, lineHeight: 44, fontFamily: fonts.bodyBold, fontVariant: ['tabular-nums'], letterSpacing: -1 },
});
