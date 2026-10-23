# Configuration process owner v1

The headless service forwards configuration commands to a dedicated Bun child. That child holds the SQLite writer lease, runs application operations, parses saved source and performs synchronous filesystem asset preparation/recovery. The service IO loop continues to renew the independent native receiver while that work runs. CLI and stdio MCP still use the same authenticated service endpoint and application semantics.

The child is the same standalone CLI executable launched through internal `__configuration run --runtime-dir ROOT --receiver HELPER` mode. Development uses the Bun executable plus the source entrypoint. There is no extra script, installed Bun/Node runtime, worker file or desktop GUI dependency in the compiled package. This internal mode is a private same-user stdio endpoint; it creates no network listener or separate editable authority.

## Private transport

The existing bounded owner pipe supplies process identity admission, request correlation, at most 16 pending requests, 64 KiB frames, a three-second startup deadline and a two-second request deadline. Native receiver/pairing deadlines are unchanged. The ready frame is `{version: 1, ready: "configuration", pid}`; replies use the existing `{version, requestId, ok, result/error}` envelope. Both sides validate strict JSON/fields and typed configuration commands/replies. An invalid typed result disconnects the child rather than leaving a poisoned pipe available. Only catalog list and scoped profile rename are admitted. Raw source commits, asset bytes and caller-selected payload fingerprints are excluded.

The owner executes requests serially, preserving compare-and-swap and durable operation receipt replay. Output backpressure pauses parsing as well as stdin reads; drain resumes buffered complete requests before accepting more. Buffered input is capped at sixteen maximum frames. Malformed framing, invalid envelopes, incomplete EOF and output failure terminate admission. An invalid scoped operation returns a bounded static code without reflecting source or error details. Ordinary errors do not bypass the application validator.

EOF closes SQLite. Shutdown disconnects configuration, receiver and pairing owners and confirms all three child exits before removing the service endpoint. Configuration owner death stops the service and releases input through the existing stop/expiry path; it does not silently create a second writer. Startup failure closes already-created children and waits for their locks. A timed-out mutation can have an unknown outcome: callers retry the original operation ID and payload to recover its durable receipt.

## Evidence and remaining work

Process tests cover a real separate PID and exclusive SQLite lease, concurrent CAS conflict, receipt replay after child restart, abrupt child death, raw-commit/framing rejection, and queued large catalog replies under backpressure through EOF. A Unix test suspends the configuration process for longer than the unchanged 750 ms receiver owner lease while the parent renews and publishes recording input; the configuration request remains pending until the child resumes. Windows runs the real owner/SQLite/lifecycle and compiled package paths; the Unix suspension probe is explicitly skipped because SIGSTOP/SIGCONT are unavailable there.

This process boundary is a prerequisite for rich imports, not their implementation. Bulk import still needs validated external asset references, application operations and bounded progress/deadline handling. Do not send binary imports through the small catalog frame or extend input leases to accommodate slow storage. The current admission deadlines intentionally fail closed if startup recovery or a catalog request exceeds their bounds.
