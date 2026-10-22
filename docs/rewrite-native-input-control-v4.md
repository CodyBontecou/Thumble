# Native input control version 4

Control version 4 connects a currently authenticated phone to the independent receiver through private native IPC. Version 2 remains enrollment; version 3 remains metadata-only control. The hello explicitly negotiates 4 before any bearer is sent. Framing, input packet, document and capabilities versions remain 1. The same pinned TLS name/ALPN/certificate policy applies. This protocol implementation postdates public snapshot c8d5d2b (phone enrollment/vault plus the iOS test-host repair); those earlier hosted results do not certify it.

After exact phone credential/epoch/authority validation, the native owner connects to the private receiver endpoint and revalidates trust before returning `authenticated`. Version-4 admission/status/disconnect metadata uses the same fields as version 3 with `inputSessionAvailable:true` and `inputEnabled:false`. Availability means the native broker is supported/reachable; the acknowledged runtime configuration can still be inactive. The receiver is recording-only. No grant is produced merely by authentication.

The following strict control requests add to status/disconnect. Every request includes `version:1` and the exact native TLS `connectionId`:

| Command | Additional request fields | Reply |
| --- | --- | --- |
| `input-configuration` | None | `active`, decimal `generation`/`revision`, connection ID, disabled physical input |
| `input-grant` | Decimal `generation` and `revision` from the acknowledged configuration | `input-granted` native secret grant |
| `input-release` | Lowercase 32-character `sessionId` | `input-released` acknowledgment for that scope |

The grant reply contains version, command, connection ID, exact generation/revision, session ID, key (64 lowercase hex characters), nonce prefix (eight hex characters), lifetime milliseconds, `packetVersion:1`, `packetBytes:108`, decimal `packetLimit:"1048576"`, `transport:"tls"` and `inputEnabled:false`. Only the receiver generates fresh key/session/prefix material. Its opaque native grant checks the exact server-channel binding again before sending this reply over TLS. No grant material enters Bun, a profile/document or a React bridge.

The caller must request the exact active receipt; stale/inactive receipt errors close that phone channel and retire any source owned by it. The native receiver remains authoritative for configuration generation, neutral barriers, source identity, replay, owner lease, input TTL and grant expiry. A new grant is capped at remaining authenticated lifetime, with a 100ms minimum and 60-second maximum. Authentication is rechecked after the bounded local installation RPC before key delivery. Grant lifetime starts at receiver installation; the reliable relay revalidates authentication on each packet and retires the source on terminal control failure. A future direct UDP path needs the same complete expiry/revocation fence; this TLS-only implementation does not certify it.

A phone native sender seals the existing 108-byte packet and sends a TLS input frame. The native owner validates current trust/epoch/channel/lifetime, forwards the sealed bytes through private IPC and waits for receiver admission before reading further input. It does not decrypt or construct a TypeScript sample. A following ordered status response proves earlier native input RPCs completed. Malformed/replayed authenticated input terminates the control channel and its source; the receiver itself does not refresh TTL on rejected packets. Connections are bounded to 128 controls, 65,536 input frames and the existing 60-second admission lifetime. Existing absolute frame deadlines remain in force.

## Retirement and races

All grant installation and native packet RPCs run under the same mutation gate as revocation and enrollment. TLS reads/writes hold no trust/storage lock. A native registry associates each connection/phone with its exact receiver reference and shared native IPC client. Revocation cancels bootstrap/windows/transports, commits the verifier removal and waits for registered native release acknowledgments before returning success. Re-enrollment commits the new epoch and retires that phone's old registered grants before delivering the new credential. Delivery failure preserves committed trust and the consumed invitation, as before.

Retirement retains registration until native acknowledgment. Otherwise disconnect could remove the entry just before revocation examines it and let revocation report success while release was still queued. The deterministic regression pauses receiver processing, starts disconnect cleanup, confirms the registration still exists, then starts revocation and verifies both wait for receiver-owned neutral state. Failed retirements remain discoverable for retry; a broken private client is closed and retried against the current protected endpoint. Errors do not imply a successful output fence.

Source release is scoped and idempotent. An old session release cannot affect a replacement, and cleanup of an old activation cannot release a newer configuration. A matching source release or disconnect retires active input; starting another source requires a fresh acknowledged activation. The existing private service receiver release remains an additional fence in CLI revocation. Independent receiver lease/TTL still bound output if control, storage, IPC or service ownership fails.

## Verification and remaining work

Actual-process Rust tests enroll a synthetic phone over native pinned TLS, negotiate version 4, authenticate, inspect configuration, receive a native grant, seal/relay held input and inspect output from the separate receiver process. They verify acknowledged revocation, old-key retirement during re-enrollment, explicit release, delayed old release, peer drop, stale receipts and generation replacement. Unit coverage verifies canonical request shapes, bounded remaining grant lifetime and the deterministic retirement race. Version-3/native-phone/source/standalone compatibility remains separately checked.

Swift/Kotlin version-4 grant consumers and input-engine binding now exist, alongside the default metadata-only version-3 clients. They validate exact active configuration and native grants, start neutral, retain bounded native output, and terminally retire on lifecycle/clock/transport failure. Their status heartbeat validates receipt/liveness without treating prioritized controls as a sample flush barrier. Actual native phone tests use a separate recording receiver to verify delivered held state, acknowledged native release and fresh neutral reconnection. See [the phone binding contract](rewrite-native-phone-input-v4.md).

UDP, controller UI/app wiring, physical OS output/signing, gameplay, optical sync and all launch acceptance gates remain pending. Hosted validation of this newer source is a separate requirement from historical checks for c8d5d2b.
