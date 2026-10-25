import { xboxProfile } from '@tapping/controller';

// Fixed, synthetic records only. No storage, sign-in, pairing credential, writes,
// delivery queue or hardware connection is reachable from this demonstration.
export function sandboxExample() {
  const at = '2026-10-24T00:00:00.000Z';
  return {
    sandbox: true,
    description: 'Synthetic read-only example. No account, phone, receiver, delivery or gameplay input is connected.',
    profiles: [{ id: 'sample-controller', name: 'Sample controller', revision: 1, updatedAt: at }],
    profile: { profile: { ...xboxProfile, id: 'sample-controller', name: 'Sample controller' }, revision: 1, createdAt: at },
    devices: [{ id: 'sample-phone', name: 'Sample phone (synthetic)', platform: 'ios', viewport: { width: 844, height: 390 }, createdAt: at, lastSeenAt: at, revokedAt: null }],
    delivery: { id: 'sample-delivery', deviceId: 'sample-phone', profileId: 'sample-controller', profileRevision: 1, requestId: 'sample-request', state: 'rendered', createdAt: at, updatedAt: at, error: null },
  };
}
