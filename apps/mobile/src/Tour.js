import { useEffect, useRef, useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import { router } from 'expo-router';
import { TOUR_PRESETS } from './layout-editor';
import { connection } from './connection';
import { forgetTourDraft, sendDraftToComputer, tourDraft } from './layout-drafts';
import { fonts, pad } from './ui/design';

// The first-run tour runs on the real landscape controller. Chapter one
// (preset, move, resize, remap) happens in the layout editor; this overlay owns
// the intro, the preset choice, connecting and the linked moment.
const resume = { step: 'intro' };
const card = '#F2F2F7', ink = '#1D1D1F', inkMuted = '#515154', blue = '#0A64D8';

/**
 * @param {{ state: any, save: (patch: any) => Promise<boolean>, connected: boolean, connecting: boolean, rtt: number | null,
 *   pill: { x: number, y: number, width: number, height: number } | null, onRelease: () => void }} props
 */
export default function Tour({ state, save, connected, connecting, rtt, pill, onRelease }) {
  // The overlay unmounts while the editor covers the controller; resume where the player left.
  const [local, setLocal] = useState(resume.step);
  const setStep = next => { resume.step = next; setLocal(next); };
  const step = state.tourStage === 'connect' ? (connected ? 'linked' : 'connect') : local;
  const [preset, setPreset] = useState('xbox');
  const [sending, setSending] = useState('');
  const sent = useRef(false);
  // Once linked, send the layout the player made in chapter one to the computer.
  useEffect(() => {
    if (step !== 'linked' || sent.current) return;
    let cancelled = false;
    // The receiver activates its own layout right after connecting; give that a
    // moment, then retry briefly before reporting the layout as phone-only.
    const attempt = async tries => {
      try { return await sendDraftToComputer({ fromTour: true }); }
      catch (failure) {
        if (tries <= 1 || cancelled) throw failure;
        await new Promise(resolve => setTimeout(resolve, 1500));
        return attempt(tries - 1);
      }
    };
    setSending('Sending your layout…');
    const start = setTimeout(() => {
      sent.current = true;
      void attempt(4).then(result => { if (!cancelled) setSending(result ? `“${result.name}” is on your computer.` : ''); })
        .catch(failure => { if (!cancelled) setSending(`Your layout stays on this phone: ${failure.message}`); });
    }, 1000);
    return () => { cancelled = true; clearTimeout(start); };
  }, [step]);
  // Until a computer sends its own layout, show the one made in chapter one.
  useEffect(() => {
    if (step !== 'connect') return;
    void tourDraft().then(profile => { if (profile) connection.previewLayout(profile); }).catch(() => {});
  }, [step]);
  const finish = () => { resume.step = 'intro'; void save({ tourDone: true, tourStage: '', dismissed: true }); };
  const chapter = step === 'connect' || step === 'linked' ? 2 : 1;

  if (step === 'intro') return <View style={s.fill} accessibilityViewIsModal>
    <View style={s.scrim} />
    <View style={[s.card, s.center, { width: 420, padding: 22, gap: 10 }]}>
      <Text style={s.n}>THUMBLE · TWO MINUTES</Text>
      <Text accessibilityRole="header" style={[s.b, { fontSize: 22, lineHeight: 27 }]}>You know how a gamepad works. Let’s make this one fit your hands.</Text>
      <Text style={s.p}>Every control can move, resize and send something else. Set it up the way you like, then connect your computer. You can change it all later.</Text>
      <View style={{ flexDirection: 'row', gap: 6, marginVertical: 4 }}>
        <Text style={s.chapterChip}>1 · Make it yours</Text><Text style={s.chapterChip}>2 · Connect</Text>
      </View>
      <View style={s.r2}>
        <Pressable accessibilityRole="button" testID="tour-skip-to-connect" onPress={() => { void forgetTourDraft().catch(() => {}).then(() => save({ tourStage: 'connect' })); }} hitSlop={8}><Text style={s.skip}>Keep the Xbox layout — connect now</Text></Pressable>
        <Go label="Let’s go" testID="tour-start" onPress={() => setStep('preset')} />
      </View>
    </View>
  </View>;

  if (step === 'preset') return <View style={s.fill} accessibilityViewIsModal>
    <View style={s.scrim} />
    <Hud chapter={1} detail="1/4" />
    <View style={[s.card, { position: 'absolute', top: 64, alignSelf: 'center', width: 420, paddingVertical: 12 }]}>
      <Text style={s.n}>MAKE IT YOURS · 1 OF 4</Text>
      <Text style={s.b}>Pick the layout that’s closest. You’ll fine-tune it next.</Text>
    </View>
    <View style={s.sheet}>
      <View accessibilityRole="radiogroup" style={{ flexDirection: 'row', gap: 10 }}>
        {TOUR_PRESETS.map(item => {
          const on = item.id === preset;
          return <Pressable key={item.id} accessibilityRole="radio" accessibilityState={{ checked: on }} testID={`tour-preset-${item.id}`} onPress={() => setPreset(item.id)}
            style={[s.preset, on && { borderColor: blue }]}>
            <PresetArt id={item.id} />
            <Text style={s.presetName}>{item.name}</Text>
            <Text style={s.presetDetail}>{item.detail}</Text>
          </Pressable>;
        })}
      </View>
      <View style={[s.r2, { marginTop: 10 }]}>
        <Text style={s.sheetNote}>Every preset is fully editable. Nothing is locked.</Text>
        <Go label={`Use ${TOUR_PRESETS.find(item => item.id === preset)?.name}`} testID="tour-use-preset" onPress={() => { onRelease(); router.push({ pathname: '/layout-editor', params: { tour: '1', preset } }); }} />
      </View>
    </View>
  </View>;

  if (step === 'connect') return <View style={s.fill} accessibilityViewIsModal>
    <View style={s.scrim} />
    <Hud chapter={2} />
    <View style={[s.lights, { top: 64 }]} accessibilityRole="list">
      <Light on={false} wait={connecting} label="Paired" /><Light on={false} label="Gamepad" /><Light on={false} label="Spell labels" />
    </View>
    <View style={[s.card, { position: 'absolute', top: 108, alignSelf: 'center', width: 460, padding: 18 }]}>
      <Text style={s.n}>CONNECT · THREE LIGHTS AND YOU’RE IN</Text>
      <Text accessibilityRole="header" style={[s.b, { fontSize: 18, lineHeight: 23 }]}>Scan the code on your computer.</Text>
      <Text style={s.p}>Open Thumble Receiver on your Mac, Windows or Linux PC and choose Pair phone. Same Wi-Fi, encrypted, remembered after the first scan. Each light turns green by itself.</Text>
      <View style={{ flexDirection: 'row', gap: 8, marginTop: 4 }}>
        <Plain label="Scan pairing code" primary testID="tour-scan" onPress={() => { onRelease(); router.push({ pathname: '/pair', params: { scan: '1' } }); }} />
        <Plain label="Paste link instead" onPress={() => { onRelease(); router.push('/pair'); }} />
      </View>
      <View style={s.r2}><Pressable accessibilityRole="button" testID="tour-later" onPress={finish} hitSlop={8}><Text style={s.skip}>Later — connect from the menu</Text></Pressable><Text style={s.note}>Your layout comes with you</Text></View>
    </View>
  </View>;

  // Linked: spotlight the connection pill.
  const spot = pill ? { left: pill.x - 6, top: pill.y - 6, width: pill.width + 12, height: pill.height + 12 } : null;
  return <View style={s.fill} accessibilityViewIsModal>
    {spot ? <View pointerEvents="none" style={[s.spot, spot]} /> : <View style={s.scrim} />}
    <View style={[s.lights, { top: 16, left: undefined, right: 16 }]} accessibilityRole="list">
      <Light on label="Paired" /><Light on label="Gamepad" /><Light on={false} label="Labels after /reload" />
    </View>
    <View style={[s.card, { position: 'absolute', top: (spot ? spot.top + spot.height : 60) + 16, left: Math.max(16, (spot?.left ?? 16)), width: 320 }]}>
      <Text style={[s.n, { color: '#1F7A35' }]}>YOU’RE LINKED{rtt != null ? ` · ${rtt} MS` : ''}</Text>
      <Text accessibilityRole="header" style={s.b}>This pill is your connection.</Text>
      <Text style={s.p}>Tap it to check or reconnect. Everything else lives behind ≡ Menu. With ConsolePort, type /reload in WoW and your spell names appear on the buttons.</Text>
      {!!sending && <Text accessibilityLiveRegion="polite" style={[s.p, { color: ink, fontFamily: fonts.bodyMedium }]}>{sending}</Text>}
      <View style={s.r2}><Text style={s.note}>Replay any time from the menu</Text><Go label="Start playing" testID="tour-finish" onPress={finish} /></View>
    </View>
    <Hud chapter={chapter} done />
  </View>;
}

function Hud({ chapter, detail = '', done = false }) {
  return <View style={s.hud} accessibilityRole="progressbar" accessibilityLabel={`Tour chapter ${chapter} of 2`}>
    <Text style={[s.hudItem, chapter === 1 && !done && s.hudOn, chapter > 1 && s.hudDone]}>{chapter > 1 ? '✓ Made it yours' : `● Make it yours${detail ? ` · ${detail}` : ''}`}</Text>
    <Text style={[s.hudItem, chapter === 2 && !done && s.hudOn, done && s.hudDone]}>{done ? '✓ Connected' : chapter === 2 ? '● Connect' : 'Connect'}</Text>
  </View>;
}
function Light({ on, wait = false, label }) {
  return <View accessibilityRole="text" accessibilityLabel={`${label}: ${on ? 'on' : 'waiting'}`} style={s.light}>
    <View style={[s.lightDot, on && { backgroundColor: '#30D158', borderColor: '#30D158' }, wait && { borderColor: pad.ring }]}>{on && <Text style={{ color: '#000', fontSize: 10, fontFamily: fonts.bodyBold }}>✓</Text>}</View>
    <Text style={[s.lightText, on && { color: pad.text }]}>{label}</Text>
  </View>;
}
/** @param {{ label: string, onPress: () => void, testID?: string }} props */
function Go({ label, onPress, testID }) {
  return <Pressable accessibilityRole="button" testID={testID} onPress={onPress} style={({ pressed }) => [s.go, pressed && { opacity: 0.7 }]}><Text style={s.goText}>{label}</Text></Pressable>;
}
/** @param {{ label: string, onPress: () => void, primary?: boolean, testID?: string }} props */
function Plain({ label, onPress, primary = false, testID }) {
  return <Pressable accessibilityRole="button" testID={testID} onPress={onPress} style={({ pressed }) => [s.plain, primary && { backgroundColor: blue }, pressed && { opacity: 0.7 }]}><Text style={[s.plainText, primary && { color: '#fff' }]}>{label}</Text></Pressable>;
}
/** Tiny schematic of each starting layout. */
function PresetArt({ id }) {
  const dot = (left, top, size, color = '#636366') => <View key={`${left}-${top}`} style={{ position: 'absolute', left, top, width: size, height: size, borderRadius: size / 2, backgroundColor: color }} />;
  const xbox = [dot(10, 18, 30), dot(50, 46, 14), dot(96, 46, 18), dot(118, 12, 12), dot(128, 24, 12), dot(108, 24, 12), dot(118, 36, 12, blue)];
  const lefty = [dot(112, 18, 30), dot(100, 46, 14), dot(40, 46, 18), dot(18, 12, 12), dot(8, 24, 12), dot(28, 24, 12), dot(18, 36, 12, blue)];
  const cp = [dot(10, 18, 30), dot(50, 46, 14), dot(96, 46, 18), dot(116, 8, 15), dot(130, 22, 15), dot(102, 22, 15), dot(116, 36, 15, blue)];
  return <View accessible={false} style={s.art}>{id === 'lefty' ? lefty : id === 'consoleport' ? cp : xbox}</View>;
}

const s = StyleSheet.create({
  fill: { ...StyleSheet.absoluteFill, zIndex: 20 },
  scrim: { ...StyleSheet.absoluteFill, backgroundColor: 'rgba(0,0,0,0.68)' },
  spot: { position: 'absolute', borderRadius: 24, borderWidth: 2, borderColor: pad.ring, boxShadow: '0px 0px 0px 2000px rgba(0,0,0,0.66)' },
  card: { backgroundColor: card, borderRadius: 16, borderCurve: 'continuous', padding: 14, gap: 6, boxShadow: '0px 12px 30px rgba(0,0,0,0.5)' },
  center: { position: 'absolute', alignSelf: 'center', top: '12%' },
  n: { fontFamily: fonts.bodyBold, fontSize: 11, letterSpacing: 0.3, color: blue },
  b: { fontFamily: fonts.bodyBold, fontSize: 16, lineHeight: 21, color: ink },
  p: { fontFamily: fonts.body, fontSize: 13, lineHeight: 18, color: inkMuted },
  r2: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 12, marginTop: 4 },
  skip: { fontFamily: fonts.bodyMedium, fontSize: 13, color: '#6E6E73' },
  go: { minHeight: 40, paddingHorizontal: 16, borderRadius: 10, borderCurve: 'continuous', backgroundColor: blue, alignItems: 'center', justifyContent: 'center' },
  goText: { fontFamily: fonts.bodyBold, fontSize: 14, color: '#fff' },
  plain: { flex: 1, minHeight: 40, borderRadius: 10, borderCurve: 'continuous', backgroundColor: '#E3E3E8', alignItems: 'center', justifyContent: 'center' },
  plainText: { fontFamily: fonts.bodyBold, fontSize: 14, color: ink },
  chapterChip: { flex: 1, textAlign: 'center', paddingVertical: 8, borderRadius: 10, overflow: 'hidden', backgroundColor: '#E3E3E8', color: ink, fontFamily: fonts.bodyBold, fontSize: 12 },
  hud: { position: 'absolute', top: 14, alignSelf: 'center', flexDirection: 'row', gap: 2, padding: 4, borderRadius: 18, backgroundColor: 'rgba(58,58,60,0.96)' },
  hudItem: { paddingHorizontal: 12, paddingVertical: 6, borderRadius: 14, overflow: 'hidden', fontFamily: fonts.bodyBold, fontSize: 11, color: pad.muted },
  hudOn: { backgroundColor: blue, color: '#fff' },
  hudDone: { color: '#30D158' },
  sheet: { position: 'absolute', left: 24, right: 24, bottom: 0, padding: 16, paddingBottom: 14, borderTopLeftRadius: 18, borderTopRightRadius: 18, backgroundColor: '#2C2C2E' },
  preset: { flex: 1, padding: 10, gap: 6, borderRadius: 14, borderCurve: 'continuous', backgroundColor: '#3A3A3C', borderWidth: 2, borderColor: 'transparent' },
  art: { height: 64, borderRadius: 9, backgroundColor: pad.ground, overflow: 'hidden' },
  presetName: { fontFamily: fonts.bodyBold, fontSize: 13, color: pad.text },
  presetDetail: { fontFamily: fonts.body, fontSize: 11, lineHeight: 14, color: pad.muted },
  note: { flexShrink: 1, fontFamily: fonts.body, fontSize: 12, color: '#6E6E73' },
  sheetNote: { flexShrink: 1, fontFamily: fonts.body, fontSize: 12, color: pad.muted },
  lights: { position: 'absolute', alignSelf: 'center', flexDirection: 'row', gap: 6 },
  light: { flexDirection: 'row', alignItems: 'center', gap: 6, height: 30, paddingLeft: 6, paddingRight: 10, borderRadius: 15, backgroundColor: 'rgba(58,58,60,0.96)' },
  lightDot: { width: 18, height: 18, borderRadius: 9, borderWidth: 1.5, borderColor: '#636366', alignItems: 'center', justifyContent: 'center' },
  lightText: { fontFamily: fonts.bodyBold, fontSize: 11, color: pad.muted },
});
