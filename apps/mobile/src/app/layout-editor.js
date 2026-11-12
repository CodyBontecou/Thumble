import { useEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react';
import { ActivityIndicator, Alert, AppState, Modal, Pressable, ScrollView, StyleSheet, Switch, Text, TextInput, View } from 'react-native';
import { router, useLocalSearchParams, usePreventRemove } from 'expo-router';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';
import { StatusBar } from 'expo-status-bar';
import { randomUUID } from 'expo-crypto';
import { assertProfile, consolePortProfile, controlDisplay, modifierPrefix, TouchController, validateLayout, validateProfile, xboxProfile } from '@tapping/controller';
import { calibration } from '../calibration';
import { usesPhoneCalibration } from '../consoleport-sync';
import { Control } from '../ControllerScreen';
import { connection } from '../connection';
import { layoutDrafts as drafts } from '../layout-drafts';
import { onboarding } from '../onboarding';
import { TOUR_PRESETS, addControl, availableOutputs, changeOutput, editFrame, outputName, presetProfile } from '../layout-editor';
import { Button, colors, fonts, pad, ui } from '../ui/design';

export default function LayoutEditorRoute() {
  return <SafeAreaProvider><SafeAreaView style={styles.screen}><StatusBar hidden /><LayoutEditor /></SafeAreaView></SafeAreaProvider>;
}

function LayoutEditor() {
  const params = useLocalSearchParams();
  const tour = params.tour === '1';
  const [tourStep, setTourStep] = useState(0);
  const [tourSmall, setTourSmall] = useState(false);
  const [tourStart, setTourStart] = useState(/** @type {any} */ (null));
  const [leaving, setLeaving] = useState(false);
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
  // A fresh draft is compared with its starting point, so opening and closing is not an edit.
  const [baseline, setBaseline] = useState(/** @type {any} */ (null));
  const dirty = !!draft && JSON.stringify(draft) !== JSON.stringify(saved ?? baseline);
  const savedStatus = dirty ? '' : status;
  useEffect(() => {
    let active = true;
    drafts.load().then(record => {
      const profile = record?.profile ?? record;
      if (!active) return;
      const base = usesPhoneCalibration(initial.profile) || initial.revision === 0
        ? calibration.standard(calibration.snapshot(), initial.profile) : initial.profile;
      if (tour) {
        const id = typeof params.preset === 'string' ? params.preset : 'xbox';
        const start = calibration.standard(calibration.snapshot(), presetProfile(id, { xbox: xboxProfile, consoleport: consolePortProfile }));
        const name = `My ${TOUR_PRESETS.find(item => item.id === id)?.name ?? 'Xbox'}`;
        const fresh = { ...newDraft(start), name };
        setDraft(fresh); setBaseline(fresh); setTourStart(fresh); setMacRevisions(record?.macRevisions ?? {});
      } else if (profile && !validateProfile(profile).length) { const checked = assertProfile(profile); setSaved(checked); setDraft(checked); setMacRevisions(record.macRevisions ?? {}); }
      else {
        // A draft from an older build may no longer validate; start fresh rather than locking the editor.
        if (profile) setStatus('Your old draft couldn’t be opened, so this starts from your active controller.');
        const fresh = newDraft(base);
        setDraft(fresh); setBaseline(fresh);
      }
    }).catch(failure => { if (active) setError(failure.message); });
    return () => { active = false; };
  }, [initial]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { if (leaving && !dirty) router.back(); }, [leaving, dirty]);
  usePreventRemove(!!busy || (dirty && !tour), ({ repeat }) => {
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
  // Park the coach card where it hides the fewest controls (ConsolePort keeps
  // its shoulders in the middle). Decided per step so it never jumps mid-drag.
  const hasDraft = !!draft;
  const tourAtBottom = useMemo(() => {
    if (!viewport || !draft) return false;
    const card = { width: 340, height: 150 }, left = (viewport.width - card.width) / 2;
    const covered = top => draft.controls.reduce((sum, { frame }) => {
      const x = Math.max(0, Math.min(left + card.width, (frame.x + frame.width) * viewport.width) - Math.max(left, frame.x * viewport.width));
      const y = Math.max(0, Math.min(top + card.height, (frame.y + frame.height) * viewport.height) - Math.max(top, frame.y * viewport.height));
      return sum + x * y;
    }, 0);
    return covered(viewport.height - card.height - 62) < covered(46);
  }, [tourStep, viewport?.width, viewport?.height, hasDraft]); // eslint-disable-line react-hooks/exhaustive-deps

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

  async function finishTour() {
    if (!draft || busy || validateProfile(draft).length) return;
    setBusy('Saving…');
    try {
      await drafts.save({ profile: draft, macRevisions, fromTour: true });
      await onboarding.update({ tourStage: 'connect' });
      connection.previewLayout(draft);
      setSaved(draft); setLeaving(true);
    } catch (failure) { setError(failure.message); }
    finally { setBusy(''); }
  }
  const tourProgress = tour && tourStart && draft ? {
    moved: draft.controls.some(item => { const was = tourStart.controls.find(c => c.id === item.id); return was && (Math.abs(was.frame.x - item.frame.x) > 0.005 || Math.abs(was.frame.y - item.frame.y) > 0.005); }),
    resized: draft.controls.some(item => { const was = tourStart.controls.find(c => c.id === item.id); return was && (Math.abs(was.frame.width - item.frame.width) > 0.005 || Math.abs(was.frame.height - item.frame.height) > 0.005); }),
    remapped: draft.mappings.some(item => { const was = tourStart.mappings.find(m => m.controlId === item.controlId); return was && was.outputs.join() !== item.outputs.join(); }) || draft.controls.some(item => !!item.customLabel),
  } : null;

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
      <Tool label="Options" disabled={!!busy} onPress={() => setOptionsOpen(true)} />
    </View>}
    <Modal visible={optionsOpen} transparent animationType="fade" supportedOrientations={['landscape']} onRequestClose={() => setOptionsOpen(false)}>
      <SafeAreaView style={styles.optionsOverlay}>
        <Pressable style={StyleSheet.absoluteFill} accessibilityRole="button" accessibilityLabel="Close control options" onPress={() => setOptionsOpen(false)} />
        <View style={styles.inspector}>
          <View style={styles.optionsHeader}><Text numberOfLines={2} style={[ui.heading, { flex: 1, color: pad.text }]}>{control ? controlDisplay(control, '', draft).label : 'Layout settings'}</Text>
            <Tool label="Done" onPress={() => setOptionsOpen(false)} />
          </View>
          <ScrollView contentContainerStyle={styles.inspectorContent} keyboardShouldPersistTaps="handled" automaticallyAdjustKeyboardInsets keyboardDismissMode="interactive">
            {control && mapping ? <>
              <TextInput accessibilityLabel="Custom label" placeholder={controlDisplay(control, '', draft).label} placeholderTextColor="#a8a8a8" style={styles.input} value={control.customLabel ?? ''} maxLength={80} editable={!busy} onChangeText={label => updateControl({ customLabel: label || undefined })} />
              {control.id !== 'chat' && <>
                <Text style={styles.detail}>Gamepad output</Text>
                <View style={styles.outputs}>{availableOutputs(draft, control).map(outputs => <Tool key={outputs[0]} label={outputName(outputs[0])}
                  selected={mapping.outputs[0] === outputs[0]} disabled={!!busy} onPress={() => setDraft(current => changeOutput(current, control.id, outputs))} />)}</View>
              </>}
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
              <Text style={[styles.detail, { marginTop: 8 }]}>Layout</Text>
            </> : <Text style={styles.detail}>Drag a control to move it. Drag its corner to resize it.</Text>}
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

          </ScrollView>
        </View>
      </SafeAreaView>
    </Modal>
    {tourProgress && !dragging && !optionsOpen && <EditorTour step={tourStep} progress={tourProgress} selected={!!control} bottom={tourAtBottom} small={tourSmall} onSmall={setTourSmall}
      onNext={() => { setTourSmall(false); if (tourStep < 2) setTourStep(tourStep + 1); else void finishTour(); }} onBack={() => { setTourSmall(false); setTourStep(Math.max(0, tourStep - 1)); }}
      onOptions={() => setOptionsOpen(true)} busy={!!busy} invalid={validation.length > 0} />}
    {!dragging && !!(busy || error || savedStatus || validation[0]) && <Text accessibilityLiveRegion="polite" numberOfLines={2}
      style={[styles.footer, (error || validation.length > 0) && ui.error]}>
      {busy || error || savedStatus || validation[0]}
    </Text>}
  </View>;
}

function newDraft(profile) {
  return { ...profile, id: `phone-${randomUUID().replace(/-/g, '')}`, name: `${profile.name.slice(0, 73).replace(/[\uD800-\uDBFF]$/, '')} copy` };
}

const TOUR_STEPS = [
  { title: 'Drag a control to where your thumb rests.', detail: 'Keep controls apart. A note at the bottom tells you if two overlap.', key: 'moved' },
  { title: 'Tap a control, then drag its blue corner to resize.', detail: 'Make the buttons you hit most a little bigger.', key: 'resized' },
  { title: 'Change what a button sends.', detail: 'Tap a control, then Options → Gamepad output. Your game decides what each output does.', key: 'remapped' },
];
/** Coach card for chapter one of the first-run tour. Collapsing it keeps the
 * step and its buttons but uncovers the controls underneath. */
function EditorTour({ step, progress, selected, onNext, onBack, onOptions, busy, invalid, bottom = false, small = false, onSmall }) {
  const item = TOUR_STEPS[step];
  const done = progress[item.key];
  const place = bottom ? { top: undefined, bottom: 62 } : null;
  const next = <Pressable accessibilityRole="button" testID="editor-tour-next" disabled={busy || (step === 2 && invalid)} onPress={onNext} style={[styles.tourGo, step === 2 && invalid && { opacity: 0.4 }]}><Text style={styles.tourGoText}>{step === 2 ? (invalid ? 'Fix the note below first' : 'Done · Connect →') : done ? 'Next' : 'Skip'}</Text></Pressable>;
  const options = step === 2 && <Pressable accessibilityRole="button" disabled={!selected} onPress={onOptions} style={[styles.tourGhost, !selected && { opacity: 0.4 }]}><Text style={styles.tourGhostText}>{selected ? 'Options' : 'Tap a control first'}</Text></Pressable>;
  if (small) return <View style={[styles.tour, styles.tourSmall, place]} testID="editor-tour">
    <Pressable accessibilityRole="button" accessibilityLabel={`Show tip: ${item.title}`} hitSlop={8} onPress={() => onSmall(false)} style={{ minHeight: 36, justifyContent: 'center' }}>
      <Text style={styles.tourTag}>{done ? '✓ ' : ''}{step + 2} of 4 · Show tip</Text>
    </Pressable>
    {options}{next}
  </View>;
  return <View style={[styles.tour, place]} accessibilityLiveRegion="polite" testID="editor-tour">
    <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' }}>
      <Text style={styles.tourTag}>MAKE IT YOURS · {step + 2} OF 4</Text>
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 12 }}>
        {done && <Text style={styles.tourDone}>✓ Nice</Text>}
        <Pressable accessibilityRole="button" accessibilityLabel="Hide tip" hitSlop={10} onPress={() => onSmall(true)}><Text style={styles.tourSkip}>Hide</Text></Pressable>
      </View>
    </View>
    <Text style={styles.tourTitle}>{item.title}</Text>
    <Text style={styles.tourDetail}>{item.detail}</Text>
    <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 8, marginTop: 2 }}>
      <Pressable accessibilityRole="button" hitSlop={8} disabled={step === 0 || busy} onPress={onBack}><Text style={[styles.tourSkip, step === 0 && { opacity: 0 }]}>Back</Text></Pressable>
      <View style={{ flexDirection: 'row', gap: 8 }}>{options}{next}</View>
    </View>
  </View>;
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
  screen: { flex: 1, backgroundColor: pad.ground },
  editor: { flex: 1 },
  loading: { flex: 1, alignItems: 'center', justifyContent: 'center', gap: 12 },
  // Grouped in the free gap between the bumpers so no control is covered.
  toolbar: { position: 'absolute', top: 4, alignSelf: 'center', flexDirection: 'row', alignItems: 'center', gap: 6 },
  title: { color: pad.text, fontFamily: fonts.bodyBold, fontSize: 15, backgroundColor: 'rgba(58,58,60,0.96)', paddingHorizontal: 12, paddingVertical: 6, borderRadius: 14, overflow: 'hidden' },
  spacer: { flex: 1 },
  canvas: { flex: 1, marginHorizontal: 8 },
  target: { position: 'absolute', borderWidth: 1.5, borderColor: 'rgba(235,235,245,0.3)', borderStyle: 'dashed', borderRadius: 16 },
  targetBody: { flex: 1, alignItems: 'center', justifyContent: 'center' },
  handle: { position: 'absolute', right: -8, bottom: -8, width: 24, height: 24, borderRadius: 7, backgroundColor: '#FFFFFF', borderWidth: 3, borderColor: pad.accent },
  selected: { borderColor: pad.accent, borderStyle: 'solid', borderWidth: 2 },
  inspector: { width: 340, maxWidth: '90%', flex: 1, alignSelf: 'flex-start', backgroundColor: '#000000', borderRadius: 18, borderCurve: 'continuous' },
  optionsOverlay: { flex: 1, backgroundColor: 'rgba(0,0,0,0.35)', padding: 12, alignItems: 'flex-start' },
  optionsHeader: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 8, paddingHorizontal: 14, paddingTop: 12, paddingBottom: 6 },
  inspectorContent: { padding: 12, gap: 10 },
  input: { fontFamily: fonts.body, fontSize: 15, minHeight: 44, color: pad.text, backgroundColor: '#1C1C1E', borderRadius: 10, paddingHorizontal: 12 },
  tool: { minHeight: 36, justifyContent: 'center', paddingHorizontal: 12, backgroundColor: 'rgba(58,58,60,0.96)', borderRadius: 10, borderCurve: 'continuous', borderWidth: 1.5, borderColor: 'transparent' },
  toolLabel: { color: pad.text, fontFamily: fonts.bodyBold, fontSize: 13 },
  disabled: { opacity: 0.4 },
  detail: { color: pad.muted, fontFamily: fonts.body, fontSize: 13 },
  row: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 4, flexWrap: 'wrap' },
  outputs: { flexDirection: 'row', flexWrap: 'wrap', gap: 6 },
  footer: { position: 'absolute', bottom: 6, alignSelf: 'center', maxWidth: '75%', backgroundColor: 'rgba(58,58,60,0.96)', color: pad.text, fontFamily: fonts.bodyMedium, fontSize: 13, paddingVertical: 6, paddingHorizontal: 12, borderRadius: 14, overflow: 'hidden' },
  tour: { position: 'absolute', top: 46, alignSelf: 'center', width: 340, backgroundColor: '#F2F2F7', borderRadius: 14, borderCurve: 'continuous', padding: 12, gap: 4, boxShadow: '0px 10px 26px rgba(0,0,0,0.5)' },
  tourSmall: { width: 'auto', flexDirection: 'row', alignItems: 'center', gap: 8, paddingVertical: 6, paddingHorizontal: 10 },
  tourTag: { fontFamily: fonts.bodyBold, fontSize: 11, color: '#0A64D8', letterSpacing: 0.3 },
  tourDone: { fontFamily: fonts.bodyBold, fontSize: 12, color: '#1F7A35' },
  tourTitle: { fontFamily: fonts.bodyBold, fontSize: 15, lineHeight: 19, color: '#1D1D1F' },
  tourDetail: { fontFamily: fonts.body, fontSize: 12, lineHeight: 16, color: '#515154' },
  tourSkip: { fontFamily: fonts.bodyMedium, fontSize: 13, color: '#6E6E73' },
  tourGo: { minHeight: 36, paddingHorizontal: 14, borderRadius: 9, backgroundColor: '#0A64D8', alignItems: 'center', justifyContent: 'center' },
  tourGoText: { fontFamily: fonts.bodyBold, fontSize: 13, color: '#FFFFFF' },
  tourGhost: { minHeight: 36, paddingHorizontal: 12, borderRadius: 9, backgroundColor: '#E3E3E8', alignItems: 'center', justifyContent: 'center' },
  tourGhostText: { fontFamily: fonts.bodyBold, fontSize: 13, color: '#1D1D1F' },
});
