import { useState } from 'react';
import { Image, Pressable, StyleSheet, Text, View } from 'react-native';
import { router } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { Button, Columns, Eyebrow, Page, colors, ui } from '../ui/design';
import { useSetup } from '../use-setup';
import thumbleIcon from '../../assets/thumble-menu.png';
export default function WelcomeScreen() {
  const { state, save, error } = useSetup();
  const [busy, setBusy] = useState(false);
  async function begin(practice = false) {
    if (busy) return;
    setBusy(true);
    if (await save({ welcomeSeen: true, ...(practice ? { dismissed: true } : {}) })) {
      if (practice) router.dismissTo('/'); else router.replace('/onboarding');
    }
    else setBusy(false);
  }
  return <Page style={{ paddingTop: 16 }}><StatusBar hidden />
    <View style={s.top}><View style={s.brand}><Image source={thumbleIcon} style={s.icon} /><Text style={s.wordmark}>thumble<Text style={{ color: colors.secondary }}>.</Text></Text></View>
      <Pressable accessibilityRole="button" disabled={!state.loaded || busy} onPress={() => begin(true)} style={s.skip}><Text style={ui.small}>Explore first</Text></Pressable></View>
    <Columns><View style={[ui.column, { justifyContent: 'center', gap: 16 }]}><Eyebrow>YOUR PHONE. YOUR CONTROLLER.</Eyebrow><Text accessibilityRole="header" style={[ui.title, { fontSize: 40, lineHeight: 44 }]}>{'Made for the way\nyou play.'}</Text><Text style={ui.body}>Turn your phone into a controller for your Mac. Start with familiar controls, or describe a layout to your own AI agent.</Text><Text style={ui.small}>Your agent designs the layout. Every button press is you.</Text></View>
      <View style={[ui.column, { justifyContent: 'center', gap: 16 }]}><View style={ui.card}><Eyebrow>YOU SAY</Eyebrow><Text style={{ color: colors.text, fontSize: 22, lineHeight: 30, letterSpacing: -0.5 }}>“Big Charge and Execute buttons. Movement on the left. Chat up top.”</Text><Text style={ui.small}>YOUR AGENT BUILDS THE LAYOUT</Text></View>
        {!!error && <Text accessibilityRole="alert" style={ui.error}>{error}</Text>}<Button disabled={!state.loaded || busy} onPress={() => begin()}>Get started</Button>
      </View></Columns>
  </Page>;
}
const s = StyleSheet.create({ top: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' }, brand: { flexDirection: 'row', alignItems: 'center', gap: 12 }, icon: { width: 32, height: 32, borderRadius: 8 }, wordmark: { color: colors.text, fontSize: 24, letterSpacing: -1, fontWeight: '600' }, skip: { minHeight: 44, minWidth: 80, alignItems: 'center', justifyContent: 'center' } });
