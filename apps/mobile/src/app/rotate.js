import { useEffect } from 'react';
import { Text, View, useWindowDimensions } from 'react-native';
import { router } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';
import { BackButton, Button, colors, fonts, ui } from '../ui/design';

const toPractice = () => router.dismissTo({ pathname: '/', params: { practice: 'coach' } });

// Setup works upright; the ConsolePort controller is landscape. Turning the
// phone continues on its own, so the button is only a fallback.
export default function RotateScreen() {
  const { width, height } = useWindowDimensions();
  useEffect(() => { if (width > height) toPractice(); }, [width, height]);
  return <SafeAreaProvider><SafeAreaView style={{ flex: 1, backgroundColor: colors.background }}>
    <StatusBar style="dark" />
    <View style={{ flex: 1, paddingHorizontal: 20, paddingBottom: 8, gap: 16 }}>
      <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', minHeight: 44 }}>
        <BackButton />
        <Text style={ui.label}>All three lights on</Text>
      </View>
      <View style={{ height: 260, alignItems: 'center', justifyContent: 'center' }} accessible accessibilityLabel="Turn the phone from upright to sideways">
        <View style={{ position: 'absolute', left: '8%', top: 30, width: 74, height: 132, borderRadius: 10, borderWidth: 4, borderColor: colors.border, backgroundColor: colors.surface, opacity: 0.55, boxShadow: `4px 4px 0px ${colors.border}` }} />
        <Text style={{ position: 'absolute', left: '36%', top: 30, fontFamily: fonts.pixel, fontSize: 48, color: colors.text }}>↷</Text>
        <View style={{ position: 'absolute', right: '6%', bottom: 20, width: 190, height: 104, borderRadius: 12, borderWidth: 4, borderColor: colors.border, backgroundColor: colors.surface, boxShadow: `5px 5px 0px ${colors.border}`, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingHorizontal: 22 }}>
          <View style={{ width: 30, height: 30 }}>
            <View style={{ position: 'absolute', left: 10, top: 0, width: 10, height: 30, backgroundColor: colors.text }} />
            <View style={{ position: 'absolute', left: 0, top: 10, width: 30, height: 10, backgroundColor: colors.text }} />
          </View>
          <View style={{ width: 44, height: 44 }}>
            {[[15, 0], [0, 15], [30, 15], [15, 30]].map(([x, y]) => <View key={`${x}${y}`} style={{ position: 'absolute', left: x, top: y, width: 14, height: 14, borderRadius: 7, backgroundColor: colors.accent, borderWidth: 2, borderColor: colors.border }} />)}
          </View>
        </View>
      </View>
      <Text accessibilityRole="header" style={[ui.title, { fontSize: 36, lineHeight: 37 }]}>Turn your phone sideways.</Text>
      <Text style={ui.body}>The controller is landscape. Hold the phone like a gamepad, one thumb on each side.</Text>
      <View style={[ui.card, { gap: 6 }]}>
        <Text style={ui.label}>Practice · about a minute</Text>
        <Text style={ui.muted}>Move, look, jump, a modifier layer, then the game menu. Stand somewhere quiet in game first.</Text>
      </View>
      <View style={{ flex: 1 }} />
      <Button onPress={toPractice}>Start practice</Button>
      <Button ghost compact onPress={() => router.dismissTo('/')}>Skip practice</Button>
    </View>
  </SafeAreaView></SafeAreaProvider>;
}
