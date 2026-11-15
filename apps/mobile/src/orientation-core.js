// Serialize native requests: a late completion from setup must not override a
// controller that regained focus while that request was in flight.
export function createOrientationController(apply) {
  let revision = 0;
  let pending = Promise.resolve();
  return {
    request(landscape) {
      const current = ++revision;
      pending = pending.catch(() => {}).then(() => current === revision ? apply(landscape) : undefined);
      return pending;
    },
  };
}
