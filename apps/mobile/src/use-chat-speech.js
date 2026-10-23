import { useCallback, useEffect, useRef, useState } from 'react';
import { AppState, PermissionsAndroid, Platform } from 'react-native';
import { requireOptionalNativeModule } from 'expo-modules-core';


const speech = requireOptionalNativeModule('TappingSpeech');
let nextSession = 0;

export function useChatSpeech() {
  const [draft, setDraft] = useState('');
  const [state, setState] = useState('idle');
  const [engine, setEngine] = useState('Uses your phone’s speech language');
  const [error, setError] = useState('');
  const session = useRef(/** @type {string | null} */ (null));
  const base = useRef('');
  const cancel = useCallback(() => {
    session.current = null;
    setState('idle');
    speech?.cancel().catch(() => {});
  }, []);
  useEffect(() => {
    const listener = speech?.addListener('speech', event => {
      if (!session.current || event.id !== session.current) return;
      if (typeof event.text === 'string') setDraft(base.current + event.text);
      if (event.engine) setEngine(event.engine);
      if (event.error) { setError(event.error); cancel(); }
      else if (event.state === 'done') { session.current = null; setState('idle'); }
      else if (event.state) setState(event.state);
    });
    const app = AppState.addEventListener('change', value => { if (value === 'background') cancel(); });
    return () => { listener?.remove(); app.remove(); session.current = null; speech?.cancel().catch(() => {}); };
  }, [cancel]);
  async function start(allowNetwork) {
    if (session.current) return;
    setError('');
    if (!speech) { setError('Install a new development build to enable voice dictation. You can still type a message.'); return; }
    const id = `speech-${Date.now()}-${++nextSession}`;
    session.current = id;
    base.current = draft.trim() ? draft.trimEnd() + ' ' : '';
    setState('preparing');
    try {
      if (Platform.OS === 'android') {
        const permission = await PermissionsAndroid.request(PermissionsAndroid.PERMISSIONS.RECORD_AUDIO);
        if (session.current !== id) return;
        if (permission !== PermissionsAndroid.RESULTS.GRANTED) throw Error('Microphone access is disabled. Enable it in Settings, or type your message.');
      }
      if (session.current !== id) return;
      await speech.start(id, '', allowNetwork);
    } catch (error) {
      if (session.current === id) { setError(error instanceof Error ? error.message : 'Could not start dictation.'); cancel(); }
    }
  }
  async function stop() {
    if (!session.current) return;
    setState('finishing');
    try { await speech?.stop(); }
    catch { setError('Could not finish dictation. Review the text or try again.'); cancel(); }
  }
  return { draft, setDraft, state, engine, error, setError, start, stop, cancel };
}
