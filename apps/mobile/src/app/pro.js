import { useEffect, useRef, useState, useSyncExternalStore } from 'react';
import { Linking, Modal, Platform, Pressable, ScrollView, Text, View, useWindowDimensions } from 'react-native';
import { router, useLocalSearchParams } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';
import config from '../../../../config/monetization.json';
import ControllerPreview from '../ControllerPreview';
import { connection } from '../connection';
import { setupComplete } from '../onboarding-core';
import { onboarding } from '../onboarding';
import { familyAvailable, planOptions } from '../purchases/core';
import { purchases } from '../purchases/store';
import { BackButton, Button, Segmented, colors, fonts, scheme, ui } from '../ui/design';

const ios = Platform.OS === 'ios';
const FEATURES = [
  { tag: '●', color: '#30D158', title: 'Setup checks itself', detail: 'Pairing and the gamepad light up on their own.' },
  { tag: '⇄', color: '#0A64D8', title: 'Rearrange everything', detail: 'Move, resize and remap any control. Start from Xbox or a preset.' },
  { tag: '▭', color: '#5E5CE6', title: 'Mac, Windows, Linux', detail: 'One small receiver. Your game keeps running on your computer.' },
  { tag: '◉', color: '#FF9F0A', title: 'Talk to type in chat', detail: 'Dictate chat in supported games, no keyboard needed.' },
  { tag: '✓', color: '#FF453A', title: 'Nothing gets stuck', detail: 'Lose Wi-Fi and every button releases. Your character stops.' },
];
const STEPS = ['Controller', 'Setup', 'Plans'];

