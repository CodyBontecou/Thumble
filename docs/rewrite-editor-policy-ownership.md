# Native editor policy acknowledgement ownership

This composes the strong pending-edit prerequisite with the explicitly captured
role-12 bridge. It does not auto-enable a role or claim production phone/game
acceptance, and it does not replace the parent's unknown request timeout.

## Capture and wait

Revocation and re-enrollment detach/retire the real scope and capture
`ClosedEditorScope` under their existing short mutation/store locks, before any
epoch overwrite. Repeated policy operations fall back to the trusted native
phone ID: the coordinator snapshots its strong pending/weak completed entry,
releases its metadata lock, then checks that entry's actual authorization.
Only permanent `phone_authentication_rejected` accepts fallback capture; a live
or poisoned matching entry fails closed. A supplied unrelated retired scope does
not hide a matching phone's old edit.

Draining occurs after all global/input/coordinator/store locks are released.
`retired_writer_if_any` only inspects permanent retirement; credential revocation
never retires a healthy writer to manufacture an orphan proof. Pending healthy
work waits for its actual correlated owner result. Unsupported, unsafe, BUSY,
or unavailable orphan recovery yields no definitive policy acknowledgement.

`CapturedPolicy::drain` obtains the shared typed proof before invoking the real
bridge's orphan reaper outside all metadata locks. The bridge then retains only
a bounded immutable envelope/request tombstone. The proof remains in the guard
while the bridge drops its delivery Arc; an empty pending registry is never used
as orphan proof. Failed reaping withholds the ACK and leaves the bridge's entry
available for retry. Exact valid old results can be ignored later; different
outer/nested context and invalid result schemas still fail closed.

## Actual output ownership

The native stdin dispatcher captures revoke policy synchronously but never waits
for its drain. One bounded deferred worker handles draining, with up to four reserved jobs;
a full queue withholds further revoke ACKs while the main loop continues consuming owner
completion events and other requests. A full/failed output queue closes the
native owner rather than reporting a definitive outcome. The parent's existing
request timeout continues to mean unknown.

The common bounded writer queue carries `GuardedLine { line, guard }`. Existing
bridge String channels feed it through one bounded forwarder. The actual writer
owns `AckGuard` across all writes and `flush`, including an IO error. The guard
contains the real scope plus `EditAckProof`, cannot serialize, and is released
only after the actual output operation returns. Both success and policy-mutation
error responses use the same path.

Re-enrollment is already a TLS worker operation. It captures before durable epoch
replacement, drains before examining the mutation Result, and retains one guard
through `enrolled`, the phone's stored acknowledgement, `enrollment-complete`,
and every error unwind. No global lock covers either send or the wait.

## Evidence and limits

With Cargo 1.88.0 and two build jobs, the composed library passes 187 tests,
including eight policy tests. They cover healthy-writer completion while a
policy worker waits; orphan BUSY; repeated same-phone proofs; real bridge reaping
without a permanent SQLite lease; actual pinned TLS re-enrollment success and
wrong-stored-ack error unwind; and blocked write/flush success/error delivery.
The blocked sink uses the same `GuardedLine::write` implementation as stdout,
observes SQLite exclusion during every write and blocked flush, and checks that
the database becomes writable after the final guard while the coordinator lives.

A separate actual-process test starts the native executable, enrolls/authenticates
an in-process pinned TLS client, sends a pending edit, then sends four same-phone revokes, a fifth
busy revoke, and status through stdin. Status returns before the parent completion
is supplied; the original revoke succeeds after that real completion. Four concurrent same-phone revokes receive ACKs after completion; a fifth busy
revoke receives no definitive ACK. EOF exits the native process successfully.
The real TLS check covers waiting for the stored acknowledgement and send/error
unwind ownership; it does not simulate an OS-blocked TLS write. No physical phone,
game, live input, or externally installed desktop GUI is used.

Parent orchestration must still close the exact captured Bun owner's admission,
disconnect it, and confirm its exit before waiting on native-host teardown. These
native tests do not establish that cross-process owner shutdown ordering. Role
activation and release acceptance remain gated on the root composition tests.

The final full native suite passes 219 tests (187 library and 32 integration),
using Cargo 1.88.0, two build jobs and two test threads. The proof-free legacy
direct Host API remains available only when no editor owner was captured;
captured editor policy must use guarded delivery. Bridge coordinator lookup is
fallible on policy paths so a poisoned state cannot become an absent-edit proof.
