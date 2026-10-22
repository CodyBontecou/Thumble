# Native input control version 6

Version 6 adds bounded authorization renewal and staged input-key rotation to the
[version-5 UDP and TLS protocol](rewrite-native-input-control-v5.md). The phone
must explicitly negotiate `controlVersion:6`; the host accepts it only when the
native input listener supports UDP plus TLS. Versions 2–5 keep their prior
behavior. Recording remains the only output backend.

## Request and receipt

The strict renewal request contains exactly these fields:

```json
{
  "version": 1,
  "command": "input-renew",
  "connectionId": "<exact native TLS connection>",
  "sessionId": "<current input session>",
  "generation": "<canonical decimal activation generation>",
  "revision": "<canonical decimal configuration revision>"
}
```

A renewal requires the current authenticated connection to remain live, with at
most 30 seconds left in its authorization. The host checks the exact socket,
host pin, credential epoch, durable trust, credential expiry and nondecreasing
wall clock under the trust mutation fence. It sets the next authorization expiry
to the smaller of the persistent credential expiry and request time plus 60
seconds. Renewal never extends the credential itself or transfers authorization
to another socket. An early, expired, malformed or unauthorized request closes
control and releases native input, as do other reliable protocol failures.

The receiver must still own the exact current session, generation and revision,
and must have accepted an initial packet. The old grant must remain within its
continuous and wall-clock deadlines. A pending renewal cannot be renewed again.
The independent receiver generates a fresh session, AES key and nonce prefix
through its [private rotation seam](rewrite-native-input-ipc-v1.md).

The reply contains all version-5 grant fields, with `command:"input-renewed"`,
plus exactly `replacesSessionId` (the current session identifier) and numeric
`authorizationExpiresAt` (the next host wall-clock deadline). The generation,
revision and TLS connection are unchanged. The new `lifetimeMs` is bounded by
the remaining renewed authorization and 60 seconds. The host rechecks trust and
authorization after native IPC, before delivering the reply. These fields and
keys remain inside native networking; they are never React properties or CLI/MCP
results.

## Reliable commitment and retirement

Preparing a renewal leaves the old stream and held state intact. The pending
key is not routable over UDP. Its first accepted packet must be sequence zero,
carry the full current controller state, and arrive over the existing reliable
TLS connection within two seconds and before the old source expires. Native
admission commits the successor before acknowledged progress changes. This
continues the existing interaction without a neutral pulse; it does not replay
touches, renew configuration ownership or bypass input TTL.

Native TLS writers protect a packet with the public THI1 header and sequence
zero in the same bounded FIFO as control frames. It clears the replaceable old
input slot and cannot be coalesced away by later samples or overtaken by a
following status request. The queue holds at most eight ordered frames plus one
latest full-state snapshot and one in-flight write. Overflow is terminal. This
header classification is transport scheduling only; the receiver still
authenticates the complete packet. A real TLS backpressure test reproduces loss
of packet zero with the prior writer and verifies the protected ordering; the
Android worker has the matching stalled-writer case.

The phone must prepare a fresh native sender, preserve the ongoing native touch
interaction, submit current full state at sequence zero over TLS, and reset
session-scoped progress to the new session. It must fence old UDP work and old
progress replies. The host routes UDP to the successor only after reliable
commitment; old-session packets then have no route. A status request for a
pending session can report no accepted sequence, but does not commit or refresh
input. Staging or commitment never restores a terminally expired interaction.

One revocation-registry entry continuously covers both current and pending
native references. Revocation, listener shutdown, reliable disconnect and error
cleanup release both references, including when native packet admission may
have committed but its acknowledgment was lost. Release success requires native
acknowledgment. Stale old-session release cannot affect a committed successor;
cancelling a pending session releases only that pending source. The independent
receiver retains its own owner lease, input TTL and continuous expiry checks.

## Work bounds

Version 6 retains the 65,536 receiver-acknowledged-packet limit per grant, across
both transports, and the cryptographic packet counter limit. Each fresh grant
starts a fresh counter. TLS input frames are additionally bounded to 65,536 and
controls to 1,024 per fixed 60-second continuous-time connection window. Those
work counters reset only when that window elapses, independent of wall-clock
changes and renewal requests. Older protocol revisions retain lifetime work
bounds. At most one current and one pending source exist per registry entry;
renewal history is not retained.

## Verification and remaining integration

The host tests use actual pinned TLS, SQLite trust, private receiver IPC and
recorded native reports, with a controlled wall clock. Two renewals cross the
initial authorization deadline while preserving a held button and trigger,
reject pending UDP commitment, switch progress to the new session and reject old
UDP routes. Additional cases cover revocation before and after commitment,
legacy version rejection, early and expired requests, epoch replacement,
credential expiry, clock rollback and ambiguous JSON fields. Negotiation tests
exercise versions 4–6 and reject unsupported versions/host capability.

Swift and Kotlin now have native-only strict renewal decoders. They require an
exact predecessor, unchanged TLS/configuration/UDP scope, and a still-live old
authorization bounded by credential expiry. Ordinary grant decoders reject the
renewal shape. Their encrypted-channel continuation seam requires a live,
non-reentrant source and distinct key/session material; it preserves the next
engine sample sequence while starting a fresh cryptographic counter. Native
engine tests retain an actual held touch through two channel handoffs and reject
stale channels, reused keys/sessions, closed sources and failed first delivery.

These controlled-clock host and native engine tests do not establish a
real-duration phone session. Automatic renewal scheduling, transport/progress
handoff, app opt-in and a headless hold across multiple real 60-second deadlines
remain required before claiming continuous phone operation. Physical gameplay, latency, signing and
optical live-sync acceptance remain separate open gates.
