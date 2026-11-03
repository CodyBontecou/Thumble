import { Image, Pressable, ScrollView, StyleSheet, Text, View, useWindowDimensions } from 'react-native';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';
import { router } from 'expo-router';
import thumbleIcon from '../../assets/icon.png';

// Thumble "Cartridge": taken from the app icon. The ground is the icon's own
// grey so the icon sits seamlessly on screen. Bone panels, ink outlines, hard
// offset shadows and one orange action per screen. The controller keeps
// ConsolePort's own look; everything around it uses these tokens.
export const colors = {
  background: '#9F9E9C', surface: '#EAE1D0', raised: '#D6CCB9', text: '#24211F', secondary: '#2F2C2A',
  muted: '#5C5650', border: '#24211F', accent: '#F56807', onAccent: '#24211F', danger: '#8B1E14', grip: '#7E7870',
};
export const fonts = { pixel: 'PixelifySans_700Bold', pixelMedium: 'PixelifySans_500Medium', label: 'Silkscreen_400Regular', body: 'InterTight_400Regular', bodyMedium: 'InterTight_500Medium', bodyBold: 'InterTight_700Bold' };
export const mono = fonts.label;
const shadow = (size = 4) => ({ boxShadow: `${size}px ${size}px 0px ${colors.border}` });
export const ui = StyleSheet.create({
  title: { color: colors.text, fontFamily: fonts.pixel, fontSize: 34, lineHeight: 36 },
  body: { color: colors.secondary, fontFamily: fonts.body, fontSize: 15, lineHeight: 21 },
  heading: { color: colors.text, fontFamily: fonts.pixel, fontSize: 20, lineHeight: 23 },
  label: { color: colors.text, fontFamily: fonts.label, fontSize: 11, lineHeight: 15 },
  card: { backgroundColor: colors.surface, borderWidth: 3, borderColor: colors.border, borderRadius: 6, padding: 16, gap: 12, ...shadow(4) },
  column: { flex: 1, gap: 20, minWidth: 0 },
  input: { backgroundColor: colors.surface, color: colors.text, borderColor: colors.border, borderWidth: 3, borderRadius: 4, padding: 14, fontSize: 16, fontFamily: fonts.body, minHeight: 52 },
  error: { color: colors.danger, fontFamily: fonts.bodyMedium, fontSize: 14, lineHeight: 20 },
  small: { color: colors.secondary, fontFamily: fonts.body, fontSize: 12, lineHeight: 17 },
  muted: { color: colors.muted, fontFamily: fonts.body, fontSize: 13, lineHeight: 18 },
});

/** @param {{children: any, style?: any, scroll?: boolean, footer?: any, edges?: any}} props */
export function Page({ children, style = {}, scroll = true, footer = null, edges = ['left', 'right', 'bottom'] }) {
  return <SafeAreaProvider><SafeAreaView style={{ flex: 1, backgroundColor: colors.background }} edges={edges}>
    {scroll ? <ScrollView automaticallyAdjustKeyboardInsets keyboardShouldPersistTaps="handled" keyboardDismissMode="interactive" contentInsetAdjustmentBehavior="automatic" contentContainerStyle={[{ padding: 20, paddingBottom: 28, gap: 20, width: '100%', maxWidth: 1120, alignSelf: 'center' }, style]}>{children}</ScrollView> : children}
    {footer}
  </SafeAreaView></SafeAreaProvider>;
}
export function Actions({ children, status = '' }) {
  return <View style={{ paddingHorizontal: 20, paddingTop: 12, paddingBottom: 8, gap: 8 }}>
    {!!status && <Text accessibilityLiveRegion="polite" style={ui.small}>{status}</Text>}
    <View style={{ flexDirection: 'row', gap: 12 }}>{children}</View>
  </View>;
}
export function Columns({ children, style = {} }) {
  const { width } = useWindowDimensions();
  return <View style={[{ flexDirection: width >= 680 ? 'row' : 'column', gap: 24, alignItems: 'stretch' }, style]}>{children}</View>;
}
/** @param {{ children: any, inverse?: boolean }} props */
export function Eyebrow({ children, inverse = false }) {
  return <Text style={[ui.label, inverse && { alignSelf: 'flex-start', paddingHorizontal: 8, paddingVertical: 4, backgroundColor: colors.text, color: colors.accent, borderRadius: 3, overflow: 'hidden' }]}>{children}</Text>;
}
/**
 * Primary is orange; secondary is bone; ghost is an outline.
 * @param {{ children: any, onPress?: () => any, disabled?: boolean, secondary?: boolean, ghost?: boolean, compact?: boolean, accessibilityLabel?: string, testID?: string }} props
 */
