# Native control error before cleanup

The opt-in debug `THUMBLE_REWRITE_INPUT_ERROR_PROBE=1` evidence now records a fixed `phone-control-before-cleanup` event when authenticated input serving returns an error. It runs after serving-local guards drop and before the caller-owned input broker destructor can send release IPC. Release builds omit this boundary and stage tracking.

Native IPC operation 4 is **release**, not progress/status. A release timeout observed before the existing post-cleanup `phone-control` event can therefore describe cleanup following an earlier serving failure. It does not establish the initial cause of a phone disconnection. The new event preserves the serving error separately; the existing post-cleanup evidence remains available.

The event includes only version, broker role, fixed context, fixed stage and an allowlisted static error code. Stages are await-frame, packet, decode-control, grant, renewal, configuration, progress, release, disconnect and status. Unknown errors become `other`. There are no payloads, credentials, identifiers, paths or source data. Existing process event, line and forwarded-report limits remain unchanged. Python and TypeScript validators reject unknown fields, stages, codes and roles.

A stage identifies the operation in progress when serving returned. It is not a latency measurement, an inferred root cause, or a globally ordered event across processes. Explicit release/disconnect commands may perform cleanup within serving before this boundary. Earlier authentication or management failures outside input serving are not covered. The shared bounded event budget can omit a later event after exhaustion.

The synthetic regression uses actual pinned TLS authentication and private native IPC. It grants input, deliberately submits a malformed control request, observes its original fixed error while the broker remains alive, and withholds native release processing beyond the unchanged 250 ms budget. The serving result remains the original error. A test-only bounded channel observes the boundary without enabling process-wide diagnostics. Tests create no physical input device.

This is diagnostic instrumentation, not a stability repair. IPC, input TTL, owner lease, authorization, cleanup and transport deadlines remain unchanged. The historical hosted failure still needs a new instrumented observation to establish its original serving error.
