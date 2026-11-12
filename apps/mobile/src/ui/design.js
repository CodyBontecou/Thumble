import { Appearance, Image, Pressable, ScrollView, StyleSheet, Text, View, useWindowDimensions } from 'react-native';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';
import { router } from 'expo-router';
import thumbleIcon from '../../assets/icon.png';

// Thumble Native: grouped iOS/Android-style surfaces, one blue action per
// screen, system light or dark (read once at launch). The controller uses the
// dark palette in both appearances so it stays calm next to the game.
const dark = {
  background: '#000000', surface: '#1C1C1E', raised: '#2C2C2E', text: '#F2F2F7', secondary: '#AEAEB2',
  muted: '#8E8E93', border: '#38383A', accent: '#0A64D8', onAccent: '#FFFFFF', danger: '#FF6961', grip: '#48484A',
  link: '#4D9BFF', ok: '#30D158', warn: '#FFD60A', separator: '#38383A',
};
const light = {
  background: '#F2F2F7', surface: '#FFFFFF', raised: '#E3E3E8', text: '#1D1D1F', secondary: '#515154',
  muted: '#6E6E73', border: '#C6C6C8', accent: '#0A64D8', onAccent: '#FFFFFF', danger: '#D70015', grip: '#AEAEB2',
  link: '#0A64D8', ok: '#1F7A35', warn: '#9A6700', separator: '#C6C6C8',
};
export const scheme = Appearance.getColorScheme() === 'light' ? 'light' : 'dark';
export const colors = scheme === 'light' ? light : dark;
/** The landscape controller is always dark. */
export const pad = {
  ground: '#1C1C1E', key: '#2C2C2E', keyPressed: '#3A3A3C', well: '#2C2C2E', cap: '#636366', text: '#F2F2F7', muted: '#AEAEB2',
  accent: '#0A64D8', a: '#30D158', b: '#FF6961', x: '#64A8FF', y: '#FFD60A', ring: '#4D9BFF',
};
// Inter Tight is bundled; weights are encoded in the family name so every
// screen keeps its emphasis without per-platform fontWeight rules.
export const fonts = { pixel: 'InterTight_700Bold', pixelMedium: 'InterTight_500Medium', label: 'InterTight_500Medium', body: 'InterTight_400Regular', bodyMedium: 'InterTight_500Medium', bodyBold: 'InterTight_700Bold' };
export const mono = fonts.label;
export const ui = StyleSheet.create({
  title: { color: colors.text, fontFamily: fonts.pixel, fontSize: 32, lineHeight: 38, letterSpacing: -0.6 },
  body: { color: colors.secondary, fontFamily: fonts.body, fontSize: 15, lineHeight: 21 },
  heading: { color: colors.text, fontFamily: fonts.pixel, fontSize: 20, lineHeight: 25, letterSpacing: -0.2 },
  label: { color: colors.link, fontFamily: fonts.bodyMedium, fontSize: 13, lineHeight: 17, letterSpacing: 0.1 },
  card: { backgroundColor: colors.surface, borderRadius: 16, borderCurve: 'continuous', padding: 16, gap: 10 },
  column: { flex: 1, gap: 20, minWidth: 0 },
  input: { backgroundColor: colors.surface, color: colors.text, borderRadius: 12, borderCurve: 'continuous', paddingHorizontal: 14, paddingVertical: 12, fontSize: 16, fontFamily: fonts.body, minHeight: 48 },
  error: { color: colors.danger, fontFamily: fonts.bodyMedium, fontSize: 14, lineHeight: 20 },
  small: { color: colors.muted, fontFamily: fonts.body, fontSize: 12, lineHeight: 16 },
  muted: { color: colors.muted, fontFamily: fonts.body, fontSize: 13, lineHeight: 18 },
  group: { backgroundColor: colors.surface, borderRadius: 12, borderCurve: 'continuous', overflow: 'hidden' },
  caption: { color: colors.muted, fontFamily: fonts.body, fontSize: 13, textTransform: 'uppercase', letterSpacing: 0.4, paddingHorizontal: 16 },
});

