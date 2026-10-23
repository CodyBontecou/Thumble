# Strong pending-edit ownership prerequisite

This supplement upgrades the unconnected native commit fence. It does not
register Role12, handle a phone request, alter a revoke/reenroll path, run SQLite
on the input thread, or activate a write. Existing policy paths must not enable
editor admission until the integration traces below pass. Mac/Unix is the only
orphan-probe implementation; other platforms retain the explicit unsupported
gate. No Windows/Linux conformance is claimed.

## Ownership and immutable dispatch

`EditorCoordinator` owns at most one `Arc<PendingEdit>`. That edit retains the
actual `CachedAuthorization` (and therefore the real `Arc<Scope>`), fence,
undroppable ticket, exact writer Arc, native event/authority/phone/credential
context and full nullable label intent. It is not owned by the TLS task. A weak
trust-store scope reference can still upgrade after the phone and its local
attachment disappear. Dropping a ticket, transport handle or scope attachment
never completes dispatched work.

The trusted epoch owner must register one `EditorAttachment` before allowing
edits. `admit` takes the short actual authorization guard and creates the
registered ticket. `begin_dispatch` accepts only that exact registered Arc and
writer, under the same brief guard, and marks the ticket before publishing any
byte. It cannot target a replacement coordinator or a retired writer. A closed
reservation can never dispatch later. The helper does not itself publish IPC.

`actual_owner_completed` is a trusted internal boundary: its caller must have
strictly parsed/correlated a real synchronous owner reply, including receipt or
explicit child error. It checks registered entry, writer, event and exact intent.
It must never be called for parent `not-dispatched`, timeout, partial queue/write,
EOF, kill issuance or an unconfirmed writer exit. Those take
`uncertain_dispatch` / `retire_writer`; the ticket remains pending and its exact
writer is permanently closed. A parsed child storage error can end the owner
call while leaving the journal's durable outcome uncertain.

## Shared orphan lease and acknowledgement proof

The fence's orphan probe acquires SQLite EXCLUSIVE for the startup-bound
existing DB and retired writer. BUSY, IO, identity/schema change and a raced
already-completed ticket do not acknowledge anything. Before clearing pending
or notifying a waiter, the probe publishes a weak reference to the exact newly
created shared `DrainProof`; its local strong guard covers the transfer into
`PendingEdit.proof`. The resource contains only `Mutex<Connection/File>` and
never references a fence, scope, registry or ticket. There is no unchecked
Send/Sync implementation.

A drained waiter must upgrade that exact orphan proof. It cannot turn an expired
weak reference into an ordinary no-lease success: late bare-fence waits fail
closed. `ClosedEditorScope` and its retained edit cover the handoff, and every
`EditAckProof` clones the same lease. Keep that proof alive through the entire
success **or error** acknowledgement send. No boolean pending-empty check can
substitute for it. The coordinator's completed-entry lookup is weak: existing
closed handles/ack senders retain the entry, but there is no coordinator/entry/
fence/proof cycle and no permanent SQLite lease after the last proof drops.

The regression starts two waiters before recovery and captures an additional
retired-scope waiter after publication. A new SQLite writer remains excluded
through success, error and late-error sends; after the last proof drops it can
acquire EXCLUSIVE even while the coordinator is still alive.

## Policy capture API and required integration

`CachedAuthorization.retains_scope` is only pointer identity; it does not grant
authorization. Policy must detach and retire the actual scope under its existing
short trust/mutation locks, then call
`coordinator.close_retired_scope(scopeArc)`. This captures the matching edit and
closes its fence even if the TLS-local attachment has disappeared. A live scope
is rejected. Capture/close uses metadata locks only; it does not do SQLite IO,
condition-variable waits or network IO. Closing an unrelated scope cannot erase
another scope's pending edit.

Release all global policy/store/input locks before calling the returned closed
handle's `wait_for_ack` or `try_orphan_proof`. Capture the policy Result first and
drain before sending either success or error. If the ledger's weak reference
cannot upgrade while this coordinator has an active matching edit, integration
is broken: the actual pending entry is required to retain it strongly. Epoch
replacement must capture the old scope before overwriting the store mapping.
Existing scope management-delivery fencing still applies to the final send;
this commit proof does not authenticate or send a response itself.

Parent loss must close native queued dispatch before an orphan probe. The
owner-lifetime private envelope must still reject queued bytes on a replacement
child, and the parent must never resolve a queued callback against a new owner.
The coordinator only enforces native local identity; it does not prove those
cross-process facts. Admission stays disabled until actual child commit,
parent/orphan exit, partial IPC, two concurrent policy acknowledgements,
revocation/reenrollment success/error and final authorization-send traces prove
those constraints together. No existing read role gains a mutation.
