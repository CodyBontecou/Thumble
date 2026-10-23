import { useEffect, useRef, useState, useSyncExternalStore } from 'react';
import { Text, TextInput, View } from 'react-native';
import { CameraView, useCameraPermissions } from 'expo-camera';
import { useRouter, useLocalSearchParams } from 'expo-router';
import { connection } from '../connection';
import { Button, Columns, Eyebrow, Page, colors, ui } from '../ui/design';

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
    else setError('Allow Camera in Settings, or paste the pairing link from your Mac.');
  }
  useEffect(() => {
    if (typeof params.data === 'string') {
      connection.connect(`tapping://pair?data=${params.data}`).catch(failure => connection.disconnect(failure.message));
    }
  }, [params.data]);
  useEffect(() => { if (state.phase === 'connected') router.replace('/'); }, [state.phase, router]);
  return <Page>
    <Columns><View style={ui.column}><Eyebrow>01 / CONNECT YOUR MAC</Eyebrow><Text accessibilityRole="header" style={ui.title}>{'A small screen.\nA bigger game.'}</Text><Text style={ui.body}>Open Tapping Receiver on your Mac. Keep both devices on the same Wi-Fi, then scan its pairing code.</Text>
      <Button onPress={scan}>Scan Mac QR code</Button>
      <Text style={ui.small}>{state.phase === 'connecting' ? state.detail : 'Pairing codes expire after two minutes. Your connection is encrypted.'}</Text>
      {(error || (state.phase === 'offline' && !state.detail.startsWith('Practice'))) ? <Text accessibilityRole="alert" style={ui.error}>{error || state.detail}</Text> : null}
    </View><View style={ui.column}>
      {scanning && permission?.granted ? <View style={{ gap: 16 }}><CameraView style={{ width: '100%', height: 224, borderRadius: 24, overflow: 'hidden' }} facing="back" barcodeScannerSettings={{barcodeTypes:['qr']}} onBarcodeScanned={({data}) => { if (!barcodeClaimed.current) { barcodeClaimed.current = true; connect(data); } }} onMountError={() => { setScanning(false); setError('Camera could not start. Try again, or paste the pairing link from your Mac.'); }} /><Button secondary onPress={() => setScanning(false)}>Cancel scanning</Button></View> : <View style={ui.card}><Eyebrow>ANOTHER WAY TO CONNECT</Eyebrow><Text style={ui.heading}>Have a pairing link?</Text><Text style={ui.body}>Copy it from the receiver on your Mac and paste it here.</Text><TextInput accessibilityLabel="Mac pairing link" value={link} onChangeText={setLink} autoCapitalize="none" autoCorrect={false} placeholder="tapping://pair?data=…" placeholderTextColor={colors.secondary} style={ui.input} />
      <Button secondary disabled={!link.trim() || state.phase === 'connecting'} onPress={() => connect(link)}>{state.phase === 'connecting' ? 'Connecting…' : 'Connect with link'}</Button></View>}
    </View></Columns>
  </Page>;
}
