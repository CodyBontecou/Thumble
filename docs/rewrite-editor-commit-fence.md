# Editor commit-lifetime prerequisite

This is an internal, unconnected primitive. No phone write role, editor command,
trust change, input policy, receiver deadline, source write or revocation handler
is enabled by this slice. The module is deliberately permitted to be unused
until its separately reviewed protocol integration exists.

`WriterLifetime` binds a trusted configuration-owner startup identity. It allows
one pending editor operation across its scopes. `CommitFence` closes one epoch's
admissions and tracks reserved/dispatched tickets. Closing cancels only a
reservation that has not dispatched. Dispatch must be marked before any event or
pipe bytes can be queued. A ticket has no completing destructor: cancellation,
EOF, a dropped value, a rejected promise and a timeout are not completion proof.

Only a strictly correlated actual owner response may call
`definitive_completion`. Match the owner lifetime, native authority, event,
phone/credential epoch, operation ID and exact intent in the later bridge.
`wait_drained` returning Pending is not a result that permits either success or
error acknowledgment. Its timeout leaves the ticket intact. Its condition wait
holds none of the writer, input, trust or policy locks.

For orphan recovery, first close scope admission and permanently retire the
owner dispatch lifetime. `BoundDatabase::existing` captures the existing private
SQLite file identity at trusted startup without creating it. Recovery requires
that same owner and scope, rejects symlinks/aliased ancestors, hardlinks, unsafe
permissions/ownership, changed device/inode and invalid schema, and requests a
zero-wait exclusive transaction. BUSY and every I/O failure leave work pending.
SQLite's own `SQLITE_FCNTL_HAS_MOVED` check also rejects an opened substitute even
if the original path has been restored before the path identity recheck.

A successful `OrphanDrain` retains the native exclusive transaction and opened
file. Keep that guard alive through the orphan-drain acknowledgment. It holds no
input/trust/policy mutex. No logical source SQL is written by this probe; SQLite
may perform its normal hot-journal recovery after a dead writer. The actual Bun
repository uses an exclusive process-lifetime lease, and its closed instance
rejects every future call. Existing private-authority filesystem integrity is
still required; these checks do not authorize a phone-selected path.

The future bridge must prohibit old queued work from starting or being forwarded
to a replacement owner after retirement, including after the database guard is
dropped. An old event must never be rebound to a newly started owner. The local
primitive rejects closed/retired dispatch and foreign tickets/lifetimes; it does
not itself cancel bytes already queued in another process. Revoke/reenroll must
mark the old epoch dead, release global input/trust/policy locks, then drain
before any acknowledgment. Parent death cannot substitute for actual writer
completion. These end-to-end traces remain integration gates.

Private controlled Mac conformance against the actual Bun 1.4.3 repository
(SQLite 3.51.0) and pinned rusqlite 0.40.2 (SQLite 3.53.2) established: idle-owner
exclusion; normal EOF release; an orphan committing after parent SIGKILL while
the probe remains BUSY; actual-writer SIGKILL rollback; native-held exclusion of
a new Bun owner; and fixed path/identity rejection. This supports the primitive's
Mac prerequisite, without proving a complete phone edit/revocation protocol.
Unix code is available for that next review; Windows is explicitly unsupported
and Linux conformance is unverified. No larger input or IPC budgets are used.
