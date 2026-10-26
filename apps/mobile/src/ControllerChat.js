import { useCallback, useEffect, useRef, useState } from 'react';
import { Pressable, StyleSheet, Switch, Text, TextInput, View } from 'react-native';
import { connection } from './connection';
import { chatValidation, utf8Length } from './connection-core';
import { useChatSpeech } from './use-chat-speech';

const channels = [['say', 'Say'], ['party', 'Party'], ['raid', 'Raid'], ['guild', 'Guild'], ['instance', 'Instance']];

export function useControllerChat(network) {
  const speech = useChatSpeech();
  const [open, setOpen] = useState(false);
  const [channel, setChannel] = useState('say');
  const [allowNetwork, setAllowNetwork] = useState(false);
  const [options, setOptions] = useState(false);
  const [sending, setSending] = useState(false);
  const sendingNow = useRef(false);
  const mounted = useRef(true);
  const pause = speech.cancel;
  useEffect(() => {
    mounted.current = true;
    connection.resetListeners.add(pause);
    return () => { mounted.current = false; connection.resetListeners.delete(pause); };
  }, [pause]);
  const dismiss = useCallback(() => {
    pause(); setOpen(false); setOptions(false);
  }, [pause]);
  function toggle() {
    if (sendingNow.current) return;
    setOpen(true);
    if (speech.state === 'preparing') { pause(); return; }
    if (speech.state === 'listening') { void speech.stop(); return; }
    if (speech.state === 'finishing') return;
    void speech.start(allowNetwork);
  }
  const canSend = speech.state === 'idle' && !sending && network.phase === 'connected' && network.chat && !chatValidation(speech.draft, channel);
  async function send() {
    if (!canSend || sendingNow.current) return;
    sendingNow.current = true; setSending(true); speech.setError('');
    try {
      await connection.sendChat(speech.draft, channel);
      if (mounted.current) { speech.setDraft(''); setOpen(false); setOptions(false); }
    } catch (error) {
      if (mounted.current) speech.setError(error instanceof Error ? error.message : 'Could not deliver chat.');
    } finally { sendingNow.current = false; if (mounted.current) setSending(false); }
  }
  function discard() { dismiss(); speech.setDraft(''); speech.setError(''); }
  return { ...speech, open, toggle, pause, dismiss, discard, channel, setChannel, allowNetwork, setAllowNetwork, options, setOptions, sending, canSend, send };
}

export default function ControllerChat({ chat, network, top }) {
  if (!chat.open) return null;
  const busy = chat.state !== 'idle';
  // During play, the existing Chat button is the stop/cancel control. Captions
  // never capture a finger or cover the sticks with an interactive surface.
  if (busy) return <View pointerEvents="none" style={s.caption}>
    <Text accessibilityLiveRegion="polite" numberOfLines={2} style={s.captionText}>{chat.draft || (chat.state === 'listening' ? 'Listening… tap Chat to stop' : chat.state === 'finishing' ? 'Finishing…' : 'Preparing dictation… tap Chat to cancel')}</Text>
  </View>;
  return <View testID="controller-chat" style={[s.panel, { top }]}>
    <View style={s.toolbar}>
      <Pressable accessibilityRole="button" accessibilityLabel="Chat channel and speech options" onPress={() => chat.setOptions(!chat.options)} style={s.tool}><Text style={s.action}>{channels.find(([value]) => value === chat.channel)?.[1]} ▾</Text></Pressable>
      <Text style={s.count}>{utf8Length(chat.draft)} / 240</Text>
      <Pressable accessibilityRole="button" accessibilityLabel="Cancel chat" disabled={chat.sending} onPress={chat.discard} style={s.tool}><Text style={s.muted}>Cancel</Text></Pressable>
      <Pressable accessibilityRole="button" disabled={!chat.canSend} accessibilityState={{ disabled: !chat.canSend }} onPress={chat.send} style={[s.tool, !chat.canSend && s.disabled]}><Text style={s.action}>{chat.sending ? 'Sending…' : 'Send'}</Text></Pressable>
    </View>
    <TextInput testID="chat-draft" accessibilityLabel="Chat message" value={chat.draft} onChangeText={chat.setDraft} maxLength={240} editable={!chat.sending} placeholder="Type or tap Chat to dictate…" placeholderTextColor="#A1A1A1" style={s.input} />
    {!!chat.error && <Text accessibilityRole="alert" style={s.error}>{chat.error}</Text>}
    {network.phase !== 'connected' && <Text style={s.detail}>Connect your computer to send.</Text>}
    {network.phase === 'connected' && !network.chat && <Text style={s.detail}>Update the receiver to send chat.</Text>}
    {chat.options && <View style={s.options}>
      <View style={s.channels}>{channels.map(([value, label]) => <Pressable key={value} accessibilityRole="radio" accessibilityState={{ checked: chat.channel === value }} onPress={() => chat.setChannel(value)} style={[s.tool, chat.channel === value && s.selected]}><Text style={s.muted}>{label}</Text></Pressable>)}</View>
      <View style={s.online}><Text style={s.detail}>Allow Apple or Android to process audio online if needed</Text><Switch accessibilityLabel="Allow online recognition" value={chat.allowNetwork} onValueChange={chat.setAllowNetwork} /></View>
    </View>}
  </View>;
}

const s = StyleSheet.create({
  caption: { position: 'absolute', top: '42%', left: '32%', right: '32%', alignItems: 'center' },
  captionText: { color: '#f0f1f2', fontSize: 14, lineHeight: 19, textAlign: 'center', backgroundColor: '#17191bee', paddingHorizontal: 10, paddingVertical: 5, borderRadius: 10 },
  panel: { position: 'absolute', width: '42%', maxWidth: 380, minWidth: 280, alignSelf: 'center', borderRadius: 16, borderCurve: 'continuous', backgroundColor: '#141414f5', borderWidth: 1, borderColor: '#2E2E2E', paddingHorizontal: 10, paddingBottom: 10 },
  toolbar: { flexDirection: 'row', alignItems: 'center', gap: 2 },
  tool: { minHeight: 44, paddingHorizontal: 8, alignItems: 'center', justifyContent: 'center', borderRadius: 8 },
  action: { color: '#EDEDED', fontSize: 14, fontWeight: '600' },
  muted: { color: '#EDEDED', fontSize: 14 },
  count: { flex: 1, color: '#A1A1A1', fontSize: 11, textAlign: 'right', marginRight: 3 },
  input: { color: '#f0f1f2', backgroundColor: '#0A0A0A', fontSize: 16, minHeight: 42, borderRadius: 9, paddingHorizontal: 10, paddingVertical: 8 },
  error: { color: '#F1A59F', fontSize: 13, lineHeight: 18, marginTop: 6 },
  detail: { color: '#A1A1A1', fontSize: 12, lineHeight: 17, flexShrink: 1 },
  disabled: { opacity: 0.4 },
  options: { gap: 4, marginTop: 6 },
  channels: { flexDirection: 'row', flexWrap: 'wrap' },
  selected: { backgroundColor: '#2E2E2E' },
  online: { flexDirection: 'row', alignItems: 'center', gap: 8 },
});
