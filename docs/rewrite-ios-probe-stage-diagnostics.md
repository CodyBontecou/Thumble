# Bounded iOS CI probe diagnostics

The C4 native job passed all 152 Swift tests, including both 75-second renewal
witnesses, and its real-service catalog and five-mode input witnesses. Both
saved-map transport cases subsequently reported `probe_closed`. That result
alone cannot distinguish the probe exiting early from its existing 30-second
owned-process watchdog. The original private runner logs were not retained in
the uploaded artifact. No native cause is established by this diagnostic change.

The test-only `NativeProbeProcess` now supports the explicit
`THUMBLE_REWRITE_PROBE_STAGE_DIAGNOSTICS=1` environment flag. It emits fixed
startup and single-byte command stages with a process-local numeric instance.
It marks intentional cleanup before terminating the owned process, so cleanup EOF or exit cannot create a new first failure. It retains one first process outcome before cleanup: early EOF, owned watchdog,
startup failure, line bound, write failure or nonzero process exit. Ordinary
stages are capped at 64 per instance. No executable path, argv, reply value,
credential or source is logged by this mechanism. A watchdog outcome means the
existing watchdog attempted termination of a running owned process; it does not
identify the reason that process stopped responding. The original exceptions,
process calls, read bounds and watchdog durations are unchanged.

`check_real_service_swift_witness.py` optionally projects the existing private
runner log into a new `mobile-real-service-swift-*-diagnostics.json` artifact.
It reads at most 2 MiB, retains at most 64 fixed stages and 16 first process
outcomes, and separately retains the first strictly decoded native input error,
first allowlisted probe error and first control outcome after cleanup. These
records are observations, not causal ordering across processes. Native control
outcomes remain explicitly labeled as post-cleanup. Existing witness/event-stream
admission remains unchanged; diagnostic write failure does not change admission.
Reports are atomically replaced with mode 0600 and capped at 16 KiB. Expanded
Swift failures, raw logs and raw event streams remain private because they can
contain request values. The existing CI `mobile-*.json` artifact allowlist already
covers the sanitized report; no raw stream is added to uploads.

A separate preflight diagnostic prevents an empty iOS bank artifact when the
existing 15-second simulator inventory call fails before any fixture starts.
It prints only failed status, the fixed simulator-inventory stage and a fixed
reason, then rethrows the original failure. Successful inventory emits nothing.
This does not start a simulator, retry a command or relax ownership validation.

Verification uses six synthetic Swift process tests, eight hostile/bounded
witness projection tests and eight bank-runner parser/preflight tests. A real
synthetic watchdog output was also passed through the Python projector. None of
these checks runs a phone, simulator, capture provider or physical input factory.
The observed C4 simulator launch timeout and earlier host input expiry remain
open issues; this source does not claim to repair either one.
