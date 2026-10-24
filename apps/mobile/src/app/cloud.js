import { AI_CONTROLLER_GENERATOR_ENABLED } from '../features';
import { useEffect, useState, useSyncExternalStore } from 'react';
import { ActivityIndicator, Share, Text, TextInput, View } from 'react-native';
import { router } from 'expo-router';
import { cloud, signInCloud, manageCloudAccount } from '../cloud/store';
import { DEFAULT_CLOUD_URL } from '../cloud/oauth';
import { cloudLayoutPrompt } from '../onboarding-core';
import { useSetup } from '../use-setup';
import { connection } from '../connection';
import { adoptCloudSelection } from '../cloud/adoption';
import { Button, Columns, Eyebrow, Page, Row, colors, ui } from '../ui/design';

export default function CloudLibrary() {
  return AI_CONTROLLER_GENERATOR_ENABLED ? <CloudGenerator /> : <CloudAccount />;
}
function CloudAccount() {
  const state = useSyncExternalStore(cloud.subscribe, cloud.snapshot);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  useEffect(() => { void cloud.load().catch(failure => setError(failure.message)); }, []);
  async function act(operation) {
    setBusy(true); setError('');
    try { await operation(); } catch (failure) { setError(failure.message); }
    finally { setBusy(false); }
  }
  return <Page><View style={ui.column}><Eyebrow>CLOUD ACCOUNT</Eyebrow><Text accessibilityRole="header" style={ui.title}>Your account.</Text>
    {!state.loaded ? <ActivityIndicator /> : state.session ? <>
      <Text style={ui.body}>Manage your existing cloud account or remove its saved connection from this phone.</Text>
      <Button disabled={busy} onPress={() => act(manageCloudAccount)}>Manage or delete account</Button>
      <Button secondary disabled={busy} onPress={() => act(() => cloud.logout())}>Sign out</Button>
    </> : <Text style={ui.body}>No cloud account is connected on this phone.</Text>}
    {!!(error || state.error) && <Text accessibilityRole="alert" style={ui.error}>{error || state.error}</Text>}
  </View></Page>;
}
function CloudGenerator() {
  const state = useSyncExternalStore(cloud.subscribe, cloud.snapshot);
  const { state: setup } = useSetup();
  const network = useSyncExternalStore(connection.subscribe, connection.snapshot);
  const [service, setService] = useState(DEFAULT_CLOUD_URL);
  const [editingService, setEditingService] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const session = state.session;
  const wow = setup.layoutMode === 'consoleport' || setup.layoutMode === 'character';
  const adopted = state.macAdoption && network.phase === 'connected' && state.macAdoption.pairing === connection.session && state.macAdoption.source.accountId === session?.accountId && state.macAdoption.source.profileId === state.selected?.profile.id && state.macAdoption.source.revision === state.selected?.revision;
  async function useOnMac() {
    setBusy(true); setError('');
    try {
      await adoptCloudSelection(cloud, connection);
      router.dismissTo('/?practice=1');
    } catch (failure) { setError(failure.message); }
    finally { setBusy(false); }
  }
  async function signIn() {
    setBusy(true); setError('');
    try { await signInCloud(service.trim()); }
    catch (failure) { setError(failure.message); }
    finally { setBusy(false); }
  }
  async function logout() {
    setBusy(true); setError('');
    try { await cloud.logout(); } catch { setError('Could not erase saved credentials. Try signing out again.'); }
    finally { setBusy(false); }
  }
  async function deleteAccount() {
    setBusy(true); setError('');
    try { await manageCloudAccount(); }
    catch (failure) { setError(failure.message); }
    finally { setBusy(false); }
  }
  async function preview(profile) {
    await cloud.preview(profile.id, profile.revision);
    const selected = cloud.snapshot().selected;
    if (selected?.profile.id === profile.id && selected?.revision === profile.revision && cloud.snapshot().lanOffline) router.dismissTo('/?practice=1');
  }
  const prompt = session ? cloudLayoutPrompt(setup, session) : '';
  async function shareRequest() {
    setBusy(true); setError('');
    try { await cloud.syncViewport(); await Share.share({ message: prompt }); }
    catch (failure) { setError(failure.message); }
    finally { setBusy(false); }
  }
  return <Page><Columns><View style={ui.column}>
    <Eyebrow>{wow ? 'WOW + CONSOLEPORT' : 'CONTROLLERS FROM YOUR AI'}</Eyebrow><Text accessibilityRole="header" style={ui.title}>Build it anywhere.<Text>{'\n'}Try it here.</Text></Text>
    <Text style={ui.body}>Ask your AI to create a controller, then try it on this phone. Your cloud library works without a Mac connection.</Text>
    {session && <View style={ui.card}>
      <Text style={ui.heading}>{session.device.name}</Text><Text selectable style={ui.small}>{session.service}</Text><Text selectable style={ui.small}>Device: {session.device.id}</Text>
      <Text style={ui.small}>Keep Thumble open to receive controllers. Saved previews remain available offline until you sign out.</Text>
      <Button disabled={busy} secondary onPress={shareRequest}>Share request with your AI</Button>
      <Button secondary onPress={() => router.push('/journey')}>View AI to WoW progress</Button>
      <Button disabled={busy} secondary onPress={logout}>Sign out and disconnect phone</Button>
      <Row title="Delete account" detail="Review and confirm deletion in your browser" disabled={busy} onPress={deleteAccount} />
    </View>}
    {!!(error || state.error) && <Text accessibilityRole="alert" style={ui.error}>{error || state.error}</Text>}
  </View><View style={ui.column}>
    {!state.loaded ? <ActivityIndicator color={colors.text} /> : !session && <View style={[ui.card, { padding: 16, gap: 12 }]}>
      <Text style={ui.heading}>Connect your cloud account</Text><Text style={ui.small}>Turn your phone sideways once to size your controller. Continue with email, Apple, or Google securely in your browser.</Text>
      {editingService && <TextInput accessibilityLabel="Cloud service URL" placeholder="https://your-cloud-service.example" placeholderTextColor={colors.secondary} value={service} onChangeText={setService} autoCapitalize="none" autoCorrect={false} keyboardType="url" textContentType="URL" style={ui.input} editable={!busy} />}
      <Button disabled={busy || state.busy || !service.trim()} onPress={signIn}>{busy || state.busy ? 'Connecting…' : 'Sign in and connect phone'}</Button>
      <Row title={editingService ? 'Hide service address' : 'Change cloud service'} onPress={() => setEditingService(!editingService)} />
    </View>}
    {session && <View style={ui.card}>
      <Text style={ui.heading}>{adopted ? 'Ready on your Mac' : state.pending ? 'A controller has arrived' : state.selected ? 'Your cloud controller' : 'Ready for your first controller'}</Text>
      <Text style={ui.body}>{state.selected ? `${state.selected.profile.name} · revision ${state.selected.revision}` : 'Share a request with your AI, or choose a saved controller below.'}</Text>
      {state.selected && state.lanOffline && <><Button onPress={() => router.dismissTo('/?practice=1')}>Try controller in practice</Button><Button secondary onPress={() => router.push('/pair')}>Connect Mac to use this controller</Button></>}
      {state.selected && network.phase === 'connected' && <Button disabled={busy || state.busy} onPress={useOnMac}>{busy ? 'Confirming on Mac…' : adopted ? 'Open this controller on Mac' : 'Use this controller on Mac'}</Button>}
      {adopted && <Text accessibilityLiveRegion="polite" style={ui.small}>Saved as a separate Mac profile and acknowledged by this phone. Resume controls when you are ready, then test your bindings in ConsolePort.</Text>}
      {state.pending && <Text accessibilityLiveRegion="polite" style={ui.small}>Downloaded. Open it in practice, or choose Use on Mac and open the confirmed controller to finish the phone render receipt.</Text>}
    </View>}
    {session && <View style={ui.card}><Text style={ui.heading}>Saved controllers</Text>
      <Button secondary disabled={state.busy || busy} onPress={() => { void cloud.refreshProfiles(); }}>Refresh library</Button>
      {!state.profiles.length && <Text style={ui.small}>Your library is empty. Ask your AI to save your first controller.</Text>}
      {state.profiles.map(profile => <Row key={profile.id} title={profile.name} detail={`Revision ${profile.revision}`} disabled={busy || state.busy || Boolean(state.pending)} onPress={() => { void preview(profile); }} />)}
    </View>}
  </View></Columns></Page>;
}
