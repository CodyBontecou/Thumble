import { useEffect, useRef, useState, useSyncExternalStore } from 'react';
import { Share, Text, View } from 'react-native';
import { router } from 'expo-router';
import { connection } from '../connection';
import { matchesAgentCheck } from '../onboarding-core';
import { useSetup } from '../use-setup';
import { Actions, Button, Columns, Eyebrow, Page, Row, ui } from '../ui/design';

// This code correlates a local connection check; it is not a pairing secret.
function checkCode() { return Array.from({ length: 3 }, () => Math.floor(Math.random() * 65536).toString(16).padStart(4, '0')).join(''); }
export default function AgentSetup() {
  const { state, save, error, setError } = useSetup();
  const network = useSyncExternalStore(connection.subscribe, connection.snapshot);
  const [busy, setBusy] = useState(false);
  const [showRequest, setShowRequest] = useState(false);
  const [showHelp, setShowHelp] = useState(false);
  const [checked, setChecked] = useState(/** @type {{code: string, session: string | null} | null} */ (null));
  const checking = useRef(false);
  const online = network.phase === 'connected';
  useEffect(() => { connection.pausePlay(); }, []);
  useEffect(() => { if (state.loaded && !state.agentCode) void save({ agentCode: checkCode() }); }, [state.loaded, state.agentCode]); // eslint-disable-line react-hooks/exhaustive-deps
  const verified = online && checked?.code === state.agentCode && checked?.session === connection.session;
  const prompt = `Check my Thumble agent connection. Call agent_connection_check with code "${state.agentCode}". This is only a connection check; do not change any layout or game bindings. If that tool is missing, help me connect or refresh the tapping-profiles MCP server on my computer first.`;
  async function check() {
    if (checking.current) return;
    checking.current = true; setBusy(true); setChecked(null); setError('');
    const session = connection.session;
    try {
      const catalog = await connection.requestProfiles();
      if (connection.snapshot().phase !== 'connected' || connection.session !== session) throw Error('Connection changed. Run the check again.');
      if (!catalog.agentCheckSupported) throw Error('Update your receiver to check agent connections.');
      if (!matchesAgentCheck(catalog, state.agentCode)) throw Error('No matching check yet. Send the request to your computer agent, then try again within 10 minutes. Make sure your agent and receiver use the same profile folder.');
      if (await save({ agentVerified: true })) setChecked({ code: state.agentCode, session });
    } catch (failure) { setError(failure.message); }
    finally { checking.current = false; setBusy(false); }
  }
  const share = () => { void Share.share({ message: prompt }).catch(failure => setError(failure.message)); };
  return <Page footer={<Actions status={verified ? 'Connection verified' : !online ? 'Connect your computer to verify your agent.' : 'Share the request, then check your connection.'}>
    <View style={{ flex: 1 }}><Button secondary disabled={!state.agentCode} onPress={share}>Share check request</Button></View>
    <View style={{ flex: 1 }}><Button disabled={busy || (online && !state.agentCode)} onPress={verified ? () => router.dismissTo('/first-layout') : !online ? () => router.push('/pair?setup=1') : check}>{verified ? 'Create my first layout' : !online ? 'Connect computer' : busy ? 'Checking…' : 'Check connection'}</Button></View>
  </Actions>}><Columns><View style={ui.column}>
    <Eyebrow>Connect your AI</Eyebrow><Text accessibilityRole="header" style={ui.title}>{'Your agent.\nYour controller.'}</Text>
    <Text style={ui.body}>Share a check request with your computer agent, then verify it here.</Text>
    <Text style={ui.small}>Checks are free. Custom layouts are included in every plan.</Text>
  </View><View style={ui.column}>
    {!!error && <Text accessibilityRole="alert" style={ui.error}>{error}</Text>}
    {verified ? <Text accessibilityLiveRegion="polite" style={ui.body}>Connection verified. Your agent reaches this receiver’s profile folder.</Text> : state.agentVerified && <Text style={ui.small}>Previously verified. Run another check to confirm the current connection.</Text>}
    <View style={ui.card}><Text style={ui.heading}>Your connection check</Text>
      <Row title={showRequest ? 'Hide check request' : 'View check request'} detail="Send this request to your computer agent" trailing={showRequest ? '−' : '+'} onPress={() => setShowRequest(!showRequest)} />
      {showRequest && <Text selectable style={ui.body}>{state.agentCode ? prompt : 'Loading your check code…'}</Text>}
      <Row title="Agent setup instructions" trailing={showHelp ? '−' : '+'} onPress={() => setShowHelp(!showHelp)} />
      {showHelp && <View style={{ gap: 16 }}><Text style={ui.body}>Use Node 22 or newer and the Thumble checkout on your computer. Add a stdio MCP server named tapping-profiles, with node as the command and the full path to packages/profile-tools/src/server.js as its argument. Refresh your agent’s tool connection.</Text><Text style={ui.small}>For Codex, replace the path in this command with your checkout:</Text><Text selectable style={ui.small}>codex mcp add tapping-profiles -- node /absolute/path/to/tapping/packages/profile-tools/src/server.js</Text><Text style={ui.small}>The agent and receiver must use the same profile folder, including TAPPING_PROFILE_DIR if configured.</Text></View>}
    </View>
    {verified && <Button secondary disabled={!online || busy} onPress={check}>Check connection again</Button>}
  </View></Columns></Page>;
}
