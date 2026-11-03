import { useState } from 'react';
import { Image, Platform, Pressable, Text, View, useWindowDimensions } from 'react-native';
import { router } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';
import { Button, Eyebrow, Wordmark, colors, fonts, ui } from '../ui/design';
import { familyAvailable } from '../purchases/core';
import { useSetup } from '../use-setup';
import icon from '../../assets/icon.png';

export default function WelcomeScreen() {
  const { state, save, error } = useSetup();
  const { width, height } = useWindowDimensions();
  const landscape = width > height;
  // The icon art has generous grey margins that blend into the ground.
  const art = landscape ? Math.min(height * 0.95, width * 0.45) : Math.min(width - 32, height * 0.42);
  const [busy, setBusy] = useState(false);
  async function begin(path) {
    if (busy) return;
    setBusy(true);
    if (await save({ welcomeSeen: true })) router.replace(path);
    else setBusy(false);
  }
  const footnote = `MAC · WINDOWS · LINUX${landscape ? '  ·  ' : '\n'}7 DAYS FREE, THEN FROM $0.99/WEEK${familyAvailable(Platform.OS) ? ' · FAMILY PLANS' : ''}`;
  const copy = <View style={{ gap: 12 }}>
    <Eyebrow inverse>FOR WORLD OF WARCRAFT</Eyebrow>
    <Text accessibilityRole="header" style={[ui.title, { fontSize: landscape ? 40 : 38, lineHeight: landscape ? 41 : 39 }]}>{'Eyes on the pull.\nThumbs on your phone.'}</Text>
    <Text style={[ui.body, { maxWidth: 400 }]}>Your ConsolePort controller and spell bars on your phone. WoW keeps running on your computer.</Text>
    {!!error && <Text accessibilityRole="alert" style={ui.error}>{error}</Text>}
  </View>;
  const actions = <View style={{ gap: 12, ...(landscape ? { flexDirection: 'row', alignItems: 'center' } : {}) }}>
    <Button disabled={!state.loaded || busy} onPress={() => begin('/pro')} testID="welcome-start">Start 7 days free</Button>
    <Button secondary disabled={!state.loaded || busy} onPress={() => begin('/pro?restore=1')}>I already have a plan</Button>
  </View>;
  return <SafeAreaProvider><SafeAreaView style={{ flex: 1, backgroundColor: colors.background }}>
    <StatusBar style="dark" />
    {landscape ? <View style={{ flex: 1, paddingHorizontal: 24, paddingVertical: 12 }}>
      <Image source={icon} accessibilityLabel="Thumble pixel controller" style={{ position: 'absolute', right: -8, top: (height - art) / 2 - 24, width: art, height: art }} resizeMode="contain" />
      <Wordmark size={26} />
      <View style={{ flex: 1, justifyContent: 'center', maxWidth: '58%' }}>{copy}</View>
      {actions}
      <Text style={[ui.label, { marginTop: 8, fontSize: 10 }]}>{footnote}</Text>
    </View> : <View style={{ flex: 1, paddingHorizontal: 20, paddingBottom: 8 }}>
      <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', minHeight: 44 }}>
        <Wordmark size={24} />
        <Pressable accessibilityRole="button" onPress={() => begin('/pro?restore=1')} style={{ minHeight: 44, justifyContent: 'center' }}><Text style={ui.label}>RESTORE</Text></Pressable>
      </View>
      <Image source={icon} accessibilityLabel="Thumble pixel controller" style={{ width: art, height: art, alignSelf: 'center', marginTop: 4, marginBottom: -art * 0.14 }} resizeMode="contain" />
      {copy}
      <View style={{ flex: 1 }} />
      <Button disabled={!state.loaded || busy} onPress={() => begin('/pro')} testID="welcome-start">Start 7 days free</Button>
      <Text style={[ui.label, { textAlign: 'center', fontSize: 10, marginTop: 12, fontFamily: fonts.label, color: colors.text }]}>{footnote}</Text>
    </View>}
  </SafeAreaView></SafeAreaProvider>;
}