/** @param {{children: any, style?: any, scroll?: boolean, footer?: any, edges?: any}} props */
export function Page({ children, style = {}, scroll = true, footer = null, edges = ['left', 'right', 'bottom'] }) {
  return <SafeAreaProvider><SafeAreaView style={{ flex: 1, backgroundColor: colors.background }} edges={edges}>
    {scroll ? <ScrollView automaticallyAdjustKeyboardInsets keyboardShouldPersistTaps="handled" keyboardDismissMode="interactive" contentInsetAdjustmentBehavior="automatic" contentContainerStyle={[{ padding: 16, paddingBottom: 28, gap: 22, width: '100%', maxWidth: 760, alignSelf: 'center' }, style]}>{children}</ScrollView> : children}
    {footer}
  </SafeAreaView></SafeAreaProvider>;
}
export function Actions({ children, status = '' }) {
  return <View style={{ paddingHorizontal: 16, paddingTop: 12, paddingBottom: 8, gap: 8 }}>
    {!!status && <Text accessibilityLiveRegion="polite" style={[ui.small, { textAlign: 'center' }]}>{status}</Text>}
    <View style={{ flexDirection: 'row', gap: 10 }}>{children}</View>
  </View>;
}
export function Columns({ children, style = {} }) {
  const { width } = useWindowDimensions();
  return <View style={[{ flexDirection: width >= 680 ? 'row' : 'column', gap: 22, alignItems: 'stretch' }, style]}>{children}</View>;
}
/** @param {{ children: any, inverse?: boolean }} props */
export function Eyebrow({ children, inverse = false }) {
  return <Text style={[ui.label, inverse && { alignSelf: 'flex-start', paddingHorizontal: 10, paddingVertical: 4, backgroundColor: colors.raised, color: colors.text, borderRadius: 12, overflow: 'hidden' }]}>{children}</Text>;
}
/**
 * Primary is filled blue; secondary is a grey fill; ghost is a plain text button.
 * @param {{ children: any, onPress?: () => any, disabled?: boolean, secondary?: boolean, ghost?: boolean, compact?: boolean, accessibilityLabel?: string, testID?: string }} props
 */
