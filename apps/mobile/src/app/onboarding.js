import { useState } from 'react';
import { Image, Pressable, StyleSheet, Text, View } from 'react-native';
import { router } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { Button, Columns, ControllerPreview, Eyebrow, Page, colors, ui } from '../ui/design';
import { onboarding } from '../onboarding';
import thumbleIcon from '../../assets/thumble-menu.png';
const steps = [
  { label: 'YOUR PHONE. YOUR CONTROLLER.', title: 'Made for the way\nyou play.', body: 'Turn your phone into a controller for your Mac. Start with familiar controls, or describe a layout to your own AI agent.', caption: 'A CONTROLLER THAT FITS YOU' },
  { label: 'ONE CONNECTION. ALL YOUR CONTROLS.', title: 'From your Mac.\nTo your thumbs.', body: 'Open Tapping Receiver on your Mac, use the same Wi-Fi, and scan its QR code. Your saved layout arrives on your phone.', caption: 'MAC → LOCAL WI-FI → PHONE' },
  { label: 'YOUR AGENT DESIGNS. YOU PLAY.', title: 'Describe it.\nThen play it.', body: 'Ask your agent for bigger buttons, a different layout, or your character’s spells. Review bindings in-game. Every button press is yours.', caption: 'AI BUILDS THE LAYOUT. YOU PLAY.' },
];
export default function OnboardingScreen() {
  const [step, setStep] = useState(0);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const current = steps[step];
  async function finish(destination) {
    if (busy) return;
    setBusy(true); setError('');
    try { await onboarding.finish(); router.replace(destination); }
    catch (failure) { setError(failure.message); setBusy(false); }
  }
  return <Page style={{ paddingTop: 16 }}><StatusBar hidden />
    <View style={s.top}><View style={s.brand}><Image source={thumbleIcon} style={s.icon} /><Text style={s.wordmark}>thumble<Text style={{ color: colors.secondary }}>.</Text></Text></View>
      <Pressable accessibilityRole="button" disabled={busy} onPress={() => finish('/')} style={s.skip}><Text style={ui.small}>Skip intro</Text></Pressable></View>
    <Columns><View style={[ui.column, { justifyContent: 'center', gap: 16 }]}><Eyebrow>{current.label}</Eyebrow><Text accessibilityRole="header" style={[ui.title, { fontSize: 40, lineHeight: 44 }]}>{current.title}</Text><Text style={ui.body}>{current.body}</Text>
      <View style={s.progress} accessibilityLabel={`Step ${step + 1} of 3`}>{steps.map((_, i) => <View key={i} style={[s.dot, { backgroundColor: i === step ? colors.text : colors.border }]} />)}</View>
    </View><View style={[ui.column, { justifyContent: 'center', gap: 16 }]}>
      {step === 0 ? <View style={[ui.card, { gap: 12 }]}><Eyebrow>YOU SAY</Eyebrow><Text style={{ color: colors.text, fontSize: 22, lineHeight: 30, letterSpacing: -0.5 }}>“Big Charge and Execute buttons. Movement on the left. Chat up top.”</Text><Text style={ui.small}>YOUR AGENT BUILDS THE LAYOUT</Text></View> : <ControllerPreview caption={current.caption} />}
      {!!error && <Text accessibilityRole="alert" style={ui.error}>{error}</Text>}
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12 }}>
        {step > 0 && <Pressable accessibilityRole="button" disabled={busy} onPress={() => setStep(step - 1)} style={s.skip}><Text style={ui.body}>Back</Text></Pressable>}
        <View style={{ flex: 1 }}><Button disabled={busy} onPress={() => step < 2 ? setStep(step + 1) : finish('/pro?welcome=1')}>{busy ? 'Saving…' : step === 2 ? 'Choose how you play' : 'Continue'}</Button></View>
      </View>
    </View></Columns>
  </Page>;
}
const s = StyleSheet.create({ top: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' }, brand: { flexDirection: 'row', alignItems: 'center', gap: 12 }, icon: { width: 32, height: 32, borderRadius: 8 }, wordmark: { color: colors.text, fontSize: 24, letterSpacing: -1, fontWeight: '600' }, skip: { minHeight: 44, minWidth: 64, alignItems: 'center', justifyContent: 'center' }, progress: { flexDirection: 'row', gap: 8, paddingTop: 8 }, dot: { width: 24, height: 3, borderRadius: 2 } });
