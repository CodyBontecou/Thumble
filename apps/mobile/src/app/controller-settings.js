import { useEffect, useRef, useState, useSyncExternalStore } from 'react';
import { Text, View } from 'react-native';
import { router, useIsFocused } from 'expo-router';
import { connection } from '../connection';
import { consolePortSyncView, usesPhoneCalibration } from '../consoleport-sync';
import { Button, Columns, Eyebrow, Page, Row, ui } from '../ui/design';

export default function ControllerSettings() {
  const network = useSyncExternalStore(connection.subscribe, connection.snapshot);
  return <Settings key={network.phase} online={network.phase === 'connected'} />;
}

function Settings({ online }) {
  const focused = useIsFocused();
  const layout = useSyncExternalStore(connection.subscribeProfile, connection.profileSnapshot);
  const [catalog, setCatalog] = useState(null);
  const [loading, setLoading] = useState(online);
  const [error, setError] = useState('');
  const refresh = useRef(() => {});
  useEffect(() => {
    let active = true, pending = false;
    async function read() {
      if (!active || !focused || !online || pending) return;
      pending = true; setLoading(true);
      try { const result = await connection.requestProfiles(); if (active) { setCatalog(result); setError(''); } }
      catch (failure) { if (active) setError(failure.message); }
      finally { pending = false; if (active) setLoading(false); }
    }
    refresh.current = () => { void read(); };
    const initialRead = setTimeout(() => { void read(); }, 0);
    const timer = setInterval(() => { void read(); }, 5000);
    return () => { active = false; clearTimeout(initialRead); clearInterval(timer); };
  }, [focused, online]);
  const status = consolePortSyncView({ online, catalog, profile: layout.profile, error, loading });
  return <Page>
    <View style={{ gap: 12 }}><Eyebrow>Your controller</Eyebrow><Text accessibilityRole="header" style={ui.title}>Set it up your way.</Text><Text style={ui.body}>Customize your phone controls and choose WoW actions. Review binding changes in the game.</Text></View>
    <Columns>
      <View style={ui.column}>
        <View style={ui.card}>
          <Eyebrow>ConsolePort sync · Retail and Classic</Eyebrow>
          <Text accessibilityRole="header" accessibilityLiveRegion="polite" style={ui.heading}>{status.title}</Text>
          {!!status.character && online && <View style={{ gap: 4 }}><Text selectable style={ui.heading}>{status.character}</Text><Text style={ui.small}>Last synced {new Date(status.exportedAt * 1000).toLocaleString()}</Text></View>}
          <Text style={ui.body}>{status.detail}</Text>
          {!!status.receiverDetail && <Text style={ui.small}>{status.receiverDetail}</Text>}
          <Button secondary disabled={!online || loading} onPress={() => refresh.current()}>{loading ? 'Checking…' : 'Check sync status'}</Button>
          {!online && <Button onPress={() => router.push('/pair')}>Connect Mac</Button>}
        </View>
        <View style={ui.card}>
          <Text accessibilityRole="header" style={ui.heading}>In ConsolePort</Text>
          <Text style={ui.body}>Set abilities, button bindings, modifiers, camera behavior and targeting in WoW. Those settings take effect in the game.</Text>
          <Text style={ui.small}>After changing bindings, type /reload to update the phone’s spell labels and modifier layers. Labels and cooldowns do not update live.</Text>
          <Text style={ui.small}>Playing WoW: Forever? Set bindings in its built-in gamepad settings. It needs no addons, and spell-label sync isn’t used.</Text>
          {!!status.modifiers.length && online && <View style={{ gap: 8 }}><Eyebrow>Last synced modifiers</Eyebrow>{status.modifiers.map(item => <View key={item.label} style={{ flexDirection: 'row', justifyContent: 'space-between', gap: 16 }}><Text style={ui.body}>{item.label}</Text><Text style={ui.body}>{item.value}</Text></View>)}</View>}
        </View>
      </View>
      <View style={ui.column}>
        <View style={ui.card}>
          <Text accessibilityRole="header" style={ui.heading}>On this phone</Text>
          <Text style={ui.body}>Touch calibration adjusts your thumbs before input reaches WoW. ConsolePort sync, when used, keeps your phone’s touch layout.</Text>
          <Row title="Touch stick calibration" detail={usesPhoneCalibration(layout.profile) ? 'Movement and camera touch response' : 'This saved controller uses its own stick settings'} disabled={!usesPhoneCalibration(layout.profile)} onPress={() => router.push('/calibration')} />
          <Row title="WoW actions" detail="Choose spells and prepare an in-game binding proposal" onPress={() => router.push('/wow-bindings')} />
          <Row title="Edit layout" detail="Move, resize, add and remap controls" onPress={() => router.push('/layout-editor')} />
          <Row title="Controller profiles" detail={layout.profile.name} onPress={() => router.push('/profiles')} />
          <Row title="WoW setup" detail="WoW version, addons, connection and label sync help" onPress={() => router.push('/wow-setup')} />
        </View>
      </View>
    </Columns>
  </Page>;
}
