import { useEffect, useRef, useState, useSyncExternalStore } from 'react';
import { Share, Text, TextInput, View } from 'react-native';
import { xboxProfile } from '@tapping/controller';
import { router } from 'expo-router';
import { connection } from '../connection';
import { firstLayoutDelivered, firstLayoutPrompt } from '../onboarding-core';
import { useSetup } from '../use-setup';
import { Actions, Button, Columns, Eyebrow, Page, Row, ui } from '../ui/design';
function token() { return Math.floor(Math.random() * 0x100000000).toString(16).padStart(8, '0'); }
export default function FirstLayout() {
  const { state, save, error, setError } = useSetup();
  const network = useSyncExternalStore(connection.subscribe, connection.snapshot);
  const layout = useSyncExternalStore(connection.subscribeProfile, connection.profileSnapshot);
  const [draftCharacter, setDraftCharacter] = useState(/** @type {string | null} */ (null));
  const character = draftCharacter ?? state.character;
  const [busy, setBusy] = useState(false);
  const [showRequest, setShowRequest] = useState(false);
  const checking = useRef(false);
  useEffect(() => { connection.pausePlay(); }, []);
  async function preference(patch) { await save({ ...patch, profileId: '', personalized: false }); }
  async function prepare() {
    setBusy(true);
    await save({ character, sourceProfileId: layout.profile.id, profileId: `first-layout-${token()}`, agentCode: state.agentCode || `${token()}${token().slice(0, 4)}`, personalized: false });
    setBusy(false);
  }
  async function checkDelivery() {
    if (checking.current) return;
    checking.current = true; setBusy(true); setError('');
    try {
      // Refresh to detect disconnection/old receivers, then use the committed phone layout.
      await connection.requestProfiles();
      if (!firstLayoutDelivered(state, connection.snapshot(), connection.profileSnapshot(), connection.layoutPending, connection.recovering)) throw Error('Your requested layout has not finished arriving. Ask your agent to activate it, keep this phone connected, then check again.');
      await save({ personalized: true });
    } catch (failure) { setError(failure.message); }
    finally { checking.current = false; setBusy(false); }
  }
  async function useStandard() {
    if (checking.current) return;
    checking.current = true; setBusy(true); setError('');
    try {
      if (layout.profile.id !== xboxProfile.id) {
        const catalog = await connection.requestProfiles();
        const standard = catalog.profiles.find(profile => profile.id === xboxProfile.id);
        if (!standard) throw Error('The standard profile is missing on your Mac. Ask your agent to restore it, or choose a saved profile.');
        await connection.selectProfile(standard, catalog.activationRevision);
      }
      if (await save({ personalized: true, profileId: '' })) router.dismissTo('/onboarding');
    } catch (failure) { setError(failure.message); }
    finally { checking.current = false; setBusy(false); }
  }
  const prompt = firstLayoutPrompt(state, state.sourceProfileId || layout.profile.id);
  const share = () => { void Share.share({ message: prompt }).catch(failure => setError(failure.message)); };
  const delivery = state.personalized ? 'You confirmed this layout arrived on your phone.' : layout.profile.id === state.profileId ? 'Requested layout rendered. Confirm delivery below.' : 'Waiting for your agent to save and activate this layout.';
  const nextAction = state.personalized ? () => router.dismissTo('/onboarding') : !state.profileId ? prepare : network.phase === 'connected' ? checkDelivery : () => router.push('/pair?setup=1');
  const nextLabel = state.personalized ? 'Continue setup' : !state.profileId ? 'Prepare layout request' : network.phase === 'connected' ? 'Check layout delivery' : 'Connect Mac';
  return <Page footer={<Actions status={state.profileId ? delivery : 'Choose preferences, then prepare your request.'}>
    <View style={{ flex: 1 }}><Button secondary disabled={!state.loaded || busy} onPress={state.profileId ? share : useStandard}>{state.profileId ? 'Share layout request' : 'Keep standard controls'}</Button></View>
    <View style={{ flex: 1 }}><Button disabled={!state.loaded || busy} onPress={nextAction}>{busy ? 'Please wait…' : nextLabel}</Button></View>
  </Actions>}><Columns><View style={ui.column}><Eyebrow>YOUR FIRST LAYOUT</Eyebrow><Text accessibilityRole="header" style={ui.title}>{'Start with what\nfeels familiar.'}</Text><Text style={ui.body}>Keep the standard controller, or send your preferences to your own AI agent. Your choices and request are saved when you leave.</Text><Button secondary onPress={() => router.push('/cloud')}>Create with your AI in the cloud</Button>{(!!state.profileId || state.personalized) && <Button secondary disabled={!state.loaded || busy} onPress={useStandard}>Keep the standard controller</Button>}<Text style={ui.small}>The standard controller works without an AI agent. Custom layouts are included in the demo.</Text>
      <View style={ui.card}><Text style={ui.heading}>Choose a starting point</Text>{[['familiar', 'Familiar controls', 'Start from the Xbox-style arrangement'], ['consoleport', 'Match ConsolePort', 'Use a fresh character export from Thumble Bridge'], ['character', 'Build for my character', 'Use learned spells and review binding changes in-game']].map(([value, title, detail]) => <Row key={value} title={title} detail={detail} trailing={state.layoutMode === value ? '✓' : '›'} disabled={!state.loaded || busy} onPress={() => preference({ layoutMode: value })} />)}</View>
    </View><View style={ui.column}>
      {!!error && <Text accessibilityRole="alert" style={ui.error}>{error}</Text>}
      <View style={ui.card}><Text style={ui.heading}>Make it comfortable</Text><Row title="Button size" detail={state.buttonSize === 'larger' ? 'Larger action buttons' : 'Standard size'} disabled={!state.loaded || busy} onPress={() => preference({ buttonSize: state.buttonSize === 'larger' ? 'standard' : 'larger' })} /><Row title="Movement side" detail={state.movementSide === 'left' ? 'Left thumb' : 'Right thumb'} disabled={!state.loaded || busy} onPress={() => preference({ movementSide: state.movementSide === 'left' ? 'right' : 'left' })} />{state.layoutMode === 'character' && <TextInput accessibilityLabel="Character or class" placeholder="Character or class (optional)" placeholderTextColor="#A1A1A1" maxLength={80} value={character} onChangeText={value => { setDraftCharacter(value); void preference({ character: value }); }} style={ui.input} />}
        <Button secondary onPress={() => router.push('/agent-setup')}>{state.agentVerified ? 'Check agent connection again' : 'Connect your AI'}</Button>
        {!!state.profileId && <Button secondary disabled={!state.loaded || busy} onPress={prepare}>Prepare a new request</Button>}
      </View>
      {!!state.profileId && <View style={ui.card}><Row title={showRequest ? 'Hide layout request' : 'View layout request'} detail="Your saved request for your Mac agent" trailing={showRequest ? '−' : '+'} onPress={() => setShowRequest(!showRequest)} />{showRequest && <Text selectable style={ui.body}>{prompt}</Text>}</View>}

    </View></Columns></Page>;
}
