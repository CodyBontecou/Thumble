import { useCallback, useEffect, useRef, useState, useSyncExternalStore } from 'react';
import { FlatList, Pressable, StyleSheet, Text, TextInput, View } from 'react-native';
import { useIsFocused } from 'expo-router';
import { randomUUID } from 'expo-crypto';
import { bindingChange, controlDisplay, gamepadKeys, utilityActions } from '@tapping/controller';
import { connection } from '../connection';
import { Button, Page, Row, ui, colors } from '../ui/design';
import { secureRecord } from '../secure-record';
import { outputName } from '../layout-editor';

const proposalRecord = secureRecord('thumble.wow-proposal.v1');

export default function WowBindings() {
  const network = useSyncExternalStore(connection.subscribe, connection.snapshot);
  const access = useSyncExternalStore(connection.subscribeAccess, connection.accessSnapshot);
  const layout = useSyncExternalStore(connection.subscribeProfile, connection.profileSnapshot);
  const focused = useIsFocused();
  const [snapshot, setSnapshot] = useState(/** @type {any} */ (null));
  const [reference, setReference] = useState(/** @type {any} */ (null));
  const [selected, setSelected] = useState('');
  const [query, setQuery] = useState('');
  const [proposal, setProposal] = useState(/** @type {any} */ (null));
  const [sent, setSent] = useState(/** @type {any} */ (null));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const epoch = useRef(0);
  const revealSelection = useRef(false);
  const list = useRef(/** @type {FlatList<any> | null} */ (null));
  useEffect(() => {
    let active = true;
    proposalRecord.load().then(record => {
      if (active && record?.plan?.kind === 'binding-plan' && typeof record.after === 'string' && typeof record.receiverId === 'string') setSent(record);
    }).catch(failure => { if (active) setError(failure.message); });
    return () => { active = false; };
  }, []);
  const selectedControl = layout.profile.controls.find(control => control.id === selected);
  const selectedMapping = layout.profile.mappings.find(mapping => mapping.controlId === selected);
  const binding = snapshot?.bindings.find(item => item.key === gamepadKeys[selectedMapping?.outputs[0]]);
  // WoW binds gamepad buttons here; keyboard keys use WoW's own key bindings.
  const controls = layout.profile.controls.filter(control => ['button', 'trigger'].includes(control.type) && control.id !== 'chat');

  const refresh = useCallback(async () => {
    const attempt = ++epoch.current;
    setBusy(true); setError(''); setProposal(null); setSnapshot(null);
    try {
      const catalog = await connection.requestProfiles();
      if (epoch.current !== attempt) return;
      const active = catalog.profiles.find(item => item.id === layout.profile.id);
      if (!active) throw Error('Choose a saved controller or use your edited layout on Mac first.');
      setReference(active);
      let result = await connection.readBindings();
      let offset = 0;
      const spells = [...result.spells];
      while (result.nextOffset !== null) {
        if (epoch.current !== attempt) return;
        if (!Number.isSafeInteger(result.nextOffset) || result.nextOffset <= offset || result.nextOffset > 2048) throw Error('Invalid character spell page.');
        offset = result.nextOffset;
        result = await connection.readBindings(offset, result.snapshotId);
        spells.push(...result.spells);
        if (spells.length > 2048) throw Error('Invalid character spell list.');
      }
      if (epoch.current === attempt) setSnapshot({ ...result, spells });
    } catch (failure) { if (epoch.current === attempt) setError(failure.message); }
    finally { if (epoch.current === attempt) setBusy(false); }
  }, [layout.profile.id]);
  const invalidate = useCallback(() => { epoch.current++; }, []);
  useEffect(() => {
    const timer = setTimeout(() => {
      if (focused && network.phase === 'connected') void refresh();
      else if (network.phase !== 'connected') { setSnapshot(null); setReference(null); setProposal(null); setBusy(false); }
    }, 0);
    return () => { clearTimeout(timer); invalidate(); };
    // A layout activation invalidates its saved profile reference and proposals.
  }, [focused, network.phase, layout.revision, refresh, invalidate]);

  function choose(intent) {
    setError('');
    try {
      const change = bindingChange(snapshot, layout.profile, { ...intent, controlId: selected });
      const plan = { bridgeVersion: 1, kind: 'binding-plan', id: randomUUID(), snapshotId: snapshot.snapshotId,
        characterGuid: snapshot.character.guid, bindingSet: snapshot.bindingSet,
        profile: { id: layout.profile.id, revision: reference.revision, name: layout.profile.name }, changes: [change] };
      const after = intent.spellId !== undefined ? 'SPELL ' + snapshot.spells.find(item => item.id === intent.spellId).name : intent.action;
      revealSelection.current = true;
      setProposal({ plan, after, before: binding.base || 'Unbound' });
    } catch (failure) { setError(failure.message); }
  }
  async function send() {
    if (!proposal || busy) return;
    setBusy(true); setError('');
    try {
      const result = await connection.copyBindingPlan(proposal.plan);
      if (result?.planId !== proposal.plan.id) throw Error('The Mac did not confirm this proposal.');
      const delivered = { ...proposal, receiverId: access?.receiverId };
      setSent(delivered); setProposal(null);
      await proposalRecord.save(delivered);
    } catch (failure) { setError(failure.message); }
    finally { setBusy(false); }
  }
  const needle = query.trim().toLocaleLowerCase();
  const spells = snapshot?.spells.filter(spell => !needle || spell.name.toLocaleLowerCase().includes(needle) || String(spell.id) === needle) ?? [];
  const visibleSent = sent?.receiverId === access?.receiverId && sent?.plan?.characterGuid === snapshot?.character.guid ? sent : null;
  const confirmed = visibleSent && snapshot?.receipt?.planId === visibleSent.plan.id && snapshot.receipt.status === 'verified';

  return <Page scroll={false}><FlatList ref={list} data={selectedControl ? spells : []} keyExtractor={spell => String(spell.id)}
    contentContainerStyle={{ padding: 20, gap: 12, width: '100%', maxWidth: 1120, alignSelf: 'center' }}
    keyboardShouldPersistTaps="handled" keyboardDismissMode="interactive"
    ListEmptyComponent={selectedControl && snapshot ? <Text style={ui.body}>No learned spells match this search.</Text> : undefined}
    renderItem={({ item }) => <Row title={item.name} detail={`Spell ${item.id}${item.rank ? ` · ${item.rank}` : ''}`} disabled={busy} onPress={() => choose({ spellId: item.id })} />}
    ListHeaderComponent={<View style={{ gap: 16 }}>
    <View style={{ gap: 8 }}>
      <Text style={ui.body}>Choose an ability for a gamepad button. In World of Warcraft, paste the proposal into /thumblebridge, review it, then click Apply outside combat.</Text>
      <Text style={ui.small}>Type /reload in World of Warcraft to refresh this character’s learned spells and bindings.</Text>
    </View>
    <Button secondary disabled={busy || network.phase !== 'connected'} onPress={() => void refresh()}>{busy ? 'Loading…' : 'Refresh character'}</Button>
    {network.phase !== 'connected' && <Text style={ui.body}>Connect your Mac to choose World of Warcraft actions.</Text>}
    {!!error && <Text accessibilityRole="alert" style={ui.error}>{error}</Text>}
    {visibleSent && <View style={ui.card} onLayout={() => list.current?.scrollToOffset({ offset: 0, animated: true })}>
      <Text accessibilityRole="header" accessibilityLiveRegion="polite" style={ui.heading}>{confirmed ? 'Binding confirmed' : 'Proposal copied to your Mac'}</Text>
      <Text style={ui.body}>{visibleSent.after}</Text>
      <Text style={ui.body}>{confirmed ? 'The latest World of Warcraft export confirms this action is bound.' : 'In World of Warcraft, open /thumblebridge, paste from the Mac clipboard, click Review pasted plan, then Apply reviewed changes. Type /reload and tap Refresh character here to confirm.'}</Text>
    </View>}
    {snapshot && <>
      <View style={{ gap: 4 }}>
        <Text accessibilityRole="header" style={ui.heading}>{snapshot.character.name}</Text>
        <Text style={ui.small}>{[snapshot.character.realm, snapshot.character.class].filter(Boolean).join(' · ')}</Text>
        <Text style={ui.small}>{snapshot.bindingSet === 1 ? 'Account-wide bindings' : 'Character bindings'} · Exported {new Date(snapshot.exportedAt * 1000).toLocaleString()}</Text>
        {snapshot.bindingSet === 1 && <Text style={ui.body}>Changes affect other characters using the account binding set.</Text>}
      </View>
      <View style={styles.controls}>{controls.map(control => {
        const mapping = layout.profile.mappings.find(item => item.controlId === control.id);
        const key = gamepadKeys[mapping?.outputs[0]], reserved = snapshot.reserved[key];
        const label = controlDisplay(control, '', layout.profile).label;
        return <Pressable key={control.id} accessibilityRole="button" accessibilityLabel={`${label}, ${outputName(mapping.outputs[0])}`}
          accessibilityState={{ selected: selected === control.id, disabled: !!reserved || busy }}
          disabled={!!reserved || busy} onPress={() => { revealSelection.current = true; setSelected(control.id); setProposal(null); }}
          style={[styles.control, selected === control.id && styles.selected, (!!reserved || busy) && { opacity: 0.4 }]}>
          <Text style={ui.body}>{label}</Text><Text style={ui.small}>{outputName(mapping.outputs[0])}{reserved ? ` · ${reserved}` : ''}</Text>
        </Pressable>;
      })}</View>
      {selectedControl && <View style={{ gap: 12 }} onLayout={event => {
          if (!revealSelection.current) return;
          revealSelection.current = false;
          list.current?.scrollToOffset({ offset: event.nativeEvent.layout.y + 20, animated: true });
        }}>
        <Text style={ui.heading}>{controlDisplay(selectedControl, '', layout.profile).label}</Text>
        <Text style={ui.body}>Current binding {binding?.base || 'Unbound'}</Text>
        {proposal && <View style={ui.card}>
          <Text style={ui.body}>{proposal.before} → {proposal.after}</Text>
          <Button disabled={busy} onPress={() => void send()}>Copy proposal to Mac</Button>
        </View>}
        <TextInput accessibilityLabel="Search learned spells" placeholder="Search learned spells" placeholderTextColor={colors.muted} value={query} onChangeText={setQuery} style={ui.input} editable={!busy} />
      </View>}
    </>}
    </View>}
    ListFooterComponent={snapshot && selectedControl ? <View style={{ gap: 12 }}>
      <Text style={ui.heading}>Game actions</Text>
      {utilityActions.map(action => <Row key={action} title={actionNames[action]} disabled={busy} onPress={() => choose({ action })} />)}
    </View> : undefined}
  />
  </Page>;
}

const styles = StyleSheet.create({
  controls: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 },
  control: { minHeight: 52, padding: 12, backgroundColor: colors.surface, borderWidth: 2, borderColor: colors.border, borderRadius: 4, maxWidth: '100%' },
  selected: { borderColor: colors.accent, backgroundColor: colors.raised },
});

const actionNames = {
  JUMP: 'Jump', OPENCHAT: 'Open chat', TARGETNEARESTENEMY: 'Target nearest enemy',
  TARGETPREVIOUSENEMY: 'Target previous enemy', TARGETSELF: 'Target yourself',
  OPENALLBAGS: 'Open bags', TOGGLEWORLDMAP: 'World map', TOGGLECHARACTER0: 'Character panel',
  TOGGLEGAMEMENU: 'Game menu', INTERACTTARGET: 'Interact with target',
};
