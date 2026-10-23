# Native owner work notification

Native socket workers enqueue bounded operations on a separate queue from owner stdin. Previously, the owner drained native work then waited up to 10 ms exclusively for stdin; native enqueue could not interrupt that wait. Physical tracing measured approximately 11.5 ms per native request, with negligible authorization-lock wait. This change removes that avoidable wait; it does not replace bounded phone TLS flow control.

A coalesced boolean and condition variable wake the owner after successful native enqueue, disconnect-release enqueue, stdin enqueue, or stdin EOF. The flag is protected while checking/waiting, so notifications before a wait are retained. Its mutex never covers output, sockets, queue operations, or response waits. Poison is a fixed fail-closed owner error. Four drained operations schedule another iteration so a coalesced notification cannot strand a larger batch.

Each iteration still checks the authoritative clock, ticks expiry, drains at most four native operations, and handles at most one stdin frame. The fallback wait remains 10 ms; native operation waits remain 250 ms, input TTL 350 ms and owner lease 750 ms. Notifications do not renew any lease. Existing Server::bind callers retain their polling interface; the production owner uses bind_with_wake.

Tests park a fake-output owner for a TEST-only one-second wait and send a real authenticated native status request. Successful completion uses the existing 250 ms operation deadline, proving native enqueue interrupts the wait. Burst, pre-wait notification, poison and unchanged owner expiry are covered. No physical device is constructed. Actual physical latency and reconnect stability require fresh device evidence after deployment.
