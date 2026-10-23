# Monetization implementation validation — October 23, 2026

The implementation is present in source. Live purchases remain disabled in the
checked-in configuration because store products, production identifiers, signing
keys and the first-party verification endpoint have not been configured.

## Automated checks

- `npm test`: 81 passing tests, including purchase cancellation/pending states,
  duplicate request prevention, stale refresh/pairing rejection, signed capability
  grants, Google purchase-state/acknowledgement behavior, unpaid MCP/profile availability and expired-demo chat/input gating.
- `npm run test:access`: native fake-clock coverage of setup/pause accounting,
  cumulative use through 1,800 seconds, process-death pre-debits, re-pairing,
  wall-clock changes, grant signatures/bindings, cached ownership, revocation and
  corrupt-ledger behavior.
- `node tools/test-access-receiver.mjs`: a real TLS/WebSocket receiver linked to
  fake HID reporting verifies custom layout delivery and profile listing/selection without purchase, neutral
  output at expiry during held input and unlimited output after a signed grant.
  Revocation preserves custom layouts/profile access and reinstates the time cap. No gameplay input
  reaches a real HID device.
- Mobile lint/typecheck and shared controller syntax check pass.
- Native/Node catalog compatibility and native chat validation pass.
- iOS Release simulator build, unsigned iPhone-target Release build and Android
  Release build pass. Physical-target compilation includes the production
  Keychain path; unsigned iOS simulators use sandbox defaults.

## UI evidence

The iOS QA simulator paired with an isolated fake-HID receiver. The demo start
screen displayed the total allowance, started successfully, and returned to a
paused controller when opening the menu. Pro presentation and return navigation
were exercised. Android QA emulator inspection covered the Pro feature list,
store-unavailable state, disabled purchase action and visible restore/retry
controls. No actual payment was made.

Recording: [iOS demo start/pause and Pro navigation](../../.argent/recordings/screen-recording-2C25402F-F87F-46EA-A615-A1A9C0689EC6-1792793137876.mp4).
The local recording is ignored by Git. UI inspection is not evidence of a real
store transaction or physical-gameplay qualification.

## Remaining release work

Follow [native purchase setup](../monetization-setup.md) to configure store
products/prices and the verifier, then run real sandbox purchase/restore/refund
checks. Physical-device speech/gameplay qualification and the documented Apple
metered-demo / Blizzard addon commercial-policy questions remain release work.

The feature gates from the initial implementation have been removed. The full
demo and Pro now have identical features; the only difference is unlimited use.
