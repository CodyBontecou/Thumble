import { Platform, Pressable, ScrollView, StyleSheet, Text, View, useWindowDimensions } from 'react-native';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';

// myself.md's neutral palette, system typography, and 8pt spacing rhythm.
// Surfaces: 24pt; grouped rows/inputs: 16pt; primary actions: pills.
export const colors = { background: '#0A0A0A', surface: '#141414', raised: '#1F1F1F', text: '#EDEDED', secondary: '#A1A1A1', border: '#2E2E2E', accent: '#EDEDED', onAccent: '#0A0A0A', danger: '#F1A59F' };
export const mono = Platform.select({ ios: 'Menlo', default: 'monospace' });
export const ui = StyleSheet.create({
  title: { color: colors.text, fontSize: 36, lineHeight: 40, letterSpacing: -1.3, fontWeight: '600' },
  body: { color: colors.secondary, fontSize: 16, lineHeight: 24 },
  heading: { color: colors.text, fontSize: 19, lineHeight: 25, fontWeight: '600', letterSpacing: -0.3 },
  label: { color: colors.secondary, fontFamily: mono, fontSize: 10, lineHeight: 16, letterSpacing: 1.5, textTransform: 'uppercase' },
  card: { backgroundColor: colors.surface, borderWidth: 1, borderColor: colors.border, borderRadius: 24, borderCurve: 'continuous', padding: 24, gap: 16 },
  column: { flex: 1, gap: 24, minWidth: 0 },
  input: { backgroundColor: colors.background, color: colors.text, borderColor: colors.border, borderWidth: 1, borderRadius: 16, borderCurve: 'continuous', padding: 16, fontSize: 16, minHeight: 52 },
  error: { color: colors.danger, fontSize: 14, lineHeight: 21 },
  small: { color: colors.secondary, fontSize: 12, lineHeight: 18 },
});
/** @param {{children: any, style?: any, scroll?: boolean, footer?: any}} props */
export function Page({ children, style = {}, scroll = true, footer = null }) {
  return <SafeAreaProvider><SafeAreaView style={{ flex: 1, backgroundColor: colors.background }} edges={['left', 'right', 'bottom']}>
    {scroll ? <ScrollView automaticallyAdjustKeyboardInsets keyboardShouldPersistTaps="handled" keyboardDismissMode="interactive" contentInsetAdjustmentBehavior="automatic" contentContainerStyle={[{ padding: 24, paddingBottom: 32, gap: 24, width: '100%', maxWidth: 1120, alignSelf: 'center' }, style]}>{children}</ScrollView> : children}
    {footer}
  </SafeAreaView></SafeAreaProvider>;
}
export function Actions({ children, status = '' }) {
  return <View style={{ paddingHorizontal: 24, paddingTop: 12, paddingBottom: 8, borderTopWidth: 1, borderColor: colors.border, gap: 8 }}>
    {!!status && <Text accessibilityLiveRegion="polite" style={ui.small}>{status}</Text>}
    <View style={{ flexDirection: 'row', gap: 12 }}>{children}</View>
  </View>;
}
export function Columns({ children, style = {} }) {
  const { width } = useWindowDimensions();
  return <View style={[{ flexDirection: width >= 680 ? 'row' : 'column', gap: 32, alignItems: 'stretch' }, style]}>{children}</View>;
}
export function Eyebrow({ children }) { return <Text style={ui.label}>{children}</Text>; }
export function Button({ children, onPress, disabled = false, secondary = false, accessibilityLabel = undefined, testID = undefined }) {
  return <Pressable testID={testID} accessibilityRole="button" accessibilityLabel={accessibilityLabel} accessibilityState={{ disabled }} disabled={disabled} onPress={onPress}
    style={({ pressed }) => ({ minHeight: 52, borderRadius: 28, borderCurve: 'continuous', paddingHorizontal: 24, paddingVertical: 14, alignItems: 'center', justifyContent: 'center', backgroundColor: secondary ? colors.raised : colors.accent, opacity: disabled ? 0.4 : pressed ? 0.7 : 1 })}>
    <Text style={{ color: secondary ? colors.text : colors.onAccent, fontSize: 16, lineHeight: 24, fontWeight: '600', textAlign: 'center' }}>{children}</Text>
  </Pressable>;
}
export function Row({ title, detail = '', trailing = '›', onPress, disabled = false }) {
  return <Pressable accessibilityRole="button" disabled={disabled} accessibilityState={{ disabled }} onPress={onPress} style={({ pressed }) => ({ minHeight: 48, paddingHorizontal: 16, paddingVertical: 8, flexDirection: 'row', alignItems: 'center', gap: 16, backgroundColor: pressed ? colors.raised : 'transparent', borderRadius: 16, borderCurve: 'continuous', opacity: disabled ? 0.4 : 1 })}>
    <View style={{ flex: 1, gap: 4 }}><Text style={{ color: colors.text, fontSize: 16, fontWeight: '500' }}>{title}</Text>{detail ? <Text style={ui.small}>{detail}</Text> : null}</View>
    <Text style={{ color: colors.secondary, fontSize: 22 }}>{trailing}</Text>
  </Pressable>;
}

// A product diagram, deliberately inert: onboarding never emits game input.
export function ControllerPreview({ caption = 'MADE FOR YOUR THUMBS' }) {
  return <View style={[ui.card, { justifyContent: 'center', minHeight: 212 }]} accessible accessibilityLabel="Illustration of a custom controller with a left movement stick and right action buttons">
    <Eyebrow>{caption}</Eyebrow>
    <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 16, paddingVertical: 16 }}>
      <View style={{ width: 92, height: 92, borderRadius: 46, backgroundColor: colors.background, borderWidth: 1, borderColor: colors.border, alignItems: 'center', justifyContent: 'center' }}><View style={{ width: 56, height: 56, borderRadius: 28, backgroundColor: colors.raised, borderWidth: 1, borderColor: '#444444' }} /></View>
      <View style={{ gap: 8 }}><View style={{ alignSelf: 'center', width: 44, height: 32, borderRadius: 16, borderWidth: 1, borderColor: colors.border, alignItems: 'center', justifyContent: 'center' }}><Text style={[ui.small, { fontSize: 10 }]}>CHAT</Text></View><View style={{ flexDirection: 'row', gap: 8 }}>{['Charge', 'Execute'].map(label => <View key={label} style={{ width: 64, height: 64, borderRadius: 32, backgroundColor: colors.raised, borderWidth: 1, borderColor: '#444444', alignItems: 'center', justifyContent: 'center' }}><Text style={{ color: colors.text, fontSize: 11 }}>{label}</Text></View>)}</View></View>
    </View>
  </View>;
}
