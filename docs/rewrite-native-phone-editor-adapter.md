# Native phone editor adapter

The native adapter binds one existing configuration database in the pairing
host's trusted startup runtime directory to the original canonical owner UUID.
The private enable command has exactly `command: phone-editor-enable` and
`ownerLifetimeId`; its result is exactly `kind: phone-editor-enabled`. A phone
cannot supply either a database path or owner lifetime. Repeated enable cannot
replace a captured writer. Unix service startup enables the captured writer only after composing the
policy fence and parent-owner-exit bridge. Windows remains gated on its
orphan-drain provider.

Control version 12 requires the management role. Both hello and authenticated
admission report `inputEnabled: false` and `inputSessionAvailable: false`.
Authentication uses the existing pinned native TLS and credential store. Each
connection carries one strict editor request, bounded to 2 KiB, and one reply,
bounded to 16 KiB. Earlier role routing remains separate.

The adapter constructs owner envelopes from authenticated native phone, epoch,
authority and the original typed request. One canonical positive uint64 counter
orders reads and writes through one bounded parent queue. Only one read and one
dispatched write can be retained. Admission and dispatch registration occur
before publishing any event bytes. A queue publication failure, parent EOF or `not-dispatched` result retires
the exact writer and retains the ticket. The two-second phone response deadline
returns admitted while retaining a healthy writer and the dispatched ticket;
it is an uncertain disposition, never cancellation or a receipt. The captured
parent owner has a separate total 30-second health budget including its bounded
wait behind already-started configuration work.

A correlated actual `owner-response` must contain the complete original nested
envelope and a strict committed receipt or conflict. An allowlisted actual
`owner-error` ends the owner call without claiming a noncommit. Only these
actual results complete the registered write fence. A read cannot complete it.
Late actual write replies still correlate after the TLS caller has left. An
orphan proof reaper can replace the retained call with a bounded immutable
request/envelope tombstone. Even an ignored late tombstone reply must pass its
complete nested context and result validation; it retains no pending-edit Arc
or database lease.

Native-library validation uses Rust 1.88.0 with two build jobs. Focused tests exercise real pinned TLS
and native credential authentication for role12 committed/read receipts and
phone-context rejection. Adapter tests cover a read while a write is held,
queue backpressure, timeout, `not-dispatched`, late actual error, mismatched
credential context, recursive duplicate fields, and strict tombstone parsing.
These tests use a synthetic trusted parent/owner reply at the local event
boundary; they do not claim an actual Bun-owner SQLite commit or the complete
revoke/reenroll/stdout acknowledgement proof. The policy composition preserves typed drain proof through actual success and
error writes and flushes. The service confirms captured-owner exit on transport
loss. See `rewrite-editor-cross-layer-witness.md` for the separate actual Bun,
SQLite and native Swift SDK witness.
