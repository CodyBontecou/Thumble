import { useEffect, useSyncExternalStore } from 'react';
import { Linking, Platform, Pressable, ScrollView, Text, View, useWindowDimensions } from 'react-native';
import { router } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';
import config from '../../../../config/monetization.json';
import { connection } from '../connection';
import { familyAvailable, planOptions } from '../purchases/core';
import { purchases } from '../purchases/store';
import { Bullet, Button, Eyebrow, Wordmark, colors, fonts, scheme, ui } from '../ui/design';

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
    ? { badge: 'Payment issue', title: 'Your payment didn’t go through.', body: `${ios ? 'The App Store' : 'Google Play'} couldn’t renew your plan. Update your payment method there and Thumble unlocks as soon as it renews.` }
    : { badge: 'Paused', title: 'Your free days or plan have ended.', body: `Pick a plan to keep playing. Lifetime pays once and never renews. New trials depend on your ${ios ? 'App Store' : 'Google Play'} account.` };
  const message = <View style={{ gap: 10, flex: landscape ? 1 : 0 }}>
    <Eyebrow inverse>{copy.badge}</Eyebrow>
    <Text accessibilityRole="header" style={[ui.title, { fontSize: landscape ? 28 : 32, lineHeight: landscape ? 29 : 33 }]}>{copy.title}</Text>
    <Text style={ui.muted}>{copy.body}</Text>
    <Bullet>All buttons released. Your character has stopped.</Bullet>
    <Bullet>Pairing, controllers and calibration are kept.</Bullet>
    {!!purchase.error && <Text accessibilityRole="alert" style={ui.error}>{purchase.error}</Text>}
  </View>;
  const plans = <View style={{ gap: 8, width: landscape ? 240 : 'auto' }}>
    <Text style={ui.caption}>{billing ? 'Or switch plan' : 'Keep playing'}</Text>
    {options.map(option => <Pressable key={option.id} accessibilityRole="button" onPress={() => router.push('/pro')}
      style={({ pressed }) => ({ flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', minHeight: 52, paddingHorizontal: 16, borderRadius: 12, borderCurve: 'continuous', backgroundColor: pressed ? colors.raised : colors.surface })}>
      <View><Text style={{ color: colors.text, fontFamily: fonts.bodyBold, fontSize: 16 }}>{option.plan === 'yearly' ? 'Yearly' : option.plan === 'weekly' ? 'Weekly' : 'Lifetime'}</Text><Text style={ui.muted}>{option.plan === 'yearly' && option.perWeek ? `${option.perWeek} a week` : option.plan === 'weekly' ? 'cancel anytime' : 'pay once'}</Text></View>
      <Text style={{ color: colors.text, fontFamily: fonts.bodyBold, fontSize: 16 }}>{option.price}</Text>
    </Pressable>)}
    <Button onPress={() => billing ? Linking.openURL(manageURL) : router.push('/pro')}>{billing ? (ios ? 'Fix payment' : 'Fix in Play') : 'Choose a plan'}</Button>
    <View style={{ flexDirection: 'row', justifyContent: 'space-between' }}>
      <Pressable accessibilityRole="button" disabled={purchase.busy} onPress={() => purchases.restore()} style={{ minHeight: 40, justifyContent: 'center' }}><Text style={[ui.small, { fontFamily: fonts.bodyMedium, fontSize: 14, color: colors.link }]}>Restore purchase</Text></Pressable>
      {billing && <Pressable accessibilityRole="link" onPress={() => Linking.openURL(manageURL)} style={{ minHeight: 40, justifyContent: 'center' }}><Text style={[ui.small, { fontFamily: fonts.bodyMedium, fontSize: 14, color: colors.link }]}>{ios ? 'Manage subscription' : 'Manage in Google Play'}</Text></Pressable>}
    </View>
    <Text style={[ui.small, { textAlign: 'center' }]}>{familyAvailable(Platform.OS) ? 'Family plans from $1.99/week' : 'Plans from $0.99/week'}</Text>
  </View>;
  return <SafeAreaProvider><SafeAreaView style={{ flex: 1, backgroundColor: colors.background }}>
    <StatusBar style={scheme === 'light' ? 'dark' : 'light'} />
    {landscape ? <View style={{ flex: 1, alignItems: 'center', justifyContent: 'center', padding: 16 }}>
      <View accessibilityViewIsModal style={[ui.card, { flexDirection: 'row', gap: 18, width: '100%', maxWidth: 640, maxHeight: '100%' }]}>
        <ScrollView style={{ flex: 1 }}>{message}</ScrollView>{plans}
      </View>
    </View> : <ScrollView contentContainerStyle={{ padding: 20, gap: 14, flexGrow: 1 }}>
      <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', minHeight: 44 }}><Wordmark size={22} /></View>
      {message}{plans}
    </ScrollView>}
  </SafeAreaView></SafeAreaProvider>;
}
