import { useEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react';
import { ActivityIndicator, Alert, AppState, Modal, Pressable, ScrollView, StyleSheet, Switch, Text, TextInput, View } from 'react-native';
import { router, usePreventRemove } from 'expo-router';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';
import { StatusBar } from 'expo-status-bar';
import { randomUUID } from 'expo-crypto';
import { assertProfile, controlDisplay, modifierPrefix, TouchController, validateLayout, validateProfile } from '@tapping/controller';
import { calibration } from '../calibration';
import { usesPhoneCalibration } from '../consoleport-sync';
import { Control } from '../ControllerScreen';
import { connection } from '../connection';
import { secureRecord } from '../secure-record';
import { addControl, availableOutputs, changeOutput, editFrame, outputName } from '../layout-editor';
import { Button, colors, fonts, ui } from '../ui/design';

const drafts = secureRecord('thumble.layout-draft.v1');

export default function LayoutEditorRoute() {
  return <SafeAreaProvider><SafeAreaView style={styles.screen}><StatusBar hidden /><LayoutEditor /></SafeAreaView></SafeAreaProvider>;
}

function LayoutEditor() {
  const network = useSyncExternalStore(connection.subscribe, connection.snapshot);
  const [initial] = useState(() => connection.profileSnapshot());
  const [draft, setDraft] = useState(/** @type {any} */ (null));
  const [macRevisions, setMacRevisions] = useState({});
  const [saved, setSaved] = useState(/** @type {any} */ (null));
  const [selected, setSelected] = useState(/** @type {string | null} */ (null));
  const [practice, setPractice] = useState(false);
  const [optionsOpen, setOptionsOpen] = useState(false);
  const [dragging, setDragging] = useState(false);
  const visuals = useMemo(() => new Map(), []);
  const [busy, setBusy] = useState('');
  const [error, setError] = useState('');
  const [status, setStatus] = useState('');
  const [size, setSize] = useState({ width: 0, height: 0 });
  const viewport = size.width > 0 && size.height > 0 ? size : null;
  const gesture = useRef(/** @type {{pageX: number, pageY: number, id: string, frame: { x: number, y: number, width: number, height: number }, resize: boolean} | null} */ (null));
  const dirty = !!draft && JSON.stringify(draft) !== JSON.stringify(saved);
  const savedStatus = dirty ? '' : status;
  useEffect(() => {
    let active = true;
    drafts.load().then(record => {
      const profile = record?.profile ?? record;
      if (!active) return;
      const base = usesPhoneCalibration(initial.profile) || initial.revision === 0
        ? calibration.standard(calibration.snapshot(), initial.profile) : initial.profile;
      if (profile) { const checked = assertProfile(profile); setSaved(checked); setDraft(checked); setMacRevisions(record.macRevisions ?? {}); }
      else setDraft(newDraft(base));
    }).catch(failure => { if (active) setError(failure.message); });
    return () => { active = false; };
  }, [initial]);
  usePreventRemove(!!busy || dirty, ({ repeat }) => {
    if (busy) return;
    Alert.alert('Discard unsaved edits?', 'Your last saved draft will still be available.', [
      { text: 'Keep editing', style: 'cancel' },
      { text: 'Discard edits', style: 'destructive', onPress: () => { setDraft(saved); repeat(); } },
    ]);
  });

  const control = draft?.controls.find(item => item.id === selected);
  const mapping = draft?.mappings.find(item => item.controlId === selected);
  const nameError = draft && !draft.name.trim() ? 'Give this layout a name.' : '';
  const validation = useMemo(() => {
    if (!draft) return [];
    if (!draft.name.trim()) return ['Give this layout a name.'];
    if (!viewport) return validateProfile(draft);
    return validateLayout(draft, viewport).errors.map(issue => issue.controls
      .filter(id => id.length > 20)
      .reduce((message, id) => {
        const control = draft.controls.find(item => item.id === id);
        return message.split(id).join(control?.customLabel ?? control?.label ?? id);
      }, issue.message));
  }, [draft, viewport]);

  function updateControl(fields) {
    setStatus('');
    setDraft(current => ({ ...current, controls: current.controls.map(item => item.id === selected ? { ...item, ...fields } : item) }));
  }
  function updateMapping(fields) {
    setStatus('');
    setDraft(current => ({ ...current, mappings: current.mappings.map(item => item.controlId === selected ? { ...item, ...fields } : item) }));
  }
  function start(event, item, resize) {
    const { pageX, pageY } = event.nativeEvent;
    setStatus('');
    gesture.current = { pageX, pageY, id: item.id, frame: item.frame, resize };
    setSelected(item.id);
  }
  function move(event) {
    if (!gesture.current || !size.width || !size.height) return;
    setDragging(true);
    const { pageX, pageY, id, frame, resize } = gesture.current;
    const next = editFrame(frame, (event.nativeEvent.pageX - pageX) / size.width, (event.nativeEvent.pageY - pageY) / size.height, resize, size, draft.controls.find(item => item.id === id)?.type);
    setDraft(current => ({ ...current, controls: current.controls.map(item => item.id === id ? { ...item, frame: next } : item) }));
  }
  async function save(activate) {
    if (!draft || busy || nameError || (activate && validation.length) || validateProfile(draft).length) return;
    setBusy(activate ? 'Applying…' : 'Saving…'); setError(''); setStatus('');
    try {
      await drafts.save({ profile: draft, macRevisions });
      setSaved(draft);
      if (activate) {
        const catalog = await connection.requestProfiles();
        const receiverId = connection.accessSnapshot()?.receiverId;
        if (!receiverId) throw Error('Reconnect your Mac to identify this receiver.');
        const result = await connection.savePhoneProfile(draft, catalog.activationRevision, macRevisions[receiverId]?.[draft.id] ?? 0);
        const entry = result.profiles.find(item => item.id === draft.id);
        const revisions = { ...macRevisions, [receiverId]: { ...macRevisions[receiverId], [draft.id]: entry.revision } };
        setMacRevisions(revisions);
        await drafts.save({ profile: draft, macRevisions: revisions });
        setStatus('Active on Mac');
      } else setStatus('Draft saved on this phone');
      setOptionsOpen(false);
    } catch (failure) { setError(failure.message); }
    finally { setBusy(''); }
  }

  if (!draft) return <View style={styles.loading}>{error ? <><Text style={ui.error}>{error}</Text><Button onPress={() => router.back()}>Close</Button></> : <ActivityIndicator color={colors.text} />}</View>;

  return <View style={styles.editor}>
    <View style={styles.canvas} onLayout={event => setSize(event.nativeEvent.layout)}
      onStartShouldSetResponder={() => !practice && !busy}
      onResponderRelease={() => setSelected(null)}>
      {practice ? <Practice profile={draft} size={size} /> : <>
        <View style={StyleSheet.absoluteFill} pointerEvents="none" accessibilityElementsHidden importantForAccessibility="no-hide-descendants">
          {size.width > 0 && draft.controls.map(item => <Control key={item.id} control={item} size={size} visuals={visuals}
            profile={draft} prefix="" chatState="idle" onAccessiblePress={() => setSelected(item.id)} />)}
        </View>
        {draft.controls.map(item => {
          const active = item.id === selected;
          const frame = item.frame;
          return <View key={item.id} style={[styles.target, active && styles.selected, {
            left: frame.x * size.width, top: frame.y * size.height, width: frame.width * size.width, height: frame.height * size.height, zIndex: active ? 1 : 0,
          }]}>
            <View accessible accessibilityRole="button" accessibilityLabel={controlDisplay(item, '', draft).label} accessibilityState={{ selected: active }}
              onAccessibilityTap={() => setSelected(item.id)} style={styles.targetBody} onStartShouldSetResponder={() => !busy}
              onResponderGrant={event => start(event, item, false)} onResponderMove={move}
              onResponderRelease={() => { gesture.current = null; setDragging(false); }} onResponderTerminate={() => { gesture.current = null; setDragging(false); }} />
            {active && <View accessible accessibilityLabel={`Resize ${controlDisplay(item, '', draft).label}`} style={styles.handle}
              onStartShouldSetResponder={() => !busy} onResponderGrant={event => start(event, item, true)} onResponderMove={move}
              onResponderRelease={() => { gesture.current = null; setDragging(false); }} onResponderTerminate={() => { gesture.current = null; setDragging(false); }} />}
          </View>;
        })}
      </>}
    </View>
    {!dragging && <View style={styles.toolbar} pointerEvents="box-none">
      <Tool label="Close" disabled={!!busy} onPress={() => router.back()} />
      <View style={styles.spacer} pointerEvents="none" />
      <Text accessibilityRole="header" pointerEvents="none" style={styles.title}>{practice ? 'Practice' : 'Edit layout'}</Text>
      <View style={styles.spacer} pointerEvents="none" />
      <Tool label="Options" disabled={!!busy} onPress={() => setOptionsOpen(true)} />
    </View>}
    <Modal visible={optionsOpen} transparent animationType="fade" supportedOrientations={['landscape']} onRequestClose={() => setOptionsOpen(false)}>
      <SafeAreaView style={styles.optionsOverlay}>
        <Pressable style={StyleSheet.absoluteFill} accessibilityRole="button" accessibilityLabel="Close control options" onPress={() => setOptionsOpen(false)} />
        <View style={styles.inspector}>
          <View style={styles.optionsHeader}><Text numberOfLines={2} style={[ui.heading, { flex: 1 }]}>{control ? controlDisplay(control, '', draft).label : 'Layout settings'}</Text>
            <Tool label="Done" onPress={() => setOptionsOpen(false)} />
          </View>
          <ScrollView contentContainerStyle={styles.inspectorContent} keyboardShouldPersistTaps="handled" automaticallyAdjustKeyboardInsets keyboardDismissMode="interactive">
            <View style={styles.outputs}>
              <Tool label={practice ? 'Edit controls' : 'Practice'} disabled={!!busy || !!validateProfile(draft).length}
                onPress={() => { setPractice(!practice); setOptionsOpen(false); }} />
              <Tool label="Save draft" disabled={!!busy || !dirty || !!nameError || !!validateProfile(draft).length} onPress={() => void save(false)} />
              <Tool label="Use on Mac" disabled={!!busy || !!validation.length || network.phase !== 'connected'} onPress={() => void save(true)} />
            </View>
            {!!error && <Text accessibilityRole="alert" style={ui.error}>{error}</Text>}
            <TextInput accessibilityLabel="Layout name" style={styles.input} value={draft.name} maxLength={80} editable={!busy} onChangeText={name => setDraft(current => ({ ...current, name }))} />
            {!!nameError && <Text accessibilityRole="alert" style={ui.error}>{nameError}</Text>}
            <View style={styles.outputs}>{['button', 'trigger', 'stick'].map(type => <Tool key={type} label={`Add ${type}`} disabled={!!busy || !viewport || draft.controls.length >= 64} onPress={() => {
              const id = `${type}-${randomUUID()}`;
              const next = addControl(draft, id, viewport, type);
              if (next === draft) { setError('Free a matching gamepad output and make room on the canvas first.'); return; }
              setError(''); setStatus(''); setDraft(next); setSelected(id); setOptionsOpen(false);
            }} />)}</View>
            <Tool label="Start from active controller" disabled={!!busy} onPress={() => Alert.alert('Start a new layout?', 'The editor will copy your active controller. Save your draft first to keep its changes.', [
              { text: 'Cancel', style: 'cancel' },
              { text: 'Start new layout', onPress: () => {
                const profile = connection.profileSnapshot().profile;
                setDraft(newDraft(usesPhoneCalibration(profile) ? calibration.standard(calibration.snapshot(), profile) : profile));
                setSelected(null); setStatus(''); setError('');
              } },
            ])} />
            {control && mapping ? <>
              <TextInput accessibilityLabel="Custom label" placeholder={controlDisplay(control, '', draft).label} placeholderTextColor="#a8a8a8" style={styles.input} value={control.customLabel ?? ''} maxLength={80} editable={!busy} onChangeText={label => updateControl({ customLabel: label || undefined })} />
              <View style={styles.outputs}>
                {[
                  ['Move left', -8, 0, false], ['Move right', 8, 0, false],
                  ['Move up', 0, -8, false], ['Move down', 0, 8, false],
                  ['Narrower', -8, 0, true], ['Wider', 8, 0, true],
                  ['Shorter', 0, -8, true], ['Taller', 0, 8, true],
                ].map(([label, dx, dy, resize]) => <Tool key={String(label)} label={String(label)} disabled={!!busy || !viewport} onPress={() => {
                  if (!viewport) return;
                  updateControl({ frame: editFrame(control.frame, Number(dx) / viewport.width, Number(dy) / viewport.height, resize, viewport, control.type) });
                }} />)}
              </View>
              {control.id !== 'chat' && <>
                <Text style={styles.detail}>Gamepad output</Text>
                <View style={styles.outputs}>{availableOutputs(draft, control).map(outputs => <Tool key={outputs[0]} label={outputName(outputs[0])}
                  selected={mapping.outputs[0] === outputs[0]} disabled={!!busy} onPress={() => setDraft(current => changeOutput(current, control.id, outputs))} />)}</View>
              </>}
              {control.type === 'stick' && <>
                <Setting label="Dead zone" value={mapping.deadzone ?? 0.12} step={0.02} min={0} max={0.5} disabled={!!busy} onChange={deadzone => updateMapping({ deadzone })} />
                <Setting label="Sensitivity" value={mapping.sensitivity ?? 1} step={0.1} min={0.1} max={3} disabled={!!busy} onChange={sensitivity => updateMapping({ sensitivity })} />
                {['invertX', 'invertY'].map(axis => <View style={styles.row} key={axis}><Text style={styles.detail}>{axis === 'invertX' ? 'Invert X' : 'Invert Y'}</Text>
                  <Switch accessibilityLabel={axis === 'invertX' ? 'Invert X' : 'Invert Y'} value={!!mapping[axis]} disabled={!!busy} onValueChange={value => updateMapping({ [axis]: value })} /></View>)}
              </>}
              <Tool label="Remove control" disabled={!!busy || draft.controls.length <= 1} onPress={() => {
                setDraft(current => ({ ...current, controls: current.controls.filter(item => item.id !== selected), mappings: current.mappings.filter(item => item.controlId !== selected) }));
                setSelected(null);
              }} />
            </> : <Text style={styles.detail}>Drag a control to move it. Drag its corner to resize it.</Text>}
          </ScrollView>
        </View>
      </SafeAreaView>
    </Modal>
    {!dragging && !!(busy || error || savedStatus || validation[0]) && <Text accessibilityLiveRegion="polite" numberOfLines={2}
      style={[styles.footer, (error || validation.length > 0) && ui.error]}>
      {busy || error || savedStatus || validation[0]}
    </Text>}
  </View>;
}

function newDraft(profile) {
  return { ...profile, id: `phone-${randomUUID().replace(/-/g, '')}`, name: `${profile.name.slice(0, 73).replace(/[\uD800-\uDBFF]$/, '')} copy` };
}

function Tool({ label, onPress, disabled = false, selected = false }) {
  return <Pressable accessibilityRole="button" accessibilityState={{ disabled, selected }} disabled={disabled} onPress={onPress}
    style={({ pressed }) => [styles.tool, (selected || pressed) && styles.selected, disabled && styles.disabled]}>
    <Text style={styles.toolLabel}>{label}</Text>
  </Pressable>;
}

function Setting({ label, value, min, max, step, onChange, disabled }) {
  const set = delta => onChange(Math.round(Math.max(min, Math.min(max, value + delta)) * 100) / 100);
  return <View style={styles.row}><Text style={styles.detail}>{label} {value}</Text>
    <Tool label={`− ${label}`} disabled={disabled || value <= min} onPress={() => set(-step)} />
    <Tool label={`+ ${label}`} disabled={disabled || value >= max} onPress={() => set(step)} />
  </View>;
}

function Practice({ profile, size }) {
  const [prefix, setPrefix] = useState('');
  const visuals = useMemo(() => new Map(), []);
  const controller = useMemo(() => new TouchController(profile, {
    onState: (state, activeProfile) => setPrefix(modifierPrefix(activeProfile, state)),
    onVisual: (id, value) => visuals.get(id)?.(value),
  }), [profile, visuals]);
  useEffect(() => {
    const subscription = AppState.addEventListener('change', phase => { if (phase !== 'active') controller.releaseAll(); });
    return () => subscription.remove();
  }, [controller]);
  const origin = useRef(/** @type {{x: number, y: number} | null} */ (null));
  useEffect(() => {
    if (size.width && size.height) controller.setViewport(size.width, size.height);
    return () => { controller.releaseAll(); };
  }, [controller, size.width, size.height]);
  function touch(method, event) {
    if (!size.width || !size.height) return;
    if (method === 'down' && !origin.current) {
      const { pageX, pageY, locationX, locationY } = event.nativeEvent;
      origin.current = { x: pageX - locationX, y: pageY - locationY };
    }
    if (!origin.current) return;
    for (const point of event.nativeEvent.changedTouches) {
      if (method === 'up') controller.up(point.identifier);
      else controller[method](point.identifier, (point.pageX - origin.current.x) / size.width, (point.pageY - origin.current.y) / size.height);
    }
  }
  return <View style={StyleSheet.absoluteFill} onStartShouldSetResponder={() => true}
    onResponderGrant={event => touch('down', event)} onResponderStart={event => touch('down', event)} onResponderMove={event => touch('move', event)}
    onResponderEnd={event => touch('up', event)} onResponderRelease={() => { origin.current = null; controller.releaseAll(); }}
    onResponderTerminate={() => { origin.current = null; controller.releaseAll(); }}>
    {size.width > 0 && profile.controls.map(control => <Control key={control.id} control={control} size={size} visuals={visuals} profile={profile}
      prefix={prefix} chatState="idle" onAccessiblePress={() => {
        const { x, y, width, height } = control.frame;
        controller.down(control.id, x + width / 2, y + height / 2);
        setTimeout(() => controller.up(control.id), 100);
      }} />)}
  </View>;
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: '#17191b' },
  editor: { flex: 1 },
  loading: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 12 },
  toolbar: { position: 'absolute', top: 4, left: 12, right: 12, flexDirection: 'row', alignItems: 'center', gap: 8 },
  title: { color: colors.surface, fontFamily: fonts.pixel, fontSize: 20, backgroundColor: '#17191b', paddingHorizontal: 4 },
  spacer: { flex: 1 },
  canvas: { flex: 1, marginHorizontal: 8 },
  target: { position: 'absolute', borderWidth: 2, borderColor: 'transparent', borderRadius: 16 },
  targetBody: { flex: 1, alignItems: 'center', justifyContent: 'center' },
  handle: { position: 'absolute', right: -4, bottom: -4, width: 24, height: 24, borderRadius: 12, backgroundColor: colors.accent },
  selected: { borderColor: colors.accent },
  inspector: { width: 320, maxWidth: '90%', flex: 1, alignSelf: 'flex-end', backgroundColor: colors.surface, borderRadius: 12, borderCurve: 'continuous', borderWidth: 2, borderColor: colors.border },
  optionsOverlay: { flex: 1, backgroundColor: '#00000066', padding: 12, alignItems: 'flex-end' },
  optionsHeader: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 8, padding: 8 },
  inspectorContent: { padding: 8, gap: 8 },
  input: { fontFamily: fonts.body, minHeight: 44, color: colors.text, borderColor: '#5a5e62', borderWidth: 1, borderRadius: 8, paddingHorizontal: 8 },
  tool: { minHeight: 44, justifyContent: 'center', paddingHorizontal: 8, borderWidth: 1, borderColor: colors.border, backgroundColor: colors.surface, borderRadius: 8, borderCurve: 'continuous' },
  toolLabel: { color: colors.text, fontFamily: fonts.bodyBold, fontSize: 13 },
  disabled: { opacity: 0.45 },
  detail: { color: colors.text, fontFamily: fonts.body, fontSize: 13 },
  row: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 4, flexWrap: 'wrap' },
  outputs: { flexDirection: 'row', flexWrap: 'wrap', gap: 4 },
  footer: { position: 'absolute', bottom: 4, alignSelf: 'center', maxWidth: '75%', backgroundColor: colors.surface, color: colors.text, fontFamily: fonts.body, fontSize: 13, paddingVertical: 6, paddingHorizontal: 12, borderRadius: 8 },
});