export default function Paywall() {
  const { restore } = useLocalSearchParams();
  const purchase = useSyncExternalStore(purchases.subscribe, purchases.snapshot);
  const { width, height } = useWindowDimensions();
  const landscape = width > height;
  const [slide, setSlide] = useState(0);
  const [audience, setAudience] = useState('individual');
  const [choice, setChoice] = useState({ individual: 'yearly', family: 'yearly' });
  const [full, setFull] = useState(false);
  const [pageWidth, setPageWidth] = useState(0);
  /** @type {import('react').RefObject<any>} */
  const pager = useRef(null);
  const options = planOptions({ catalog: purchase.catalog, config, audience, platform: Platform.OS });
  const option = options.find(item => item.plan === choice[audience]) ?? options[0];
  const active = purchase.status === 'active';

  function leave() {
    const setup = onboarding.snapshot();
    if (!setup.tourDone || (!setup.dismissed && !setupComplete(setup))) router.replace('/');
    else if (router.canGoBack()) router.back();
    else router.replace('/');
  }
  useEffect(() => {
    connection.pausePlay();
    void (restore === '1' ? purchases.restore() : purchases.refresh());
  }, [restore]);
  useEffect(() => { if (active && restore === '1') leave(); }, [active, restore]);
  function go(index) {
    setSlide(index);
    if (pageWidth) pager.current?.scrollTo({ x: index * pageWidth, animated: true });
  }
  async function buy() {
    if (active) { leave(); return; }
    await purchases.buy(option.id);
    if (purchases.snapshot().status === 'active') leave();
  }

  const per = option.plan === 'yearly' ? '/year' : option.plan === 'weekly' ? '/week' : '';
  const lifetime = option.plan === 'lifetime';
  const priceLine = active ? 'Your plan is active.' : lifetime ? `${option.price} once` : option.trial ? `${option.trialDays} days free, then ${option.price}${per}` : `${option.price}${per}`;
  const cta = active ? 'Continue' : !option.available ? 'Plans unavailable' : lifetime ? `Buy Lifetime · ${option.price}` : option.trial ? 'Start free trial' : `Subscribe · ${option.price}${per}`;
  const terms = active ? '' : lifetime
    ? `Charged once today${ios ? ' to your Apple ID' : ' to your Google account'}. No subscription. Buying Lifetime does not cancel an existing subscription.`
    : `${option.trial ? `Free for ${option.trialDays} days, then ` : ''}${option.price}${per}, renewing until cancelled. ${ios ? 'Cancel at least 24 hours before the trial or period ends in App Store subscriptions. Charged to your Apple ID.' : 'Cancel anytime in Google Play before the trial or period ends. Charged to your Google account.'}${option.family ? ' Shared with up to 5 family members through Family Sharing.' : ''}`;

  const slides = [
    <View key="controller" style={{ flex: 1, gap: 10 }}>
      <Text accessibilityRole="header" style={[ui.title, { fontSize: landscape ? 26 : 30, lineHeight: landscape ? 28 : 32 }]}>Your game, under your thumbs.</Text>
      <PreviewCard width={Math.min(landscape ? 440 : pageWidth || width - 40, 520)} onFull={() => setFull(true)} />
      <Text style={ui.body}>Label any button, hold a bumper for a second layer, and move anything that doesn’t sit right.</Text>
    </View>,
    <View key="setup" style={{ flex: 1, gap: 10 }}>
      <Text accessibilityRole="header" style={[ui.title, { fontSize: landscape ? 26 : 30, lineHeight: landscape ? 28 : 32 }]}>Couch to game in minutes.</Text>
      <View style={{ flexDirection: landscape ? 'row' : 'column', flexWrap: landscape ? 'wrap' : 'nowrap', gap: 10 }}>
        {FEATURES.map(feature => <View key={feature.title} style={[ui.card, { padding: 12, gap: 12, flexBasis: landscape ? '47%' : 'auto', flexGrow: 1, flexDirection: 'row', alignItems: 'center' }]}>
          <View style={{ width: 30, height: 30, borderRadius: 8, backgroundColor: feature.color, alignItems: 'center', justifyContent: 'center' }}><Text style={{ color: '#fff', fontFamily: fonts.bodyBold, fontSize: 14 }}>{feature.tag}</Text></View>
          <View style={{ flex: 1, gap: 2 }}><Text style={{ color: colors.text, fontFamily: fonts.bodyBold, fontSize: 15, lineHeight: 19 }}>{feature.title}</Text><Text style={ui.muted}>{feature.detail}</Text></View>
        </View>)}
      </View>
    </View>,
    <View key="plans" style={{ flex: 1, gap: 8 }}>
      <Text accessibilityRole="header" style={[ui.title, { fontSize: landscape ? 26 : 30, lineHeight: landscape ? 28 : 32 }]}>Seven days, on us.</Text>
      <View style={{ flexDirection: landscape ? 'row' : 'column', gap: 6 }}>
        {[['D1', 'Everything unlocked today'], ['D5', ios ? 'Cancel anytime before day 7' : 'Cancel in Google Play before day 7'], ['D7', lifetime ? 'Lifetime has no trial' : 'Trial ends, your plan starts']].map(([day, text]) => <View key={day} style={{ flex: landscape ? 1 : 0, flexDirection: 'row', gap: 8, alignItems: 'center' }}>
          <View style={{ width: 28, height: 28, borderRadius: 14, backgroundColor: day === 'D1' ? colors.accent : colors.raised, alignItems: 'center', justifyContent: 'center' }}><Text style={{ fontFamily: fonts.bodyBold, fontSize: 12, color: day === 'D1' ? '#fff' : colors.text }}>{day.slice(1)}</Text></View>
          <Text style={[ui.small, { fontFamily: fonts.bodyMedium, color: colors.text, flex: 1 }]}>{text}</Text>
        </View>)}
      </View>
      {familyAvailable(Platform.OS) && <Segmented label="Who is it for" value={audience} onChange={setAudience} options={[{ value: 'individual', label: 'Just me' }, { value: 'family', label: landscape ? 'Family · 6' : 'Family · up to 6' }]} />}
      <View accessibilityRole="radiogroup" accessibilityLabel="Plan" style={{ gap: 6 }}>
        {options.map(item => <PlanCard key={item.id} option={item} selected={item.plan === option.plan} compact={landscape} onPress={() => setChoice(current => ({ ...current, [audience]: item.plan }))} />)}
      </View>
    </View>,
  ];

  const steps = <View accessibilityRole="tablist" style={{ flexDirection: 'row', gap: 6 }}>
    {STEPS.map((label, index) => <Pressable key={label} accessibilityRole="tab" accessibilityState={{ selected: index === slide }} onPress={() => go(index)}
      style={{ flex: 1, minHeight: 32, alignItems: 'center', justifyContent: 'center', gap: 6 }}>
      <View style={{ alignSelf: 'stretch', height: 4, borderRadius: 2, backgroundColor: index <= slide ? colors.accent : colors.raised }} />
      <Text style={[ui.small, { fontFamily: index === slide ? fonts.bodyBold : fonts.body, color: index === slide ? colors.text : colors.muted }]}>{label}</Text>
    </Pressable>)}
  </View>;
  const purchaseBlock = <View style={{ gap: 8 }}>
    <View style={{ flexDirection: 'row', alignItems: 'baseline', justifyContent: 'space-between', gap: 8 }}>
      <Text style={[ui.heading, { fontSize: 17, flexShrink: 1 }]}>{priceLine}</Text>
      {slide < 2 && !active && <Pressable accessibilityRole="button" onPress={() => go(2)} style={{ minHeight: 32, justifyContent: 'center' }}><Text style={[ui.small, { fontFamily: fonts.bodyMedium, fontSize: 14, color: colors.link }]}>See all plans</Text></Pressable>}
    </View>
    <Button disabled={purchase.busy || (!active && !option.available)} onPress={buy} testID="paywall-cta">{purchase.busy ? 'Contacting store…' : cta}</Button>
    {!!terms && <Text style={[ui.small, { textAlign: landscape ? 'left' : 'center' }]}>{terms}</Text>}
    {!!purchase.error && <Text accessibilityRole="alert" style={ui.error}>{purchase.error}</Text>}
    {!option.available && !active && <Text style={ui.small}>{purchase.unavailable ? 'Purchases aren’t available in this build yet. Store prices appear here once the store responds.' : 'This plan isn’t available in your store yet.'}</Text>}
    {__DEV__ && !active && <Button ghost compact onPress={() => { purchases.bypass(); leave(); }}>Continue without a plan (development build)</Button>}
    <View style={{ flexDirection: 'row', justifyContent: landscape ? 'space-between' : 'center', gap: 18 }}>
      <LinkText onPress={() => purchases.restore()}>Restore</LinkText>
      <LinkText onPress={() => Linking.openURL(config.termsURL)}>Terms</LinkText>
      <LinkText onPress={() => Linking.openURL(config.privacyURL)}>Privacy</LinkText>
    </View>
  </View>;
  const header = <View style={{ flexDirection: 'row', alignItems: 'center', gap: 10, minHeight: 44 }}>
    <BackButton onPress={() => router.canGoBack() ? router.back() : router.replace('/welcome')} />
    <Text style={[ui.label, { flex: 1, textAlign: 'right' }]}>{active ? 'Your plan' : `7 days free · ${slide + 1} of 3`}</Text>
  </View>;
  const pagerView = <ScrollView ref={pager} horizontal pagingEnabled showsHorizontalScrollIndicator={false} onLayout={event => setPageWidth(event.nativeEvent.layout.width)}
    onMomentumScrollEnd={event => pageWidth && setSlide(Math.round(event.nativeEvent.contentOffset.x / pageWidth))} style={{ flex: 1, overflow: 'hidden' }}>
    {slides.map((content, index) => <ScrollView key={index} style={{ width: pageWidth || width }} contentContainerStyle={{ paddingRight: landscape ? 4 : 0, flexGrow: 1 }} accessibilityLabel={`${index + 1} of 3`}>{content}</ScrollView>)}
  </ScrollView>;

  return <SafeAreaProvider><SafeAreaView style={{ flex: 1, backgroundColor: colors.background }}>
    <StatusBar style={scheme === 'light' ? 'dark' : 'light'} />
    {landscape ? <View style={{ flex: 1, flexDirection: 'row', gap: 20, paddingHorizontal: 20, paddingVertical: 10 }}>
      <View style={{ flex: 1, gap: 10 }}>{header}{pagerView}</View>
      <View style={{ width: 260, gap: 10 }}>{steps}<View style={[ui.card, { flex: 1, padding: 12 }]}><ScrollView contentContainerStyle={{ gap: 8 }}>{purchaseBlock}</ScrollView></View></View>
    </View> : <View style={{ flex: 1, paddingHorizontal: 20, paddingBottom: 8, gap: 12 }}>
      {header}{pagerView}{steps}{purchaseBlock}
    </View>}
    <FullScreenPreview visible={full} onClose={() => setFull(false)} onStart={() => { setFull(false); go(2); }} />
  </SafeAreaView></SafeAreaProvider>;
}

