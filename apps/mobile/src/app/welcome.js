import { useState } from 'react';
import { Platform, Pressable, Text, View, useWindowDimensions } from 'react-native';
import { xboxProfile } from '@tapping/controller';
import { router } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';
import { Button, Eyebrow, Wordmark, colors, fonts, pad, scheme, ui } from '../ui/design';
import { familyAvailable } from '../purchases/core';
import { useSetup } from '../use-setup';

export default function WelcomeScreen() {
  const { state, save, error } = useSetup();
  const { width, height } = useWindowDimensions();
  const landscape = width > height;
  // The drawn controller fills most of the width in portrait.
  const art = landscape ? Math.min(height * 0.95, width * 0.45) : Math.min(width - 32, height * 0.42);
  const [busy, setBusy] = useState(false);
  async function begin(path) {
    if (busy) return;
    setBusy(true);
    if (await save({ welcomeSeen: true })) router.replace(path);
    else setBusy(false);
  }
  const footnote = `Mac · Windows · Linux${landscape ? '  ·  ' : '\n'}7 days free, then from $0.99/week${familyAvailable(Platform.OS) ? ' · family plans' : ''}`;
  const copy = <View style={{ gap: 12 }}>
    <Eyebrow>For games on your computer</Eyebrow>
    <Text accessibilityRole="header" style={[ui.title, { fontSize: landscape ? 34 : 34, lineHeight: 40 }]}>{'Eyes on the game.\nThumbs on your phone.'}</Text>
    <Text style={[ui.body, { maxWidth: 420 }]}>A full gamepad on your phone, laid out the way your hands like it. Your game keeps running on your computer.</Text>
    {!!error && <Text accessibilityRole="alert" style={ui.error}>{error}</Text>}
  </View>;
  const actions = <View style={{ gap: 12, ...(landscape ? { flexDirection: 'row', alignItems: 'center' } : {}) }}>
    <Button disabled={!state.loaded || busy} onPress={() => begin('/pro')} testID="welcome-start">Start 7 days free</Button>
    <Button secondary disabled={!state.loaded || busy} onPress={() => begin('/pro?restore=1')}>I already have a plan</Button>
  </View>;
  return <SafeAreaProvider><SafeAreaView style={{ flex: 1, backgroundColor: colors.background }}>
    <StatusBar style={scheme === 'light' ? 'dark' : 'light'} />
    {landscape ? <View style={{ flex: 1, paddingHorizontal: 24, paddingVertical: 12 }}>
      <View style={{ position: 'absolute', right: 24, top: (height - art * 0.46) / 2 - 24 }}><MiniPad width={art} /></View>
      <Wordmark size={26} />
      <View style={{ flex: 1, justifyContent: 'center', maxWidth: '58%' }}>{copy}</View>
      {actions}
      <Text style={[ui.small, { marginTop: 8 }]}>{footnote}</Text>
    </View> : <View style={{ flex: 1, paddingHorizontal: 20, paddingBottom: 8 }}>
      <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', minHeight: 44 }}>
        <Wordmark size={24} />
        <Pressable accessibilityRole="button" onPress={() => begin('/pro?restore=1')} style={{ minHeight: 44, justifyContent: 'center' }}><Text style={{ fontFamily: fonts.bodyMedium, fontSize: 15, color: colors.link }}>Restore</Text></Pressable>
      </View>
      <View style={{ alignSelf: 'center', marginTop: 12, marginBottom: 24 }}><MiniPad width={art} /></View>
      {copy}
      <View style={{ flex: 1 }} />
      <View style={{ gap: 8 }}>
        <Button disabled={!state.loaded || busy} onPress={() => begin('/pro')} testID="welcome-start">Start 7 days free</Button>
        <Button secondary disabled={!state.loaded || busy} onPress={() => begin('/pro?restore=1')}>I already have a plan</Button>
      </View>
      <Text style={[ui.small, { textAlign: 'center', marginTop: 12 }]}>{footnote}</Text>
    </View>}
  </SafeAreaView></SafeAreaProvider>;
}

/** A drawing of the default Xbox layout, scaled to fit. */
function MiniPad({ width }) {
  const height = Math.round(width * 0.46);
  return <View accessibilityRole="image" accessibilityLabel="Thumble controller in the default Xbox layout" style={{ width, height, borderRadius: 22, borderCurve: 'continuous', backgroundColor: pad.ground, overflow: 'hidden' }}>
    {xboxProfile.controls.map(control => {
      const { x, y, width: w, height: h } = control.frame;
      const box = { left: x * width, top: y * height, width: w * width, height: h * height };
      const d = Math.min(box.width, box.height);
      const stick = control.type === 'stick', wide = control.type === 'trigger' || control.id === 'lb' || control.id === 'rb';
      return <View key={control.id} style={{ position: 'absolute', ...box, alignItems: 'center', justifyContent: 'center' }}>
        <View style={{ width: wide ? box.width : d, height: wide ? box.height : d, borderRadius: wide ? 6 : d / 2, backgroundColor: control.id === 'a' ? pad.accent : pad.key, alignItems: 'center', justifyContent: 'center' }}>
          {stick && <View style={{ width: d * 0.48, height: d * 0.48, borderRadius: d, backgroundColor: pad.cap }} />}
        </View>
      </View>;
    })}
  </View>;
}
