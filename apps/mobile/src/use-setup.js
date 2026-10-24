import { useEffect, useState, useSyncExternalStore } from 'react';
import { onboarding } from './onboarding';
export function useSetup() {
  const state = useSyncExternalStore(onboarding.subscribe, onboarding.snapshot);
  const [error, setError] = useState('');
  useEffect(() => { void onboarding.load().catch(failure => setError(failure.message)); }, []);
  async function save(patch) {
    setError('');
    try { await onboarding.update(patch); return true; }
    catch (failure) { setError(failure.message); return false; }
  }
  return { state, save, error, setError };
}
