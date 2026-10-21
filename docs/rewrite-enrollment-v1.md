# Rewrite native enrollment protocol v1

Implemented as a Rust native worker operation over the existing pinned TLS channel. It is exercised through real synthetic loopback TLS. Product listener activation, service/CLI forwarding to this native window owner and phone secure-storage integration remain pending. Existing service `PairingWindows` remains the current CLI implementation until that forwarding is wired; it does not silently authorize this coordinator. Shared fixture tests keep the proof hash, offer and status semantics aligned during that transition.

Only authenticated same-user setup may call the native window owner's open/cancel/status operations. The owner binds an immutable authority instance and persistent host pin. An offer contains a random 128-bit opaque window identifier, random 256-bit lowercase hex secret and expiry at native wall time plus 120 seconds. Opening replaces previous material before entropy generation. Only a domain-separated SHA-256 verifier is retained. The verifier binds authority, window identifier and proof using the exact UTF-8 construction in ADR 0001. Five failed proofs exhaust the window; a valid fifth proof succeeds once. Cancellation, replacement, expiry, restart and clock failure/rollback retire pending material. Status contains no secret or verifier and advertises networking disabled until product listener integration exists.

The coordinator requires an open server-side channel presenting exactly the window owner's pin, and the ledger must be bound to that same pin. It rejects client-role/wrong-host channels before reading control messages. Each receive/send retains the transport's bounded frame size and absolute operation timeout. This blocking operation belongs on a bounded native network worker, never on the safety, input-sampling or UI thread. It does not create worker threads or open sockets itself.

The phone sends a control frame containing exactly:

```json
{
  "version": 1,
  "command": "hello",
  "controlVersion": 1,
  "inputVersion": 1,
  "documentVersion": 1,
  "capabilitiesVersion": 1
}
```

Each version is checked independently. Unsupported versions, unknown/duplicate fields, invalid JSON, wrong phase and input frames fail closed. This envelope negotiation does not implement document operations or enable input. On success the host replies with the same version fields plus `authorityInstanceId` and `inputEnabled:false`. The phone must match that authority to the invitation before transmitting its proof.

The next control frame is exactly `version:1`, `command:"enroll"`, `authorityInstanceId`, `windowId`, `proof`, `phoneId` and `label`. Identifiers use the existing bounded native identity grammar; phone labels are nonempty, at most 128 UTF-8 bytes and contain no control characters. Invalid phone metadata fails before consumption. The native owner consumes the proof under its short policy lock, then releases that lock before storage or network operations. Cancellation/replacement during TLS negotiation takes effect at proof consumption. Canceling a consumed window does not revoke committed trust; the owner must use revocation for that.

The native trust transaction generates a fresh credential, increments its epoch and commits before sending the `enrolled` reply defined by ADR 0005. The phone must persist its host pin, phone identifier, credential, epoch and expiry in platform secure storage before responding with exactly `version:1`, `command:"enrollment-stored"`, `phoneId` and `credentialEpoch`. The epoch is a canonical decimal string matching the issued credential. This acknowledgment reports the phone's storage action; the host cannot independently attest that action. Wrong/missing acknowledgments yield `phone_credential_delivery_unconfirmed`, close TLS and retain committed trust. No acknowledgment or return value grants physical input.

On success the coordinator returns public trusted-phone metadata to its native caller and leaves the channel available for later authenticated control. Every error closes TLS. A consumed invitation is never restored, including storage or clock failures after admission. Failure to read the native clock before proof consumption cancels the pending window. Reconnection/authentication, bounded listener admission, credential recovery/rotation, session-epoch revocation and native mobile clients for these messages remain pending.

`Rewrite/packages/fixtures/enrollment-v1.json` contains synthetic public message examples and an independently computed verifier. Rust and TypeScript tests consume the same fixture. Real TLS tests cover committed enrollment, wrong versions/proofs/phases, duplicate/unknown fields, wrong channel role, missing/wrong acknowledgment, policy cancellation/replacement during reads and clock failures on either side of proof consumption. Platform-provider/device tests and physical acceptance remain separate gates.