function LinkText({ children, onPress }) {
  return <Pressable accessibilityRole="link" onPress={onPress} style={{ minHeight: 32, justifyContent: 'center' }}><Text style={[ui.small, { fontFamily: fonts.bodyMedium, fontSize: 13, color: colors.link }]}>{children}</Text></Pressable>;
}
function PreviewCard({ width, onFull }) {
  const w = Math.max(200, width), h = Math.round(w * 340 / 760);
  return <View style={{ width: w, height: h, borderRadius: 18, borderCurve: 'continuous', overflow: 'hidden' }}>
    <ControllerPreview width={w} height={h} />
    <Pressable accessibilityRole="button" accessibilityLabel="View the controller full screen" onPress={onFull}
      style={{ position: 'absolute', right: 8, top: 8, minHeight: 30, paddingHorizontal: 12, borderRadius: 15, backgroundColor: 'rgba(58,58,60,0.96)', justifyContent: 'center' }}>
      <Text style={{ fontFamily: fonts.bodyBold, fontSize: 12, color: '#F2F2F7' }}>Full screen</Text>
    </Pressable>
  </View>;
}
function PlanCard({ option, selected, compact, onPress }) {
  const unit = option.plan === 'yearly' ? 'per year' : option.plan === 'weekly' ? 'per week' : 'one time';
  const sub = option.plan === 'lifetime' ? 'Pay once · no trial' : `${option.trial ? `${option.trialDays} days free · ` : ''}${option.plan === 'yearly' && option.perWeek ? `${option.perWeek} a week` : 'cancel anytime'}`;
  return <Pressable accessibilityRole="radio" accessibilityState={{ checked: selected }} accessibilityLabel={`${option.plan}, ${option.price} ${unit}`} onPress={onPress}
    style={{ flexDirection: 'row', alignItems: 'center', gap: 12, minHeight: compact ? 50 : 60, paddingHorizontal: 14, paddingVertical: 8, borderRadius: 14, borderCurve: 'continuous', backgroundColor: colors.surface, borderWidth: 2, borderColor: selected ? colors.accent : 'transparent' }}>
    <View style={{ width: 22, height: 22, borderRadius: 11, borderWidth: 2, borderColor: selected ? colors.accent : colors.grip, alignItems: 'center', justifyContent: 'center' }}>{selected && <View style={{ width: 12, height: 12, borderRadius: 6, backgroundColor: colors.accent }} />}</View>
    <View style={{ flex: 1, gap: 1 }}>
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
        <Text style={{ color: colors.text, fontFamily: fonts.bodyBold, fontSize: 16 }}>{option.plan === 'yearly' ? 'Yearly' : option.plan === 'weekly' ? 'Weekly' : 'Lifetime'}</Text>
        {!!option.save && <Text style={{ fontFamily: fonts.bodyBold, fontSize: 11, color: '#fff', paddingHorizontal: 8, paddingVertical: 2, borderRadius: 9, overflow: 'hidden', backgroundColor: colors.accent }}>{option.save}</Text>}
      </View>
      <Text style={ui.muted}>{sub}</Text>
    </View>
    <View style={{ alignItems: 'flex-end' }}><Text style={{ color: colors.text, fontFamily: fonts.bodyBold, fontSize: 16 }}>{option.price}</Text><Text style={ui.muted}>{unit}</Text></View>
  </Pressable>;
}
// Upright phones turn the preview sideways, the way the controller is held.
function FullScreenPreview({ visible, onClose, onStart }) {
  const { width, height } = useWindowDimensions();
  const portrait = height > width;
  const w = portrait ? height : width, h = portrait ? width : height;
  return <Modal visible={visible} animationType="fade" supportedOrientations={['portrait', 'landscape']} onRequestClose={onClose}>
    <View style={{ flex: 1, backgroundColor: '#1C1C1E' }}>
      <View style={{ position: 'absolute', width: w, height: h, left: (width - w) / 2, top: (height - h) / 2, transform: portrait ? [{ rotate: '90deg' }] : [] }}>
        <View style={{ position: 'absolute', left: 0, top: 60 }}><ControllerPreview width={w} height={h - 64} interactive /></View>
        <View style={{ position: 'absolute', left: 44, right: 44, top: 12, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' }}>
          <Text style={{ fontFamily: fonts.bodyBold, fontSize: 12, color: '#F2F2F7', backgroundColor: 'rgba(58,58,60,0.96)', paddingHorizontal: 12, paddingVertical: 6, borderRadius: 14, overflow: 'hidden' }}>Preview · tap a modifier</Text>
          <Button compact onPress={onStart}>Start free trial</Button>
          <Pressable accessibilityRole="button" accessibilityLabel="Close preview" onPress={onClose} style={{ width: 44, height: 44, borderRadius: 22, backgroundColor: 'rgba(58,58,60,0.96)', alignItems: 'center', justifyContent: 'center' }}><Text style={{ fontFamily: fonts.bodyBold, fontSize: 17, color: '#F2F2F7' }}>✕</Text></Pressable>
        </View>
      </View>
    </View>
  </Modal>;
}
