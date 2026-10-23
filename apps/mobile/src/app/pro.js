import { useEffect, useSyncExternalStore } from 'react';
import { Linking, Pressable, Text, View } from 'react-native';
import { router, useLocalSearchParams } from 'expo-router';
import config from '../../../../config/monetization.json';
import { purchases } from '../purchases/store';
import { connection } from '../connection';
import { Button, Columns, ControllerPreview, Eyebrow, Page, colors, ui } from '../ui/design';
export default function ProScreen() {
  const store = useSyncExternalStore(purchases.subscribe, purchases.snapshot);
  const access = useSyncExternalStore(connection.subscribeAccess, connection.accessSnapshot);
  const { welcome } = useLocalSearchParams();
  useEffect(() => { connection.pausePlay(); void purchases.refresh(); }, []);
  const owned = access?.pro === true;
  const purchased = store.status === 'owned';
  function leave() { if (welcome) router.replace('/pair'); else if (router.canGoBack()) router.back(); else router.replace('/'); }
  return <Page><Columns>
    <View style={ui.column}><Eyebrow>THUMBLE PRO / LIFETIME ACCESS</Eyebrow><Text accessibilityRole="header" style={ui.title}>{owned ? 'Your controller.\nUnlocked.' : 'Keep playing.\nWithout a limit.'}</Text><Text style={ui.body}>{owned ? 'All features. Unlimited play.' : 'Try every feature for 30 minutes total. Pro removes the time limit.'}</Text><ControllerPreview />
      <Text style={ui.small}>Your agent builds the layout. Every button press is you.</Text>
    </View>
    <View style={ui.column}><View style={ui.card}>
      <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', gap: 16 }}><Text style={ui.heading}>Thumble Pro</Text><Text style={[ui.label, { color: colors.text }]}>ONE TIME</Text></View>
      <Text style={[ui.title, { fontVariant: ['tabular-nums'] }]}>{owned ? 'Unlocked' : store.price || `$${config.basePriceUSD.toFixed(2)} USD`}</Text>
      {!store.price && !owned && <Text style={ui.small}>Base price · local price appears when the store is available.</Text>}
      {['Unlimited controller time', 'One-time purchase. No subscription.'].map(feature => <View key={feature} style={{ flexDirection: 'row', gap: 12 }}><Text style={{ color: colors.text }}>✓</Text><Text style={[ui.body, { color: colors.text, flex: 1 }]}>{feature}</Text></View>)}
      {owned ? <Button onPress={leave}>Return to controller</Button> : purchased ? <Button onPress={() => router.replace('/pair')}>Connect Mac to verify Pro</Button> : <Button disabled={store.busy || !store.price || !purchases.configured()} onPress={() => purchases.act('purchase')}>{store.busy ? 'Contacting store…' : store.price ? `Unlock Pro · ${store.price}` : 'Purchases coming soon'}</Button>}
      <Text style={ui.small}>One-time purchase. No subscription. Restore with the same store account. iOS and Android purchases are separate.</Text>
    </View>
      {!purchases.configured() && <Text style={ui.small}>Purchases aren’t available in this build yet. The full-featured 30-minute demo is available.</Text>}
      {!!store.error && <Text accessibilityRole="alert" style={ui.error}>{store.error}</Text>}
      {!access && purchased && <Text style={ui.body}>Your store purchase is saved. Connect your Mac to verify access.</Text>}
      {!owned && <Button secondary onPress={leave}>{welcome ? 'Try the 30-minute demo' : 'Return to demo'}</Button>}
      <View style={{ flexDirection: 'row', gap: 24, flexWrap: 'wrap' }}>
        <Pressable accessibilityRole="button" disabled={store.busy} onPress={() => purchases.act('restore')} style={{ minHeight: 44, justifyContent: 'center' }}><Text style={{ color: colors.text, fontSize: 14 }}>Restore Purchases</Text></Pressable>
        <Pressable accessibilityRole="button" disabled={store.busy} onPress={() => purchases.refresh()} style={{ minHeight: 44, justifyContent: 'center' }}><Text style={ui.small}>Retry store</Text></Pressable>
        {[['Privacy', config.privacyURL], ['Terms', config.termsURL], ['Support', config.supportURL]].filter(([, url]) => url.startsWith('https://')).map(([label, url]) => <Pressable key={label} accessibilityRole="link" style={{ minHeight: 44, justifyContent: 'center' }} onPress={() => Linking.openURL(url)}><Text style={ui.small}>{label}</Text></Pressable>)}
      </View><Text style={ui.small}>Custom layouts, saved profiles and dictation are included in the demo. Pro only removes the time limit. Layouts use your own agent; dictation depends on device and language.</Text>
    </View>
  </Columns></Page>;
}
