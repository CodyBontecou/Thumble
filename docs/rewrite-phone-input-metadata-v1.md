# Native phone input configuration metadata

The Swift and Kotlin control clients can query `inputConfiguration()` after
control-v4/v5 authentication and before the first input attempt. This uses the
existing `input-configuration` exchange; it introduces no wire protocol change.

The result contains only `active`, exact decimal-string `generation` and
`revision`, and the recording-only `inputEnabled: false` flag. It contains no
credential, packet key, nonce, session grant or controller geometry. Inactive
configurations preserve their last epochs, including zero before first activation.
Active generations must be positive. Both counters retain the full uint64 range.

The decoder rejects extra/missing fields, wrong connection/command/version,
noncanonical or overflowing counters, nonboolean activity, and physical-output
admission. A rejected or late response closes the native control owner. Queries
before authentication, through control-v3, during another operation, or after an
input attempt cannot enter the transport. Swift cancellation and Android worker
interruption/close retire pending results.

Inspection neither admits input nor consumes the one-shot grant attempt. The
subsequent `bindInput`/`prepareInput` operation fetches configuration again and
requires an exact map epoch match before requesting keys. A configuration change
between inspection and binding therefore produces no input owner or packet. No
query restores prior touches.

Native fixtures cover inactive/full-range uint64 epochs, malformed and foreign replies,
late close/cancellation, busy ownership, and inspect-to-bind changes. Existing real
TLS/native-IPC phone scenarios now query metadata before each grant across TLS,
UDP and UDP-blackhole fallback. These tests use synthetic credentials and a
recording sink. The Expo host pairing/binding UI and continuous authorization/grant
renewal remain separate integration work.
