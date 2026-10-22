# Native authorization clock reservations (trust schema v2)

Native input authorization must reject clock rollback and retired credentials without performing a durable SQLite write per packet. The original per-observation durable trust path could hold the shared control fence longer than the independent 350 ms input expiry on Windows. The replacement reserves a bounded native-clock interval durably and checks packets within that committed interval using a short in-memory epoch fence. The receiver still records reports; this change does not enable physical output or certify gameplay.

## Clock and persistence

The native owner reads wall-clock milliseconds itself; a phone cannot supply authorization time. Trust schema v2 adds `reserved_until` alongside `last_time`. The v1-to-v2 change is transactional and preserves the host pin, phone identities, verifier/credential epoch, active state and observed floor. It does not reset trust. An invalid schema or clock relation fails closed.

A committed reservation reaches at most 1,000 ms beyond its native observation. The live monotonic deadline is anchored before the corresponding storage work: write latency consumes the budget rather than extending it. In-memory accepted time never decreases. Packet authorization checks the global observed floor, committed ceiling, monotonic deadline, immutable credential/connection/grant expiry and current epoch guard. An observation beyond the ceiling is rejected; no peer value can extend the ceiling.

Exactly one owned worker checks reservation demand every 20 ms and renews when no more than 500 ms remains. Demand exists only while cached epoch scopes exist. The worker may block on existing storage; it does not create queued per-packet work or detach a writer from the owner. A failed renewal or sampled exhausted monotonic reservation latches authorization failure. A late successful write cannot rearm that failed owner. Restart the host after resolving storage/clock failures; repeated phone packets or reconnect attempts cannot clear the failure.

On restart the previously committed ceiling becomes the antirollback floor. Opening the trust store waits at most the normal-clock remainder of 1,000 ms. A larger backward wall-clock change leaves inspection/revocation usable while authentication remains unavailable until native time catches up. This bounded admission delay is a deliberate operational tradeoff for preserving rollback rejection across a crash without per-packet fsync.

## Epoch and forwarding fences

TLS packets, read-only authenticated input status and encrypted UDP packets use the cached epoch fence and clock reservation. They do not acquire the durable trust-store or global policy-mutation mutex. The epoch guard stays held through native forwarding so invalidation waits for already admitted work and prevents later old-epoch work.

Enrollment, grant delivery/renewal and durable trust mutations still check persistent trust. Revoke/re-enroll serialize policy mutation, invalidate the old epoch, retire/neutralize its native sources, and only then commit/acknowledge the durable operation. A durable failure can leave the live old scope invalidated; it cannot silently reactivate input. Already delivered stale credentials/grants do not regain authority.

Lock order matters: packet forwarding holds its epoch guard before using the broker/source owner; durable mutation uses policy mutation then trust owner and invalidation; reservation work uses trust owner then the short clock lock. Packet work never reaches back into durable storage from an epoch guard. TLS network delivery is outside these fences.

The independent 750 ms service-owner lease and 350 ms input TTL remain unchanged. Reservation failure does not extend either timer or keep a held report alive. Loss of valid samples leads to normal independent neutralization. Quiet or disconnected cached scopes do not prove live input.

## Review and verification

Review `authorization_clock.rs`, `cached_authorization.rs`, `trust_reservation.rs`, `phone_trust.rs`, `authenticated_control.rs`, `input_datagram.rs` and broker/revocation integration under `Rewrite/native/receiver/src/`. Tests cover v1 migration, bounded restart/rollback behavior, failed and delayed storage, terminal exhaustion, revoked/re-enrolled epochs, in-flight forwarding fences and actual TLS-to-independent-receiver behavior while storage is contended. Source-specific results belong in the PR; local passes alone do not establish the Windows regression is resolved.

A sustained storage stall can still stop authorization when its bounded reservation is exhausted. This is intentional fail-closed behavior. Physical output, driver/signing and gameplay acceptance remain separate launch gates.
