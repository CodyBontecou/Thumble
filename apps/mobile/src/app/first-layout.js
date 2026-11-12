import { AI_CONTROLLER_GENERATOR_ENABLED } from '../features';
import { useEffect, useRef, useState, useSyncExternalStore } from 'react';
import { Share, Text, TextInput, View } from 'react-native';
import { xboxProfile, consolePortProfile } from '@tapping/controller';
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
  /** @param {typeof xboxProfile | typeof consolePortProfile} [profile] */
  async function chooseBuiltIn(profile = consolePortProfile) {
    if (checking.current) return;
    checking.current = true; setBusy(true); setError('');
    try {
      if (layout.profile.id !== profile.id) {
        const catalog = await connection.requestProfiles();
        const standard = catalog.profiles.find(entry => entry.id === profile.id);
        if (!standard) throw Error('This built-in controller is missing on your computer. Update your receiver, then try again.');
        await connection.selectProfile(standard, catalog.activationRevision);
      }
      if (await save({ personalized: true, profileId: '', layoutMode: profile.id === consolePortProfile.id ? 'consoleport' : 'familiar' })) router.dismissTo('/onboarding');
    } catch (failure) { setError(failure.message); }
    finally { checking.current = false; setBusy(false); }
  }
  const prompt = firstLayoutPrompt(state, state.sourceProfileId || layout.profile.id);
  const share = () => { void Share.share({ message: prompt }).catch(failure => setError(failure.message)); };
  const delivery = state.personalized ? 'You confirmed this layout arrived on your phone.' : layout.profile.id === state.profileId ? 'Requested layout rendered. Confirm delivery below.' : 'Waiting for your agent to save and activate this layout.';
  const nextAction = state.personalized ? () => router.dismissTo('/onboarding') : !state.profileId ? prepare : network.phase === 'connected' ? checkDelivery : () => router.push('/pair?setup=1');
  const nextLabel = state.personalized ? 'Continue setup' : !state.profileId ? 'Prepare layout request' : network.phase === 'connected' ? 'Check layout delivery' : 'Connect computer';
  if (!AI_CONTROLLER_GENERATOR_ENABLED) return <Page><Columns><View style={ui.column}><Eyebrow>ConsolePort controller</Eyebrow><Text accessibilityRole="header" style={ui.title}>{'Ready for\nyour next game.'}</Text><Text style={ui.body}>Two sticks, face buttons, D-pad, shoulders and triggers. Set your actions and modifier bindings in ConsolePort on your computer.</Text><Button disabled={!state.loaded || busy} onPress={() => chooseBuiltIn()}>{busy ? 'Please wait…' : 'Use ConsolePort controls'}</Button><Button secondary onPress={() => router.push('/calibration')}>Stick calibration</Button>{!!error && <Text accessibilityRole="alert" style={ui.error}>{error}</Text>}</View></Columns></Page>;
  return <Page footer={<Actions status={state.profileId ? delivery : 'Choose preferences, then prepare your request.'}>
    <View style={{ flex: 1 }}><Button secondary disabled={!state.loaded || busy} onPress={state.profileId ? share : () => chooseBuiltIn(consolePortProfile)}>{state.profileId ? 'Share layout request' : 'Keep ConsolePort controls'}</Button></View>
    <View style={{ flex: 1 }}><Button disabled={!state.loaded || busy} onPress={nextAction}>{busy ? 'Please wait…' : nextLabel}</Button></View>
  </Actions>}><Columns><View style={ui.column}><Eyebrow>Your first layout</Eyebrow><Text accessibilityRole="header" style={ui.title}>{'Start with what\nfeels familiar.'}</Text><Text style={ui.body}>Choose a built-in Xbox or ConsolePort controller, or send your preferences to your own AI agent. Your choices and request are saved when you leave.</Text><Button secondary onPress={() => router.push('/cloud')}>Create with your AI in the cloud</Button><Button secondary disabled={!state.loaded || busy} onPress={() => chooseBuiltIn(consolePortProfile)}>Use ConsolePort controls</Button>{(!!state.profileId || state.personalized) && <Button secondary disabled={!state.loaded || busy} onPress={() => chooseBuiltIn(xboxProfile)}>Use Xbox controls</Button>}<Text style={ui.small}>Both built-in controllers work without an AI agent. ConsolePort controls use gamepad labels; set your actions in WoW. Custom layouts are included in the demo.</Text>
      <View style={ui.card}><Text style={ui.heading}>Choose a starting point</Text>{[['familiar', 'Familiar controls', 'Start from the Xbox-style arrangement'], ['consoleport', 'Match ConsolePort', 'Use a fresh character export from Thumble'], ['character', 'Build for my character', 'Use learned spells and review binding changes in-game']].map(([value, title, detail]) => <Row key={value} title={title} detail={detail} trailing={state.layoutMode === value ? '✓' : '›'} disabled={!state.loaded || busy} onPress={() => preference({ layoutMode: value })} />)}</View>
    </View><View style={ui.column}>
      {!!error && <Text accessibilityRole="alert" style={ui.error}>{error}</Text>}
      <View style={ui.card}><Text style={ui.heading}>Make it comfortable</Text><Row title="Button size" detail={state.buttonSize === 'larger' ? 'Larger action buttons' : 'Standard size'} disabled={!state.loaded || busy} onPress={() => preference({ buttonSize: state.buttonSize === 'larger' ? 'standard' : 'larger' })} /><Row title="Movement side" detail={state.movementSide === 'left' ? 'Left thumb' : 'Right thumb'} disabled={!state.loaded || busy} onPress={() => preference({ movementSide: state.movementSide === 'left' ? 'right' : 'left' })} />{state.layoutMode === 'character' && <TextInput accessibilityLabel="Character or class" placeholder="Character or class (optional)" placeholderTextColor="#A1A1A1" maxLength={80} value={character} onChangeText={value => { setDraftCharacter(value); void preference({ character: value }); }} style={ui.input} />}
        <Button secondary onPress={() => router.push('/agent-setup')}>{state.agentVerified ? 'Check agent connection again' : 'Connect your AI'}</Button>
        {!!state.profileId && <Button secondary disabled={!state.loaded || busy} onPress={prepare}>Prepare a new request</Button>}
      </View>
      {!!state.profileId && <View style={ui.card}><Row title={showRequest ? 'Hide layout request' : 'View layout request'} detail="Your saved request for your computer agent" trailing={showRequest ? '−' : '+'} onPress={() => setShowRequest(!showRequest)} />{showRequest && <Text selectable style={ui.body}>{prompt}</Text>}</View>}

    </View></Columns></Page>;
}
