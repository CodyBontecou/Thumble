# Native pairing invitation intake

Both phone libraries expose `EnrollmentInvitation.decode` for the existing flat
seven-field CLI offer: `host`, `port`, `certificatePin`, `authorityInstanceId`,
`windowId`, `secret`, and `expiresAt`. Decode the offer itself, not the enclosing
CLI result or pairing reply. The input remains native bootstrap material; it is
not a React property, configuration document, credential-vault record or status
response. Native descriptions/reflection redact its proof.

The decoder accepts at most 4096 UTF-8 bytes and exactly those seven fields. It
reuses the native strict JSON reader, rejecting duplicate decoded keys, malformed
Unicode/UTF-8, nested values, arrays, trailing material, null/boolean coercions,
and non-integer numeric spellings. Hosts use the existing bounded ASCII CLI host
alphabet and exclude unspecified bind addresses. Ports are 1...65535; expiration
is a positive integer no larger than JavaScript's exact integer limit. Pins and
proofs are lowercase 32-byte hex; authority/window identities use the existing
bounded grammar. Parse failures produce the native enrollment rejection type.

Decoding does not extend or consume the invitation, save credentials, open a
socket, or establish trust. Enrollment still checks current time/expiry before
connection and before proof delivery, validates pinned TLS/host negotiation,
stores credentials natively, and requires the host's completion. The typed native
constructor remains available for native callers; untrusted text uses the decoder.

One synthetic public fixture supplies three valid offers (IPv4, hostname, IPv6)
and malformed cases to both native test suites. TypeScript verifies the valid
offers through the existing host reply decoder and canonical serializer. Native
enrollment tests now obtain their bootstrap object through this intake path,
then exercise the existing handshake/storage/cancellation scenarios. No new wire
protocol or invitation-secret bridge is introduced. Manual-entry/QR UI and the
phone's full pairing-to-controller flow remain pending.
