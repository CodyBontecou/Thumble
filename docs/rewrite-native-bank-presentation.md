# Native accepted-state presentation banks

The default `PhonePresentationRequest` still uses read-only role 10, version 1 and
base-bank notifications. Passing an explicit `PhonePresentationBank` selects
role 11/version 2; there is no implicit upgrade or fallback. Input control remains
version 9 for explicit Mac input and version 6 for recording.

Both SDKs verify the requested bank, theme, authority, installed source pins,
profile, native generation/revision, exact viewport text and materialized map
hash before accepting metadata/icons. Version 2 bridge notifications include
`presentationProtocol: 2` and the full context. A local `kind: bank` notification
has no fabricated presentation revision or freshness. Every metadata, icon and
cosmetic-error callback is preceded by the current bank notification so an early
map/admission/theme render cannot permanently lose bank selection.

Bank selection uses accepted semantic trigger values strictly greater than 0.5.
The value 0.5 can quantize to byte 128 and still selects base. Digital trigger
controls submit semantic 1.0. The new observer runs only after the native packet
channel accepts a sample. The original one-feedback-callback bind overload is
retained, including positional and trailing-lambda callers. A separate explicit
observer overload prevents feedback from silently becoming accepted-state data.
Kotlin observer exceptions are isolated from the accepted input; Swift observers
are nonthrowing. Product observers only compute/coalesce local state in O(1).

Native app hooks enqueue at most one pending bank update, preserve the latest
accepted bank, and reset to base on release/cancellation/connection cleanup.
Management cancellation, socket work and bridge notifications run after the
input callback returns. Foreground, connection lifetime, current bank, theme and
batch epoch fence every asynchronous result. The input owner and physical map
are never changed by presentation results or failures.

The pollers close each sequential management batch, retain a single pending
refresh, and refresh periodically at the existing two-second cadence. A bank or
theme change cancels only management work. Verified PNG caching remains bounded
to 64 icons/512KiB raw bytes; PNG validation and frame limits are unchanged. An
unchanged successful metadata result still refreshes the cosmetic observation
timer; icon arrival and local bank events never prove game freshness.

The shared role 11 fixture covers all four banks in both themes with distinct
verified 32px images. Native tests cover strict context rejection, exact semantic
thresholds, failed submissions, callback compatibility, digital-trigger release,
late management batches, and closure during bank notification. Existing role 10
and constrained-thread 64-control coverage remains in place. Actual visual bank
acceptance is a separate app-level gate; compiling SDKs/apps is not that proof.
