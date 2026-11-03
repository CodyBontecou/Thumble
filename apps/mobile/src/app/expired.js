import { useEffect, useSyncExternalStore } from 'react';
import { Image, Linking, Platform, Pressable, ScrollView, Text, View, useWindowDimensions } from 'react-native';
import { router } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';
import config from '../../../../config/monetization.json';
import { connection } from '../connection';
import { familyAvailable, planOptions } from '../purchases/core';
import { purchases } from '../purchases/store';
import { Bullet, Button, Eyebrow, Wordmark, colors, fonts, ui } from '../ui/design';
import icon from '../../assets/icon.png';

const ios = Platform.OS === 'ios';
const manageURL = ios ? 'https://apps.apple.com/account/subscriptions' : 'https://play.google.com/store/account/subscriptions';

// Shown when a trial or plan lapses. The controller has already released every
// input; pairing, controllers and calibration stay on this phone.
export default function ExpiredScreen() {
  const purchase = useSyncExternalStore(purchases.subscribe, purchases.snapshot);
  const { width, height } = useWindowDimensions();
  const landscape = width > height;
  const billing = purchase.status === 'billing';
  const options = planOptions({ catalog: purchase.catalog, config, platform: Platform.OS });
  useEffect(() => { connection.pausePlay(); void purchases.refresh(); }, []);
  useEffect(() => { if (purchase.status === 'active') router.dismissTo('/'); }, [purchase.status]);
  const copy = billing
    ? { badge: 'PAYMENT ISSUE', title: 'Your payment didn’t go through.', body: `${ios ? 'The App Store' : 'Google Play'} couldn’t renew your plan. Update your payment method there and Thumble unlocks as soon as it renews.` }
    : { badge: 'PLAN ENDED', title: 'Your free days or plan have ended.', body: `Pick a plan to keep playing. Lifetime pays once and never renews. New trials depend on your ${ios ? 'App Store' : 'Google Play'} account.` };
  const message = <View style={{ gap: 10, flex: landscape ? 1 : 0 }}>
    <Eyebrow inverse>{copy.badge}</Eyebrow>
    <Text accessibilityRole="header" style={[ui.title, { fontSize: landscape ? 28 : 32, lineHeight: landscape ? 29 : 33 }]}>{copy.title}</Text>
    <Text style={ui.muted}>{copy.body}</Text>
    <Bullet>All buttons released. Your character has stopped.</Bullet>
    <Bullet>Pairing, controllers and calibration are kept.</Bullet>
    {!!purchase.error && <Text accessibilityRole="alert" style={ui.error}>{purchase.error}</Text>}
  </View>;
  const plans = <View style={{ gap: 8, width: landscape ? 240 : 'auto' }}>
    <Text style={ui.label}>{billing ? 'OR SWITCH PLAN' : 'KEEP PLAYING'}</Text>
    {options.map(option => <Pressable key={option.id} accessibilityRole="button" onPress={() => router.push('/pro')}
      style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', minHeight: 48, paddingHorizontal: 12, borderRadius: 4, borderWidth: 3, borderColor: colors.border, backgroundColor: option.plan === 'yearly' ? colors.surface : colors.raised, ...(option.plan === 'yearly' ? { boxShadow: `3px 3px 0px ${colors.border}`, outlineWidth: 3, outlineColor: colors.accent, outlineOffset: -7, outlineStyle: 'solid' } : {}) }}>
      <View><Text style={[ui.heading, { fontSize: 16 }]}>{option.plan === 'yearly' ? 'Yearly' : option.plan === 'weekly' ? 'Weekly' : 'Lifetime'}</Text><Text style={ui.muted}>{option.plan === 'yearly' && option.perWeek ? `${option.perWeek} a week` : option.plan === 'weekly' ? 'cancel anytime' : 'pay once'}</Text></View>
      <Text style={[ui.heading, { fontSize: 16 }]}>{option.price}</Text>
    </Pressable>)}
    <Button onPress={() => billing ? Linking.openURL(manageURL) : router.push('/pro')}>{billing ? (ios ? 'Fix payment' : 'Fix in Play') : 'Choose a plan'}</Button>
    <View style={{ flexDirection: 'row', justifyContent: 'space-between' }}>
      <Pressable accessibilityRole="button" disabled={purchase.busy} onPress={() => purchases.restore()} style={{ minHeight: 40, justifyContent: 'center' }}><Text style={[ui.small, { fontFamily: fonts.bodyBold, color: colors.text, textDecorationLine: 'underline' }]}>Restore purchase</Text></Pressable>
      {billing && <Pressable accessibilityRole="link" onPress={() => Linking.openURL(manageURL)} style={{ minHeight: 40, justifyContent: 'center' }}><Text style={[ui.small, { fontFamily: fonts.bodyBold, color: colors.text, textDecorationLine: 'underline' }]}>{ios ? 'Manage subscription' : 'Manage in Google Play'}</Text></Pressable>}
    </View>
    <Text style={[ui.small, { textAlign: 'center' }]}>{familyAvailable(Platform.OS) ? 'Family plans from $1.99/week' : 'Plans from $0.99/week'}</Text>
  </View>;
  return <SafeAreaProvider><SafeAreaView style={{ flex: 1, backgroundColor: landscape ? '#17191b' : colors.background }}>
    <StatusBar style={landscape ? 'light' : 'dark'} />
    {landscape ? <View style={{ flex: 1, alignItems: 'center', justifyContent: 'center', padding: 16 }}>
      <View accessibilityViewIsModal style={[ui.card, { flexDirection: 'row', gap: 18, width: '100%', maxWidth: 640, maxHeight: '100%', boxShadow: '6px 6px 0px #000000' }]}>
        <ScrollView style={{ flex: 1 }}>{message}</ScrollView>{plans}
      </View>
    </View> : <ScrollView contentContainerStyle={{ padding: 20, gap: 14, flexGrow: 1 }}>
      <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', minHeight: 44 }}><Wordmark size={22} /></View>
      <View style={{ alignSelf: 'center' }}>
        <Image source={icon} accessible={false} style={{ width: 110, height: 110, opacity: 0.7 }} />
        <Text style={[ui.label, { position: 'absolute', right: -18, bottom: 10, fontSize: 10, backgroundColor: colors.text, color: colors.accent, paddingHorizontal: 6, paddingVertical: 3, overflow: 'hidden' }]}>PAUSED</Text>
      </View>
      {message}{plans}
    </ScrollView>}
  </SafeAreaView></SafeAreaProvider>;
}
