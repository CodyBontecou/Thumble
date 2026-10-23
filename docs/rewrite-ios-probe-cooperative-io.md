# Synthetic probe cooperative-executor repair

This changes only the macOS Swift test helper and its regressions. Product TLS,
input TTL, owner IPC, lease and renewal timers are unchanged. The existing
100 ms synthetic watchdog and two-second test assertion remain unchanged.

## Observed failure and isolated reproduction

Public 3659 CI job 120520917272 failed its Swift 169-test step with ten issues.
The synthetic sleep-process deadline took 3.151 seconds; several independent
real pinned-TLS fixtures rejected in the same cluster at approximately 3.34
seconds. The helper used synchronous `FileHandle.read` and `waitUntilExit` in
actor-isolated methods. Those calls occupied Swift cooperative executor workers;
the helper's `Task.detached` watchdog needed that same executor to resume.

The published helper passed the deadline test alone locally in 103 ms. A private
minimal experiment started 20 owned `/bin/sleep 3` children (active processor
count + 2, capped at 32), each with the unchanged 100 ms watchdog. With all readers
blocking concurrently, completion instead took 3.181 seconds and failed the same
two-second assertion. This used sleeping child processes, not CPU-load workers.
After the repair, the same experiment and existing synthetic tests completed
in 177 ms. This isolates an actual test-helper scheduling defect. It does not
prove every historical production disconnection has this cause.

## Repair and cleanup

Each probe has its own serial GCD IO queue. `line` suspends the actor using a
checked continuation while the queue performs the blocking pipe read. Process
exit waiting uses the same queue and suspension. The watchdog can therefore
resume on the cooperative executor even with many outstanding reads.

Read cancellation marks cleanup and terminates the actual owned child, allowing
the real read to reach EOF before its continuation finishes. `stop` terminates
and waits for actual exit; it does not merely cancel a task and abandon an IO
operation. The existing diagnostic first-error latch and cleanup suppression
remain in place. A cancellation regression verifies the blocked reader finishes,
the child exits and cleanup does not become a first failure. All processes here
are synthetic test fixtures; production application code is not changed.

## Verification and limits

The new bounded concurrent-reader regression preserves the two-second assertion.
The full isolated suite passed 171 tests: the existing 169 plus concurrent-reader
and cancellation regressions. It used exact published native probe binaries,
including both 75-second held-input renewal modes (two rotations each), real
pinned TLS, framing, native IPC, packet-zero ordering and coalescing cases.

The local toolchain was Swift 6.3.3; the failed hosted run used Swift 6.2.4. Hosted
rerun confirmation remains open. This is not a production timer increase,
prewarming change, receiver fix, simulator acceptance claim or store clearance.
Raw job/test logs and executable digests remain private evidence.