export function Button({ children, onPress, disabled = false, secondary = false, ghost = false, compact = false, accessibilityLabel = undefined, testID = undefined }) {
  const primary = !secondary && !ghost;
  return <Pressable accessibilityRole="button" accessibilityLabel={accessibilityLabel} accessibilityState={{ disabled }} disabled={disabled} onPress={onPress} testID={testID}
    style={({ pressed }) => ({
      minHeight: compact ? 44 : 50, borderRadius: compact ? 10 : 14, borderCurve: 'continuous', paddingHorizontal: compact ? 14 : 20, paddingVertical: 10,
      alignItems: 'center', justifyContent: 'center', opacity: disabled ? 0.4 : pressed ? 0.7 : 1,
      backgroundColor: primary ? colors.accent : secondary ? colors.raised : 'transparent',
    })}>
    <Text style={{ color: primary ? colors.onAccent : ghost ? colors.link : colors.text, fontFamily: ghost ? fonts.bodyMedium : fonts.bodyBold, fontSize: compact ? 15 : 17, lineHeight: compact ? 20 : 22, textAlign: 'center' }}>{children}</Text>
  </Pressable>;
}
/** A grouped-list row. Rows placed next to each other read as one group. */
/** @param {{ title: string, detail?: string, trailing?: string, onPress?: () => any, disabled?: boolean, testID?: string }} props */
export function Row({ title, detail = '', trailing = '›', onPress, disabled = false, testID = undefined }) {
  return <Pressable accessibilityRole="button" disabled={disabled} accessibilityState={{ disabled }} onPress={onPress} testID={testID} style={({ pressed }) => ({ minHeight: 52, paddingHorizontal: 16, paddingVertical: 10, flexDirection: 'row', alignItems: 'center', gap: 12, backgroundColor: pressed ? colors.raised : colors.surface, borderRadius: 12, borderCurve: 'continuous', opacity: disabled ? 0.4 : 1 })}>
    <View style={{ flex: 1, gap: 2 }}><Text style={{ color: colors.text, fontFamily: fonts.bodyMedium, fontSize: 16, lineHeight: 21 }}>{title}</Text>{detail ? <Text numberOfLines={2} style={ui.muted}>{detail}</Text> : null}</View>
    <Text style={{ color: colors.grip, fontFamily: fonts.bodyMedium, fontSize: 22 }}>{trailing}</Text>
  </Pressable>;
}
/** @param {{ onPress?: () => any, label?: string }} props */
export function BackButton({ onPress = undefined, label = 'Back' }) {
  return <Pressable accessibilityRole="button" accessibilityLabel={label} hitSlop={8} onPress={onPress ?? (() => router.canGoBack() ? router.back() : router.replace('/'))}
    style={({ pressed }) => ({ minWidth: 44, height: 44, flexDirection: 'row', alignItems: 'center', gap: 2, opacity: pressed ? 0.5 : 1 })}>
    <Text style={{ color: colors.link, fontFamily: fonts.bodyMedium, fontSize: 28, lineHeight: 30, marginTop: -3 }}>‹</Text>
    <Text style={{ color: colors.link, fontFamily: fonts.body, fontSize: 17 }}>{label}</Text>
  </Pressable>;
}
export function Wordmark({ size = 24, icon = false }) {
  return <View style={{ flexDirection: 'row', alignItems: 'center', gap: 10 }}>
    {icon && <Image source={thumbleIcon} accessible={false} style={{ width: size * 1.6, height: size * 1.6, borderRadius: size * 0.36 }} />}
    <Text accessibilityRole="header" style={{ color: colors.text, fontFamily: fonts.pixel, fontSize: size, letterSpacing: -0.4 }}>Thumble</Text>
  </View>;
}
export function Bullet({ children }) {
  return <View style={{ flexDirection: 'row', gap: 10, alignItems: 'center' }}>
    <View style={{ width: 8, height: 8, borderRadius: 4, backgroundColor: colors.accent }} />
    <Text style={[ui.body, { flex: 1, color: colors.text, fontSize: 15 }]}>{children}</Text>
  </View>;
}
/** Status light used by setup: off, waiting (current) or on. */
export function Lamp({ state }) {
  const on = state === 'on', waiting = state === 'waiting';
  return <View style={{ width: 24, height: 24, borderRadius: 12, alignItems: 'center', justifyContent: 'center', backgroundColor: on ? colors.ok : waiting ? colors.accent : 'transparent', borderWidth: on || waiting ? 0 : 1.5, borderColor: colors.grip }}>
    {on && <Text style={{ color: '#000', fontFamily: fonts.bodyBold, fontSize: 13 }}>✓</Text>}
    {waiting && <View style={{ width: 8, height: 8, borderRadius: 4, backgroundColor: '#fff' }} />}
  </View>;
}
/** Segmented choice, used for Just me / Family. */
export function Segmented({ options, value, onChange, label }) {
  return <View accessibilityRole="radiogroup" accessibilityLabel={label} style={{ flexDirection: 'row', padding: 2, gap: 2, backgroundColor: colors.raised, borderRadius: 9, borderCurve: 'continuous' }}>
    {options.map(option => {
      const on = option.value === value;
      return <Pressable key={option.value} accessibilityRole="radio" accessibilityState={{ checked: on }} onPress={() => onChange(option.value)} style={{ flex: 1, minHeight: 34, borderRadius: 7, alignItems: 'center', justifyContent: 'center', backgroundColor: on ? (scheme === 'light' ? '#FFFFFF' : '#636366') : 'transparent' }}>
        <Text style={{ fontFamily: fonts.bodyMedium, fontSize: 14, color: colors.text }}>{option.label}</Text>
      </Pressable>;
    })}
  </View>;
}
/** Free-trial meter. */
export function Meter({ filled, total, inverse = false }) {
  return <View style={{ height: 6, borderRadius: 3, backgroundColor: inverse ? 'rgba(255,255,255,0.25)' : colors.raised, overflow: 'hidden' }}>
    <View style={{ width: `${Math.max(0, Math.min(1, total ? filled / total : 0)) * 100}%`, height: 6, borderRadius: 3, backgroundColor: colors.accent }} />
  </View>;
}
