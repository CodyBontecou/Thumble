# Bounded native iOS runtime launch orchestration

The public50 hosted native runtime job reached `launch` at 168654 ms and then
hit its outer 480-second Actions timeout. The uploaded stage journal had no
launch completion or runtime result. This is an orchestration stall; it does
not establish that native input failed or even whether the app began running.

The diagnostic runner now bounds its owned `simctl launch` command to 60 seconds.
A launch timeout preserves the existing failed result with phase
`runner-launching`. The separate `*-orchestration.json` contains only version 1,
scope `ios-runtime-orchestration`, and boolean `launchTimedOut`/`cleanupFailed`.
It carries no command arguments, paths, error messages, endpoints or credentials.
The report is replaced atomically using a private temporary file.

Shutdown and delete each have an independent 15-second command budget. Delete
is attempted even when shutdown fails. Cleanup cannot replace an existing
primary exception; if the runtime succeeded but cleanup fails, the runner fails
with the fixed `ios_runtime_cleanup_failed` code. Its runtime-result artifact
still reports the runtime observation truthfully; the orchestration report
identifies the separate cleanup failure. Failure to write this sidecar fails a
previously successful runner, and cannot replace an existing primary failure.

The outer 480-second CI limit, 180-second runtime-result wait and all production
TLS/input/IPC/lease deadlines are unchanged. Other setup subprocesses remain
unchanged; this slice does not claim a fully bounded setup pipeline or fix the
underlying simulator stall. Injected regressions cover blocked launch, both
cleanup failures, non-timeout primary errors, successful cleanup, and independent
shutdown/delete attempts. They perform no simulator or physical-device actions.
