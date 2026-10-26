import { AI_CONTROLLER_GENERATOR_ENABLED } from '../features';
import { useState } from 'react';
import { Image, Pressable, StyleSheet, Text, View } from 'react-native';
import { router } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { Actions, Button, Columns, Eyebrow, Page, colors, ui } from '../ui/design';
import { useSetup } from '../use-setup';
import thumbleIcon from '../../assets/thumble-menu.png';
export default function WelcomeScreen() {
  const { state, save, error } = useSetup();
  const [busy, setBusy] = useState(false);
  async function begin(practice = false) {
    if (busy) return;
    setBusy(true);
    if (await save({ welcomeSeen: true, ...(practice ? { dismissed: true } : {}) })) {
      if (practice) router.dismissTo('/'); else router.replace('/wow-setup?setup=1');
    }
    else setBusy(false);
  }
  return <Page style={{ paddingTop: 16 }} footer={<Actions><View style={{ flex: 1 }}><Button disabled={!state.loaded || busy} onPress={() => begin()}>Set up WoW</Button></View></Actions>}><StatusBar hidden />
    <View style={s.top}><View style={s.brand}><Image source={thumbleIcon} style={s.icon} /><Text style={s.wordmark}>thumble<Text style={{ color: colors.secondary }}>.</Text></Text></View>
      <Pressable accessibilityRole="button" disabled={!state.loaded || busy} onPress={() => begin(true)} style={s.skip}><Text style={ui.small}>Try the controls</Text></Pressable></View>
    <Columns><View style={[ui.column, { justifyContent: 'center', gap: 16 }]}><Eyebrow>WOW + CONSOLEPORT</Eyebrow><Text accessibilityRole="header" style={[ui.title, { fontSize: 40, lineHeight: 44 }]}>{'WoW on desktop.\nControls on your phone.'}</Text><Text style={ui.body}>Move, look around and use your WoW actions from your phone. Start with ConsolePort controls and set your bindings in WoW.</Text><Text style={ui.small}>WoW runs on your computer. Keep your phone and computer on the same Wi-Fi.</Text></View>
      <View style={[ui.column, { justifyContent: 'center', gap: 16 }]}>{AI_CONTROLLER_GENERATOR_ENABLED ? <View style={ui.card}><Eyebrow>YOU SAY</Eyebrow><Text style={{ color: colors.text, fontSize: 22, lineHeight: 30, letterSpacing: -0.5 }}>“Big Charge and Execute buttons. Movement on the left. Chat up top.”</Text><Text style={ui.small}>YOUR AGENT BUILDS THE LAYOUT</Text></View> : <View style={ui.card}><Eyebrow>BEFORE YOU BEGIN</Eyebrow><Text style={ui.heading}>Your computer, WoW and ConsolePort.</Text><Text style={ui.body}>You’ll need macOS 15+, Windows 10/11, or Linux with a compatible Wine/Proton setup, plus WoW and a ConsolePort version for your installation. We’ll walk you through pairing, the recommended Thumble companion addon, and your first in-game checks.</Text></View>}
        {!!error && <Text accessibilityRole="alert" style={ui.error}>{error}</Text>}
      </View></Columns>
  </Page>;
}
const s = StyleSheet.create({ top: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' }, brand: { flexDirection: 'row', alignItems: 'center', gap: 12 }, icon: { width: 32, height: 32, borderRadius: 8 }, wordmark: { color: colors.text, fontSize: 24, letterSpacing: -1, fontWeight: '600' }, skip: { minHeight: 44, minWidth: 80, alignItems: 'center', justifyContent: 'center' } });
