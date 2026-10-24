// Keep link handling scoped to the focused pairing screen. A deep link can arrive
// while iOS is still inactive; opening its socket then fails the foreground guard.
export function followPairingLink(connection, appState, value, onError) {
  let stopped = false, pending = false, foreground = 0, ownedAttempt = -1;
  function start() {
    if (stopped || pending || appState.currentState !== 'active' || connection.snapshot().phase !== 'offline') return;
    pending = true;
    const startedAt = foreground;
    const opening = connection.connect(value);
    ownedAttempt = connection.attempt;
    opening.catch(error => {
      if (!stopped && connection.attempt === ownedAttempt) onError(error);
    }).finally(() => {
      pending = false;
      // A foreground event may have arrived during asynchronous preparation.
      if (foreground !== startedAt) start();
    });
  }
  const subscription = appState.addEventListener('change', phase => {
    if (phase === 'active') { foreground++; start(); }
  });
  start();
  return () => {
    stopped = true;
    subscription.remove();
    if (connection.attempt === ownedAttempt && connection.snapshot().phase !== 'connected' && (pending || connection.snapshot().phase === 'connecting')) connection.disconnect();
  };
}
