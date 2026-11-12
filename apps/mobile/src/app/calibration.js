import { useState, useSyncExternalStore } from 'react';
import { Pressable, StyleSheet, Switch, Text, View } from 'react-native';
import { calibration } from '../calibration';
import { connection } from '../connection';
import { usesPhoneCalibration } from '../consoleport-sync';
import { Columns, Eyebrow, Page, colors, ui } from '../ui/design';
export default function CalibrationScreen() {
  const saved = useSyncExternalStore(calibration.subscribe, calibration.snapshot);
  const layout = useSyncExternalStore(connection.subscribeProfile, connection.profileSnapshot);
  const supported = usesPhoneCalibration(layout.profile) || layout.revision === 0;
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  async function change(side, key, value) {
    if (busy || !supported) return;
    connection.pausePlay(); setBusy(true); setError('');
    try { await calibration.set({ ...saved, [side]: { ...saved[side], [key]: value } }); }
    catch (failure) { setError(failure.message); }
    finally { setBusy(false); }
  }
  return <Page>
    <View style={{ gap: 12 }}><Eyebrow>On this phone</Eyebrow><Text accessibilityRole="header" style={ui.title}>Fine-tune your thumbs.</Text><Text style={s.detail}>Adjust touch input for built-in and synced ConsolePort controllers. For camera behavior and game sensitivity, use ConsolePort in WoW. Saved custom controllers keep their own stick settings.</Text>{!supported && <Text style={s.detail}>Your active saved controller uses its own stick settings. Choose a built-in or synced ConsolePort controller to use touch calibration.</Text>}</View><Columns>
    {(['left', 'right']).map(side => <View key={side} style={[ui.card, { flex: 1 }]}>
      <Text style={s.title}>{side === 'left' ? 'Movement stick' : 'Camera stick'}</Text>
      {(['invertX', 'invertY']).map(key => <View style={s.row} key={key}><Text style={s.label}>{key === 'invertX' ? 'Invert horizontal' : 'Invert vertical'}</Text><Switch trackColor={{ false: colors.border, true: colors.secondary }} thumbColor={colors.text} disabled={busy || !supported} accessibilityLabel={`${side} ${key}`} value={saved[side][key]} onValueChange={value => change(side, key, value)} /></View>)}
      <Text style={s.label}>Dead zone</Text>
      <View style={s.choices}>{[0, 0.12, 0.24, 0.36].map(value => <Pressable key={value} disabled={busy || !supported} accessibilityRole="button" accessibilityState={{ selected: saved[side].deadzone === value, disabled: busy || !supported }} onPress={() => change(side, 'deadzone', value)} style={[s.choice, saved[side].deadzone === value && s.selected]}><Text style={s.label}>{Math.round(value * 100)}%</Text></Pressable>)}</View>
    </View>)}
    </Columns>{!!error && <Text accessibilityRole="alert" style={s.error}>{error}</Text>}
  </Page>;
}
const s = StyleSheet.create({ title: { color: '#EDEDED', fontSize: 20, fontWeight: '600' }, row: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', minHeight: 44 }, label: { color: '#EDEDED', fontSize: 17 }, detail: { color: '#A1A1A1', fontSize: 15, lineHeight: 22 }, choices: { flexDirection: 'row', gap: 8 }, choice: { minHeight: 44, flex: 1, minWidth: 0, alignItems: 'center', justifyContent: 'center', borderRadius: 16, borderCurve: 'continuous', borderWidth: 1, borderColor: '#2E2E2E' }, selected: { borderColor: '#EDEDED', backgroundColor: '#2E2E2E' }, error: { color: '#F1A59F', fontSize: 15 } });
