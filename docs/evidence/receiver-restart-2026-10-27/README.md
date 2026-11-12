# Persistent Mac receiver pairing — October 27, 2026

Implemented, signed and tested locally with the Pixel 7 running the previously installed Android 1.0.0 (3) reconnect build. No new mobile build was needed.

## Cause and fix

The receiver regenerated its TLS certificate and random listening port on every launch, and retained the phone credential only in process memory. The restart regression initially failed on the changed TLS fingerprint.

The receiver now saves its PKCS12 identity, phone pairing credential and listening port in the signed app's Data Protection Keychain. It restores them on startup, preserves TLS pinning and phone binding, and fails visibly if saved credentials cannot be read or saved. No persistent private key or phone credential is written into ordinary profile files. The test harness injects its own isolated secret store and never accesses the user's Keychain.

An initial pairing issued the new persistent identity. After that, two actual signed receiver process restarts automatically reconnected the Pixel without delivering any new pairing link. The TLS pin and endpoint remained identical, the saved controller layout returned, and normal production purchase verification reported connected=true, ready=true, pro=true. Measured reconnects were 0.83 and 0.74 seconds. See pixel-restarts.json.

Explicit receiver “Disconnect and pair again” still revokes the saved phone credential. Mac sleep now releases controls while retaining trust; it no longer calls the explicit reset action. Sleep/wake was not exercised on the physical Mac in this run.

## Validation

- Real mobile-core/receiver integration: background return, fresh phone process, full Mac receiver process restart, exact TLS pin and endpoint retention, wrong-phone rejection and explicit phone-side forgetting passed.
- Native credential tests: saved credential restored by a fresh instance; durable reset; forged and superseded credentials rejected; failed save cannot replace valid pairing; corrupt saved credentials rejected.
- Normal receiver access integration: demo layout/profile access, expiry neutralization, Pro, signed grant and revocation checks passed.
- 40 mobile connection/pairing tests passed. Mobile lint/typecheck and git diff --check passed.
- Existing eight-step Android UI smoke test replay passed after the receiver restarts and another phone-process restart. Its final idle check noted a small changing region; receiver readiness and Pro acceptance were independently confirmed by the real receiver status. This UI smoke test is supplemental, not a TLS or authentication assertion.
- Universal Developer ID receiver build completed and strict signature verification passed.

## Scope

Local receiver build only; no new store submission, notarization or public desktop release was performed. The Android binary remains the prior local version 1.0.0 (3), retaining app/purchase data. The receiver keeps the last local endpoint: DHCP/IP changes and an occupied saved port are outside this restart test. It does not silently rotate identity, bypass pinning, reset demo time or fabricate ownership.

Reproduce with `node tools/test-reconnect-receiver.mjs`. The test compiles a stub-HID receiver, terminates it, relaunches against the same isolated store, and reconnects a phone using only its saved credential.
