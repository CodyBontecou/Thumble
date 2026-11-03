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
import { BackButton, Button, Eyebrow, Segmented, colors, fonts, ui } from '../ui/design';

const ios = Platform.OS === 'ios';
const FEATURES = [
  { tag: 'AUTO', title: 'Setup checks itself', detail: 'Pairing, gamepad and spell labels light up on their own.' },
  { tag: 'ANY PC', title: 'Mac, Windows, Linux', detail: 'One small receiver. WoW keeps running on your computer.' },
  { tag: 'VOICE', title: 'Talk to type in chat', detail: 'Dictate a message to your group without a keyboard.' },
  { tag: 'SAFE', title: 'Nothing gets stuck', detail: 'Lose Wi-Fi and every button releases. Your character stops.' },
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
    if (!setup.dismissed && !setupComplete(setup)) router.replace('/connect');
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
      <Text accessibilityRole="header" style={[ui.title, { fontSize: landscape ? 26 : 30, lineHeight: landscape ? 28 : 32 }]}>Your spells, on a real ConsolePort pad.</Text>
      <PreviewCard width={Math.min(landscape ? 440 : pageWidth || width - 40, 520)} onFull={() => setFull(true)} />
      <Text style={ui.body}>Every button shows the spell it casts after a /reload. Hold a modifier for more.</Text>
    </View>,
    <View key="setup" style={{ flex: 1, gap: 10 }}>
      <Text accessibilityRole="header" style={[ui.title, { fontSize: landscape ? 26 : 30, lineHeight: landscape ? 28 : 32 }]}>Couch to raid in three lights.</Text>
      <View style={{ flexDirection: landscape ? 'row' : 'column', flexWrap: 'wrap', gap: 10 }}>
        {FEATURES.map(feature => <View key={feature.tag} style={[ui.card, { padding: 10, gap: 4, flexBasis: landscape ? '47%' : 'auto', flexGrow: 1, flexDirection: landscape ? 'column' : 'row', alignItems: landscape ? 'flex-start' : 'center' }]}>
          <Eyebrow inverse>{feature.tag}</Eyebrow>
          <View style={{ flex: landscape ? 0 : 1, gap: 2 }}><Text style={[ui.heading, { fontSize: 16, lineHeight: 19 }]}>{feature.title}</Text><Text style={ui.muted}>{feature.detail}</Text></View>
        </View>)}
      </View>
    </View>,
    <View key="plans" style={{ flex: 1, gap: 8 }}>
      <Text accessibilityRole="header" style={[ui.title, { fontSize: landscape ? 26 : 30, lineHeight: landscape ? 28 : 32 }]}>Seven days, on us.</Text>
      <View style={{ flexDirection: landscape ? 'row' : 'column', gap: 6 }}>
        {[['D1', 'Everything unlocked today'], ['D5', ios ? 'Cancel anytime before day 7' : 'Cancel in Google Play before day 7'], ['D7', lifetime ? 'Lifetime has no trial' : 'Trial ends, your plan starts']].map(([day, text]) => <View key={day} style={{ flex: landscape ? 1 : 0, flexDirection: 'row', gap: 8, alignItems: 'center' }}>
          <Text style={[ui.label, { backgroundColor: colors.text, color: colors.accent, paddingHorizontal: 5, paddingVertical: 2, borderRadius: 2, overflow: 'hidden' }]}>{day}</Text>
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
      style={{ flex: 1, minHeight: 44, borderRadius: 4, borderWidth: 3, borderColor: colors.border, alignItems: 'center', justifyContent: 'center', backgroundColor: index === slide ? colors.accent : index < slide ? colors.surface : colors.raised, ...(index === slide ? { boxShadow: `3px 3px 0px ${colors.border}` } : { transform: [{ translateX: 3 }, { translateY: 3 }] }) }}>
      <Text style={ui.label}>{index + 1}</Text><Text style={[ui.small, { fontFamily: fonts.bodyBold, color: colors.text }]}>{label}</Text>
    </Pressable>)}
  </View>;
  const purchaseBlock = <View style={{ gap: 8 }}>
    <View style={{ flexDirection: 'row', alignItems: 'baseline', justifyContent: 'space-between', gap: 8 }}>
      <Text style={[ui.heading, { fontSize: 17, flexShrink: 1 }]}>{priceLine}</Text>
      {slide < 2 && !active && <Pressable accessibilityRole="button" onPress={() => go(2)} style={{ minHeight: 32, justifyContent: 'center' }}><Text style={[ui.small, { fontFamily: fonts.bodyBold, color: colors.text, textDecorationLine: 'underline' }]}>See all plans</Text></Pressable>}
    </View>
    <Button disabled={purchase.busy || (!active && !option.available)} onPress={buy} testID="paywall-cta">{purchase.busy ? 'Contacting store…' : cta}</Button>
    {!!terms && <Text style={[ui.small, { textAlign: landscape ? 'left' : 'center', color: colors.text }]}>{terms}</Text>}
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
    <Text style={[ui.label, { flex: 1 }]}>{active ? 'YOUR PLAN' : `7 DAYS FREE · ${slide + 1} OF 3`}</Text>
  </View>;
  const pagerView = <ScrollView ref={pager} horizontal pagingEnabled showsHorizontalScrollIndicator={false} onLayout={event => setPageWidth(event.nativeEvent.layout.width)}
    onMomentumScrollEnd={event => pageWidth && setSlide(Math.round(event.nativeEvent.contentOffset.x / pageWidth))} style={{ flex: 1, overflow: 'hidden' }}>
    {slides.map((content, index) => <ScrollView key={index} style={{ width: pageWidth || width }} contentContainerStyle={{ paddingRight: landscape ? 4 : 0, flexGrow: 1 }} accessibilityLabel={`${index + 1} of 3`}>{content}</ScrollView>)}
  </ScrollView>;

  return <SafeAreaProvider><SafeAreaView style={{ flex: 1, backgroundColor: colors.background }}>
    <StatusBar style="dark" />
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
  return <Pressable accessibilityRole="link" onPress={onPress} style={{ minHeight: 32, justifyContent: 'center' }}><Text style={[ui.small, { fontFamily: fonts.bodyBold, color: colors.text, textDecorationLine: 'underline' }]}>{children}</Text></Pressable>;
}
function PreviewCard({ width, onFull }) {
  const w = Math.max(200, width), h = Math.round(w * 340 / 760);
  return <View style={{ width: w, height: h, borderWidth: 3, borderColor: colors.border, borderRadius: 6, overflow: 'hidden', boxShadow: `5px 5px 0px ${colors.border}` }}>
    <ControllerPreview width={w - 6} height={h - 6} />
    <Pressable accessibilityRole="button" accessibilityLabel="View the controller full screen" onPress={onFull}
      style={{ position: 'absolute', right: 6, top: 6, minHeight: 32, paddingHorizontal: 8, borderRadius: 4, borderWidth: 2, borderColor: colors.border, backgroundColor: colors.surface, justifyContent: 'center', boxShadow: '2px 2px 0px #000000' }}>
      <Text style={[ui.label, { fontSize: 10 }]}>FULL SCREEN</Text>
    </Pressable>
  </View>;
}
function PlanCard({ option, selected, compact, onPress }) {
  const unit = option.plan === 'yearly' ? 'per year' : option.plan === 'weekly' ? 'per week' : 'one time';
  const sub = option.plan === 'lifetime' ? 'Pay once · no trial' : `${option.trial ? `${option.trialDays} days free · ` : ''}${option.plan === 'yearly' && option.perWeek ? `${option.perWeek} a week` : 'cancel anytime'}`;
  return <Pressable accessibilityRole="radio" accessibilityState={{ checked: selected }} accessibilityLabel={`${option.plan}, ${option.price} ${unit}`} onPress={onPress}
    style={{ flexDirection: 'row', alignItems: 'center', gap: 12, minHeight: compact ? 48 : 58, paddingHorizontal: 12, paddingVertical: 6, borderRadius: 4, borderWidth: 3, borderColor: colors.border, backgroundColor: colors.surface,
      ...(selected ? { boxShadow: `3px 3px 0px ${colors.border}`, outlineWidth: 3, outlineColor: colors.accent, outlineOffset: -7, outlineStyle: 'solid' } : { opacity: 0.85, transform: [{ translateX: 3 }, { translateY: 3 }] }) }}>
    <View style={{ width: 18, height: 18, borderWidth: 3, borderColor: colors.border, backgroundColor: selected ? colors.accent : 'transparent' }} />
    <View style={{ flex: 1, gap: 1 }}>
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
        <Text style={[ui.heading, { fontSize: 17 }]}>{option.plan === 'yearly' ? 'Yearly' : option.plan === 'weekly' ? 'Weekly' : 'Lifetime'}</Text>
        {!!option.save && <Text style={[ui.label, { fontSize: 10, paddingHorizontal: 5, paddingVertical: 1, backgroundColor: colors.accent, borderWidth: 2, borderColor: colors.border }]}>{option.save}</Text>}
      </View>
      <Text style={ui.muted}>{sub}</Text>
    </View>
    <View style={{ alignItems: 'flex-end' }}><Text style={[ui.heading, { fontSize: 18 }]}>{option.price}</Text><Text style={ui.muted}>{unit}</Text></View>
  </Pressable>;
}
// Upright phones turn the preview sideways, the way the controller is held.
function FullScreenPreview({ visible, onClose, onStart }) {
  const { width, height } = useWindowDimensions();
  const portrait = height > width;
  const w = portrait ? height : width, h = portrait ? width : height;
  return <Modal visible={visible} animationType="fade" supportedOrientations={['portrait', 'landscape']} onRequestClose={onClose}>
    <View style={{ flex: 1, backgroundColor: '#17191b' }}>
      <View style={{ position: 'absolute', width: w, height: h, left: (width - w) / 2, top: (height - h) / 2, transform: portrait ? [{ rotate: '90deg' }] : [] }}>
        <View style={{ position: 'absolute', left: 0, top: 60 }}><ControllerPreview width={w} height={h - 64} interactive /></View>
        <View style={{ position: 'absolute', left: 44, right: 44, top: 12, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' }}>
          <Text style={[ui.label, { backgroundColor: colors.surface, paddingHorizontal: 8, paddingVertical: 4, borderWidth: 2, borderColor: colors.border, overflow: 'hidden' }]}>PREVIEW · TAP A MODIFIER</Text>
          <Button compact onPress={onStart}>Start free trial</Button>
          <Pressable accessibilityRole="button" accessibilityLabel="Close preview" onPress={onClose} style={{ width: 44, height: 44, borderRadius: 4, borderWidth: 2, borderColor: colors.border, backgroundColor: colors.surface, alignItems: 'center', justifyContent: 'center' }}><Text style={[ui.heading, { fontSize: 18 }]}>✕</Text></Pressable>
        </View>
      </View>
    </View>
  </Modal>;
}
