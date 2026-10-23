import { useCallback, useEffect, useState, useSyncExternalStore } from 'react';
import { ActivityIndicator, FlatList, Pressable, StyleSheet, Text, View } from 'react-native';
import { connection } from '../connection';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';
import { Eyebrow, ui } from '../ui/design';

export default function ProfilesScreen() { return <SafeAreaProvider><Profiles /></SafeAreaProvider>; }

function Profiles() {
  const network = useSyncExternalStore(connection.subscribe, connection.snapshot);
  const layout = useSyncExternalStore(connection.subscribeProfile, connection.profileSnapshot);
  const [catalog, setCatalog] = useState(/** @type {{profiles: {id: string, name: string, revision: number}[], activationRevision: number}} */ ({ profiles: [], activationRevision: 0 }));
  const [loading, setLoading] = useState(true);
  const [selecting, setSelecting] = useState('');
  const [error, setError] = useState('');
  const refresh = useCallback(async () => {
    setError(''); setLoading(true);
    try { setCatalog(await connection.requestProfiles()); }
    catch (failure) { setError(failure.message); }
    finally { setLoading(false); }
  }, []);
  useEffect(() => {
    let active = true;
    connection.requestProfiles().then(result => { if (active) setCatalog(result); })
      .catch(failure => { if (active) setError(failure.message); })
      .finally(() => { if (active) setLoading(false); });
    return () => { active = false; };
  }, []);
  async function choose(profile) {
    setError(''); setSelecting(profile.id);
    try { setCatalog(await connection.selectProfile(profile, catalog.activationRevision)); }
    catch (failure) { setError(failure.message); }
    finally { setSelecting(''); }
  }
  return <SafeAreaView style={s.safeArea} edges={['left', 'right', 'bottom']}><View style={s.screen}>
    <View style={{ gap: 8, paddingTop: 16 }}><Eyebrow>YOUR CONTROLLER LIBRARY</Eyebrow><Text accessibilityRole="header" style={ui.title}>Ready when you are.</Text></View><View style={s.intro}>
      <Text style={s.detail}>Choose a saved controller from your Mac.</Text>
      <Pressable accessibilityRole="button" onPress={refresh} disabled={loading || !!selecting} style={s.refresh}><Text style={s.action}>Refresh</Text></Pressable>
    </View>
    {error ? <Text accessibilityRole="alert" style={s.error}>{error}</Text> : null}
    {loading ? <ActivityIndicator accessibilityLabel="Loading profiles" color="#EDEDED" style={s.loading} /> :
      <FlatList data={catalog.profiles} keyExtractor={item => item.id} contentContainerStyle={s.list}
        extraData={[layout, selecting, network.phase]}
        ListEmptyComponent={<Text style={s.detail}>{error ? '' : 'No saved profiles yet. Ask your agent to create one.'}</Text>}
        renderItem={({ item }) => {
          const selected = layout.profile.id === item.id && layout.revision > 0;
          const busy = selecting === item.id;
          return <Pressable accessibilityRole="button" accessibilityLabel={item.name} accessibilityState={{ selected, disabled: !!selecting || network.phase !== 'connected' }}
            disabled={!!selecting || network.phase !== 'connected'} onPress={() => choose(item)}
            style={({ pressed }) => [s.row, pressed && s.pressed]}>
            <View style={{ flex: 1, gap: 4 }}><Text style={s.name}>{item.name}</Text><Text style={ui.small}>Saved on your Mac</Text></View>
            {busy ? <ActivityIndicator accessibilityLabel="Switching profile" color="#EDEDED" /> : selected ? <Text style={s.selected}>Selected</Text> : null}
          </Pressable>;
        }} />}
  </View></SafeAreaView>;
}
const s = StyleSheet.create({
  safeArea: { flex: 1, backgroundColor: '#0A0A0A' },
  screen: { flex: 1, paddingHorizontal: 24 },
  intro: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 16 },
  detail: { color: '#A1A1A1', fontSize: 15, lineHeight: 22, flexShrink: 1 },
  action: { color: '#EDEDED', fontSize: 17, fontWeight: '600' },
  refresh: { minHeight: 48, minWidth: 72, justifyContent: 'center', alignItems: 'center' },
  loading: { marginTop: 24 },
  error: { color: '#F1A59F', fontSize: 15, marginBottom: 12 },
  list: { paddingBottom: 24, gap: 8 },
  row: { minHeight: 60, flexDirection: 'row', alignItems: 'center', gap: 16, paddingVertical: 16, borderWidth: 1, borderRadius: 16, borderCurve: 'continuous', paddingHorizontal: 24, backgroundColor: '#141414', borderColor: '#2E2E2E' },
  pressed: { backgroundColor: '#1F1F1F' },
  name: { flex: 1, color: '#EDEDED', fontSize: 17 },
  selected: { color: '#EDEDED', fontSize: 15, fontWeight: '600' },
});
