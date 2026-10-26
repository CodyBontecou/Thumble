import { useCallback, useEffect, useRef, useState, useSyncExternalStore } from 'react';
import { AppState, Text, TextInput, View } from 'react-native';
import { CameraView, useCameraPermissions } from 'expo-camera';
import { useFocusEffect, useRouter, useLocalSearchParams } from 'expo-router';
import { onboarding } from '../onboarding';
import { connection } from '../connection';
import { followPairingLink } from '../pairing-link';
import { Actions, Button, Columns, Eyebrow, Page, colors, ui } from '../ui/design';

export default function PairScreen() {
  const router = useRouter();
  const [permission, requestPermission] = useCameraPermissions();
  const [scanning, setScanning] = useState(false);
  const [link, setLink] = useState('');
  const [error, setError] = useState('');
  const state = useSyncExternalStore(connection.subscribe, connection.snapshot);
  const params = useLocalSearchParams();
  const barcodeClaimed = useRef(false);
  async function connect(value) {
    setScanning(false); setError('');
    try { await connection.connect(value); } catch (failure) { setError(failure.message); }
  }
  async function scan() {
    setError('');
    const result = permission?.granted ? permission : await requestPermission();
    if (result.granted) { barcodeClaimed.current = false; setScanning(true); }
    else setError('Allow Camera in Settings, or paste the pairing link from your computer.');
  }
  useFocusEffect(useCallback(() => {
    if (typeof params.data !== 'string') return;
    setError('');
    return followPairingLink(connection, AppState, `thumble://pair?data=${params.data}`, failure => setError(failure.message));
  }, [params.data]));
  useEffect(() => {
    if (state.phase === 'connected') void onboarding.update({ paired: true }).then(() => router.dismissTo(params.returnTo === 'wow' ? '/wow-setup' : params.returnTo === 'journey' ? '/journey' : params.setup === '1' ? '/onboarding' : '/')).catch(failure => setError(failure.message));
  }, [state.phase, router, params.setup, params.returnTo]);
  const failure = error || (state.phase === 'offline' && !state.detail.startsWith('Practice') ? state.detail : '');
  return <Page style={{ paddingTop: 16 }} footer={<Actions status={state.phase === 'connecting' ? state.detail : failure ? 'Could not pair. Scan the current code on your computer.' : 'Same Wi-Fi · encrypted connection'}>
    <View style={{ flex: 1 }}><Button disabled={state.phase === 'connecting'} onPress={scan}>Scan computer QR code</Button></View>
    {typeof params.data === 'string' && <View style={{ flex: 1 }}><Button secondary disabled={state.phase === 'connecting'} onPress={() => connect(`thumble://pair?data=${params.data}`)}>Try pairing again</Button></View>}
  </Actions>}>
    <Columns><View style={[ui.column, { gap: 16 }]}><Eyebrow>01 / CONNECT YOUR COMPUTER</Eyebrow><Text accessibilityRole="header" style={ui.title}>{'Connect your phone.\nKeep WoW on desktop.'}</Text><Text style={ui.body}>Install Thumble Receiver for your computer and open it. Open its pairing window, then scan the QR code here. Keep both devices on the same Wi-Fi.</Text>
      <Text style={ui.small}>{state.phase === 'connecting' ? state.detail : 'Pairing codes expire after two minutes. Your connection is encrypted.'}</Text>
    </View><View style={[ui.column, { gap: 16 }]}>{!!failure && <Text accessibilityRole="alert" style={ui.error}>{failure}</Text>}
      {scanning && permission?.granted ? <View style={{ gap: 16 }}><CameraView style={{ width: '100%', height: 224, borderRadius: 24, overflow: 'hidden' }} facing="back" barcodeScannerSettings={{barcodeTypes:['qr']}} onBarcodeScanned={({data}) => { if (!barcodeClaimed.current) { barcodeClaimed.current = true; connect(data); } }} onMountError={() => { setScanning(false); setError('Camera could not start. Try again, or paste the pairing link from your computer.'); }} /><Button secondary onPress={() => setScanning(false)}>Cancel scanning</Button></View> : <View style={[ui.card, { padding: 16, gap: 12 }]}><Eyebrow>ANOTHER WAY TO CONNECT</Eyebrow><Text style={ui.heading}>Have a pairing link?</Text><Text style={ui.body}>Copy it from the receiver on your computer and paste it here.</Text><TextInput accessibilityLabel="Computer pairing link" value={link} onChangeText={setLink} autoCapitalize="none" autoCorrect={false} placeholder="thumble://pair?data=…" placeholderTextColor={colors.secondary} style={ui.input} />
      <Button secondary disabled={!link.trim() || state.phase === 'connecting'} onPress={() => connect(link)}>{state.phase === 'connecting' ? 'Connecting…' : 'Connect with link'}</Button></View>}
    </View></Columns>
  </Page>;
}
