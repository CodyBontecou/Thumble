# Keep input trust checks durable without rollback-journal directory churn

Every native input/control authorization persists the observed host clock under
the trust fence. Windows runner measurements on SQLite 3.53.2 found DELETE/EXTRA
observations taking 57.4 ms at the median and 99.6 ms at the maximum of 32 samples;
WAL/EXTRA on the same runner took 5.5 ms and 8.1 ms respectively. The input fault
suite exposed deadline failures under the resulting shared-fence contention.
Use WAL with synchronous EXTRA, retaining a durable commit on every observation,
credential change and revocation. The 350 ms input TTL and existing TLS/owner
budgets remain unchanged. [SQLite documents EXTRA as equivalent to FULL in WAL,
with a transaction sync preserving durability](https://sqlite.org/pragma.html#pragma_synchronous).

The sole ledger owner holds no read transaction between calls. Checkpoint after
16 WAL pages and retain at most 256 KiB when a WAL resets; keep page size at most
4 KiB, the existing 256-page database cap, private-file checks, exclusive owner
lock and immediate refusal on lock contention. The reset-size setting is not a
hard limit while an external reader pins a WAL. The product owns only one local
connection and opens no external read handles; continuous-observation tests
check actual journal growth across checkpoints and durable clock/revocation
recovery after reopen. The existing 1 MiB startup checks still reject oversized
sidecars. This local database is unsupported on network filesystems.

WAL adds backup obligations: use SQLite's backup API or quiesce and close the
owner before copying the ledger. Copying only a live main database can omit
committed trust in its WAL. Existing owner-private WAL/SHM validation stays in
place. This change does not cache trust in JavaScript, batch clock durability,
relax revocation, or claim physical power-loss certification. The Windows fault
suite must still pass on this source before the latency repair is established.
