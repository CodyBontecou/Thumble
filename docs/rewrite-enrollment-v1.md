# Rewrite native enrollment envelope v1, control protocol v2

The Rust coordinator and native Swift/Kotlin phone clients now exchange enrollment over pinned TLS. Shared fixtures and actual Network.framework/JVM TLS clients exercise the native host trust ledger. Native phone credential vaults are implemented; real OS-provider runtime tests are prepared in headless CI but have not run for this source yet. Product listener activation, service/CLI forwarding to the native window owner, phone application integration and input-session grants remain pending. Existing service `PairingWindows` remains the current CLI implementation until forwarding is wired; it does not silently authorize the native coordinator.

TLS framing/ALPN remains version 1. The JSON envelope is version 1, while independently negotiated control version 2 adds a required final host confirmation after the phone's storage acknowledgment. Input, document and capability envelope versions remain independently checked at 1. These checks do not implement document operations or enable input. Earlier control-version peers fail negotiation before proof consumption. An invitation is not a trusted phone or an input grant.

Only authenticated same-user setup may open/cancel/status the native window. It binds an immutable authority instance and persistent host pin. An offer contains a random 128-bit opaque window identifier, random 256-bit lowercase hex secret and expiry at native wall time plus 120 seconds. Opening replaces previous material before generating entropy. Only the domain-separated SHA-256 verifier is retained. Five failed proofs exhaust a window; the fifth valid proof succeeds once. Cancellation, replacement, expiry, restart and clock failure/rollback retire pending material. Status contains no secret/verifier and advertises networking disabled until listener integration exists. Shared TypeScript/native fixtures preserve hash, offer and status semantics during migration.

The host coordinator accepts only an open server-side TLS channel presenting the window owner's exact pin, with a ledger bound to the same pin. The phone constructs its TLS transport from a validated native invitation, verifies the host certificate through the existing TLS policy, and checks the returned authority before sending the secret. Invitations and credentials have redacted native descriptions. Native clients validate bounded phone identifiers and UTF-8 labels before beginning enrollment.

The phone sends exactly:

```json
{
  "version": 1,
  "command": "hello",
  "controlVersion": 2,
  "inputVersion": 1,
  "documentVersion": 1,
  "capabilitiesVersion": 1
}
```

The host reply has the same fields plus `authorityInstanceId` and `inputEnabled:false`. The phone requires an exact match. Both phone decoders accept only bounded flat objects of strings, nonnegative signed-range 64-bit integers and booleans. Invalid UTF-8, duplicate decoded keys (including Unicode escape aliases), invalid escapes/surrogates, coercions, unsupported shapes, unknown/extra fields and trailing data fail closed. Message-specific checks enforce exact types, canonical positive decimal credential epochs and expiry. All frames retain native size/deadline limits; receiving input during enrollment fails.

The next phone control frame has exactly `version:1`, `command:"enroll"`, `authorityInstanceId`, `windowId`, `proof`, `phoneId` and `label`. Phone identifiers follow the bounded native identity grammar; labels are nonempty, at most 128 UTF-8 bytes and contain no control characters. The phone rechecks invitation expiry and native clock monotonicity immediately before sending its proof. The host validates metadata, consumes the window under a short policy lock, then releases that lock before storage or network operations. Cancellation/replacement during negotiation takes effect at consumption. Canceling an already consumed window does not revoke committed trust.

The host trust transaction generates the credential, increments its epoch and commits before sending the `enrolled` reply from ADR 0005. The phone validates the reply's identity, epoch, expiry and secret shape, constructs its opaque native credential, and waits for vault save plus verified readback. Swift performs storage on a separate native actor; Android enforces a native worker for its production entry point. Storage failure prevents acknowledgment. A successful save is followed by exactly `version:1`, `command:"enrollment-stored"`, `phoneId` and `credentialEpoch`. The host cannot independently attest the phone's storage action.

After validating that acknowledgment, the host sends exactly `version:1`, `command:"enrollment-complete"`, `phoneId`, `credentialEpoch` and `inputEnabled:false`. The phone returns success only after receiving this matching reply and rechecking clock/expiry. Neither side grants input. Successful native callers retain their control channel for later owner integration; public phone client APIs do not expose a general raw-packet or secret export port.

Any host failure closes TLS. After proof consumption, storage or network failures never restore the window. Lost/wrong acknowledgments or completion preserve committed trust and report unconfirmed delivery. Phone failures close their transport and preserve potentially saved credentials for explicit recovery. Cancellation during save cannot promise that the credential was not persisted; it fences the subsequent acknowledgment. Late Android connection completion after close is retired before sending proof. No automatic replay/retry reuses an invitation; recovery requires a fresh locally authorized window.

Blocking host operations run on a bounded native worker, never the input/safety/UI thread. Window policy locks are not held during TLS reads/writes. Swift uses MainActor coordination with asynchronous Network.framework I/O and a separate storage actor. Android uses its caller's native worker, terminal cancellation and at most one transient closer. Production listener admission, owner leases, authenticated reconnect, credential recovery/rotation, session-epoch revocation and the React Native app remain separate integration gates.

`enrollment-v1.json` fixes the proof and versioned message shapes. `enrollment-control-v2.json` supplies valid and hostile phone-control fixtures. `enrollment_probe` is a synthetic loopback-only executable built for tests, never installed in the product. Both native phones enroll through real TLS against its Rust ledger; tests also cover storage failures, cancellation, clock rollback, stale versions and missing/mismatched final confirmation. Real Keychain and AndroidKeyStore tests are separately compiled and wired into CI. Their result verifiers require the named provider case to pass and reject missing/skipped/empty evidence, including optimized Python execution. This source still needs its scoped CI publication and actual provider runtime evidence; physical signing, gameplay, optical sync and latency acceptance remain pending.