export function Button({ children, onPress, disabled = false, secondary = false, ghost = false, compact = false, accessibilityLabel = undefined, testID = undefined }) {
  const primary = !secondary && !ghost;
  return <Pressable accessibilityRole="button" accessibilityLabel={accessibilityLabel} accessibilityState={{ disabled }} disabled={disabled} onPress={onPress} testID={testID}
    style={({ pressed }) => ({
      minHeight: compact ? 44 : 52, borderRadius: 4, paddingHorizontal: compact ? 14 : 20, paddingVertical: 10, alignItems: 'center', justifyContent: 'center',
      backgroundColor: primary ? colors.accent : secondary ? colors.surface : 'transparent', borderWidth: ghost ? 2 : 3, borderColor: colors.border,
      opacity: disabled ? 0.45 : 1,
      ...(ghost ? {} : pressed ? { transform: [{ translateX: 3 }, { translateY: 3 }] } : shadow(primary ? 4 : 3)),
      ...(primary && !pressed ? { boxShadow: `4px 4px 0px ${colors.border}, inset 0px 3px 0px rgba(255,255,255,0.35)` } : {}),
    })}>
    <Text style={{ color: colors.text, fontFamily: primary ? fonts.pixel : fonts.bodyBold, fontSize: primary ? (compact ? 16 : 18) : 14, lineHeight: primary ? 22 : 19, textAlign: 'center' }}>{children}</Text>
  </Pressable>;
}
/** @param {{ title: string, detail?: string, trailing?: string, onPress?: () => any, disabled?: boolean, testID?: string }} props */
export function Row({ title, detail = '', trailing = '›', onPress, disabled = false, testID = undefined }) {
  return <Pressable accessibilityRole="button" disabled={disabled} accessibilityState={{ disabled }} onPress={onPress} testID={testID} style={({ pressed }) => ({ minHeight: 54, paddingHorizontal: 12, paddingVertical: 8, flexDirection: 'row', alignItems: 'center', gap: 12, backgroundColor: colors.surface, borderWidth: 3, borderColor: colors.border, borderRadius: 4, opacity: disabled ? 0.45 : 1, ...(pressed ? { transform: [{ translateX: 3 }, { translateY: 3 }] } : shadow(3)) })}>
    <View style={{ flex: 1, gap: 2 }}><Text style={{ color: colors.text, fontFamily: fonts.pixel, fontSize: 16, lineHeight: 19 }}>{title}</Text>{detail ? <Text numberOfLines={2} style={ui.muted}>{detail}</Text> : null}</View>
    <Text style={{ color: colors.text, fontFamily: fonts.pixel, fontSize: 20 }}>{trailing}</Text>
  </Pressable>;
}
/** @param {{ onPress?: () => any, label?: string }} props */
export function BackButton({ onPress = undefined, label = 'Back' }) {
  return <Pressable accessibilityRole="button" accessibilityLabel={label} hitSlop={6} onPress={onPress ?? (() => router.canGoBack() ? router.back() : router.replace('/'))}
    style={({ pressed }) => ({ width: 44, height: 44, borderRadius: 4, backgroundColor: colors.surface, borderWidth: 3, borderColor: colors.border, alignItems: 'center', justifyContent: 'center', ...(pressed ? { transform: [{ translateX: 3 }, { translateY: 3 }] } : shadow(3)) })}>
    <Text style={{ color: colors.text, fontFamily: fonts.pixel, fontSize: 22, lineHeight: 24, marginTop: -2 }}>‹</Text>
  </Pressable>;
}
export function Wordmark({ size = 24, icon = false }) {
  return <View style={{ flexDirection: 'row', alignItems: 'center', gap: 10 }}>
    {icon && <Image source={thumbleIcon} accessible={false} style={{ width: size * 1.6, height: size * 1.6, borderRadius: 6, borderWidth: 2, borderColor: colors.border }} />}
    <Text accessibilityRole="header" style={{ color: colors.text, fontFamily: fonts.pixel, fontSize: size }}>thumble<Text style={{ color: colors.accent }}>.</Text></Text>
  </View>;
}
export function Bullet({ children }) {
  return <View style={{ flexDirection: 'row', gap: 10, alignItems: 'center' }}>
    <View style={{ width: 10, height: 10, backgroundColor: colors.accent, borderWidth: 2, borderColor: colors.border }} />
    <Text style={[ui.body, { flex: 1, color: colors.text, fontFamily: fonts.bodyMedium, fontSize: 14 }]}>{children}</Text>
  </View>;
}
/** Status light used by setup: off, waiting (current) or on. */
export function Lamp({ state }) {
  return <View style={{ width: 20, height: 20, borderWidth: 3, borderColor: colors.border, backgroundColor: state === 'on' ? colors.accent : state === 'waiting' ? colors.surface : colors.grip,
    ...(state === 'on' ? { boxShadow: 'inset 0px 3px 0px rgba(255,255,255,0.45)' } : {}), ...(state === 'waiting' ? { outlineWidth: 2, outlineStyle: 'dashed', outlineColor: colors.accent, outlineOffset: 2 } : {}) }} />;
}
/** Segmented choice with ink track, used for Just me / Family. */
export function Segmented({ options, value, onChange, label }) {
  return <View accessibilityRole="radiogroup" accessibilityLabel={label} style={{ flexDirection: 'row', padding: 3, gap: 3, backgroundColor: colors.text, borderRadius: 4 }}>
    {options.map(option => {
      const on = option.value === value;
      return <Pressable key={option.value} accessibilityRole="radio" accessibilityState={{ checked: on }} onPress={() => onChange(option.value)} style={{ flex: 1, minHeight: 40, borderRadius: 2, alignItems: 'center', justifyContent: 'center', backgroundColor: on ? colors.surface : 'transparent' }}>
        <Text style={{ fontFamily: fonts.pixel, fontSize: 15, color: on ? colors.text : colors.surface }}>{option.label}</Text>
      </Pressable>;
    })}
  </View>;
}
/** Segmented demo/trial meter. */
export function Meter({ filled, total, inverse = false }) {
  return <View style={{ height: 14, borderWidth: 2, borderColor: inverse ? colors.surface : colors.border, padding: 2, flexDirection: 'row', gap: 2, backgroundColor: inverse ? 'transparent' : colors.surface }}>
    {Array.from({ length: total }, (_, index) => <View key={index} style={{ flex: 1, backgroundColor: index < filled ? colors.accent : 'transparent' }} />)}
  </View>;
}
