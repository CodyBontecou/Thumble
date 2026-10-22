# Windows Bun private-pipe diagnostic

This independent diagnostic compares fixed synthetic stdio peers under Bun 1.4.3 and Node 26.8.1. It imports no service/NativePipe code and changes no product deadlines, transports or cleanup. It neither reads real configuration nor accesses a phone, game, device, credentials or OS input. The ordinary malformed catalog-child test remains the actual NativePipe codec witness; correlate its exact source head with this smaller transport matrix.

Run with the pinned Node executable, an explicit pinned Bun executable and a **new** evidence directory:

```sh
THUMBLE_DIAG_BUN=/absolute/path/to/bun node diagnostics/rewrite-stdio/run-matrix.mjs /new/private/evidence
```

The separate Windows 2022 workflow checks out `github.sha`, uses read-only repository permission and no persisted checkout credentials, selects Bun 1.4.3/Node 26.8.1, then uploads only bounded JSON evidence. It is diagnostic, not a substitute product gate.

Each cell runs once; failures are not retried. The driver captures all independent cells before returning failure if any cell fails:

| Parent context                                     | Parent transport                           | Child runtime/write                                                                   |
| -------------------------------------------------- | ------------------------------------------ | ------------------------------------------------------------------------------------- |
| Bun script and actual `bun:test` rejection matcher | `node:child_process.spawn` and `Bun.spawn` | Bun `process.stdout.write(callback)` and `await Bun.write(Bun.stdout, ...)` (8 cells) |
| Bun script and actual `bun:test` rejection matcher | Both parent transports                     | Node `process.stdout.write(callback)` (4 cells)                                       |
| Node script                                        | `node:child_process.spawn`                 | Node `process.stdout.write(callback)` (1 control)                                     |

All cells use the same peer: a ready envelope, two exact requests/replies with fixed 36-character synthetic identities, then wait for **stdin EOF**. The second reply is the original malformed typed catalog shape and is exactly 132 bytes including newline. The parent first validates its exact raw envelope, then rejects it with the fixed `configuration_response_invalid` category. The Bun-test cells use the actual `expect(promise).rejects.toThrow` matcher. The request write starts **before** calling that matcher, matching NativePipe's ordering; Bun's matcher may synchronously pump until settlement, so writing only afterward would test an unsent request instead of transport.

Ready has a 2-second diagnostic observation budget; each reply has 4 seconds. Cleanup sends EOF only after success/failure observation, waits 1 second, requests kill if necessary, then waits at most 1 further second. The peer has an independent 14-second watchdog. The driver enforces a 16-second outer cell timeout and a 155-second new-cell budget; these are diagnostic budgets, not product timeout changes. At most one peer is intentionally active per cell, with bounded watchdog termination even after an outer failure.

The `node:spawn` reader uses the same flowing `.stdout.on('data')` boundary as NativePipe. The `Bun.spawn` reader uses native readable streams. Both await process/pipe closure before completing cleanup; EOF confirmation is required for success. A reply observed only after EOF can never become a passing result. Evidence distinguishes child write callback/resolution, parent chunk/line arrival, flowing/readable byte state, typed rejection, EOF, process exit, pipe closure and forced cleanup. No buffering meaning is inferred from a successful write callback.

Each cell emits at most 96 fixed phase/numeric records, at most 8 KiB stdout and 4 KiB buffered diagnostic stderr, and a JSON result capped at 32 KiB. Artifacts contain no raw request/reply text, request identities, PID, executable paths, arbitrary errors or environment dumps. The summary records the checked-out source head when provided by Actions and exact tool versions. A missing/overflowed result is itself a fixed failure category. Early EOF/exit, post-EOF data and successful live replies are separate observations.

Local validation on macOS checks harness construction and matrix behavior only. It does not explain the measured Windows case where the malformed reply became visible only after disconnect. One early construction run intentionally exposed and corrected write-after-matcher ordering; its failure was not product evidence. A later local run observed a Node-child cleanup failure after both replies arrived; added fixed EOF/exit phases preserve that distinction. Neither green local controls nor intermittent green Windows jobs establish a product fix. Product transport changes require a discriminating exact-head Windows result first.
