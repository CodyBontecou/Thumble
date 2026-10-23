# Native IPC handshake deadline diagnostic

This opt-in debug diagnostic narrows the original native IPC handshake failure before input admission. It changes no deadline, retry, protocol frame, worker/queue limit, authorization, or cleanup behavior. The original operation budget remains 250 ms and receiver frame wait remains 2 s. Release configurations omit these diagnostics and test scheduling hooks.

## Evidence and limits

Hosted run 39990668209, job 120541283829, artifact 12519307628 failed in admission with zero publications. Its first retained error is broker `native-read` / `would-block` / OS 35, followed by phone-control `native_input_timeout` with op 0, then receiver read-options OS 22 and read-failure exit. There is no native-client opcode terminal. The source path therefore points to the HMAC server-proof read in `Client::connect`, before an input opcode is sent. This remains an inference from the old diagnostic, not a captured handshake phase.

A local actual-socket positive control withholding the proof reproduces the first error signature and original 250 ms deadline. A macOS socket probe shows OS 22 can follow local socket shutdown; it is not evidence that invalid timeout rounding initiated the hosted failure. Tiny positive socket timeout values were accepted. These controls do not reproduce the spontaneous hosted scheduling cause.

The receiver handshake runs on its bounded socket workers before the input-owner queue, wake notification, safety-loop drain, output recording, or policy/store locks. The work receiver mutex drops before handling the socket. Accept uses a nonblocking listener and bounded try-send. Endpoint publication precedes worker and accept readiness, so cold-start scheduling is plausible. The synthetic runtime starts its native fixture on `/begin`, after simulator launch; the long simulator boot/install phases do not directly age an already running native fixture.

Ranked hypotheses for the next failure:

1. Accept-thread startup or scheduling stall: a large `acceptGapMs` around the failed first connection, with short worker queue/proof phases.
2. Broker scheduling or loopback delivery delay: client `proof-read` expires despite short receiver phases. These metrics alone cannot distinguish broker descheduling from kernel delivery.
3. Worker head-of-line delay: large `queueMs`. Four sockets can occupy all workers, but the fresh synthetic probe is expected to have one client, making this less likely without evidence of extra connections.

No root-cause repair is claimed. A readiness barrier should only be considered after the next capture attributes the delay to initial readiness; the deadline must not be widened to conceal it.

## Captured fields

With `THUMBLE_REWRITE_INPUT_ERROR_PROBE=1` in a debug build, the existing `native_input_error` stream additionally accepts these exact schemas:

- Broker `native-connect`: fixed `stage` (`tcp-connect`, `challenge-send`, `proof-read`, `proof-validate`), total `elapsedMs` since TCP setup began, and allowlisted `code`. Emitted only when connection fails, before the caller's control cleanup.
- Receiver `native-handshake`: fixed `stage` (`accepted`, `challenge-read`, `proof-send`, `complete`), `acceptGapMs` since the preceding accept iteration (or endpoint publication on first iteration), `queueMs` from accept to worker pickup, `readMs` from pickup through socket setup/challenge read, and `proofMs` through validation/HMAC/proof send. The timing snapshot is retained until the connection exits abnormally, so `complete` can reveal proof sent after the broker's deadline. This is a local send completion, not peer acknowledgment.

Durations are monotonic relative milliseconds clamped to 0–60000. Submillisecond values round down. No endpoint, PID, connection identifier, path, challenge, proof, key, packet, credential, or free-form error text is emitted. The emitter retains its existing first-16 / 256-byte event budget; the collector retains first-32 / 8-KiB limits and rejects extra keys, unknown stages, noncanonical integers, and out-of-range values. Concurrent connections are not uniquely correlated across processes, so timing proximity alone does not prove identity or cross-process event ordering.

The existing public mobile workflow already calls `run_mobile_app_probe.py` with `--input-error-report`, which enables this flag and collects the sanitized JSON. No workflow edit is needed. Raw runtime stdout/stderr remains private; upload the existing allowlisted error report.

## Verification

Three actual-socket tests keep original deadlines and exercise phase ordering:

- Withheld proof: reports broker `proof-read` timeout, and peer observes EOF with no subsequent opcode or reconnection.
- Gated accept: broker reaches its deadline while accept is paused; receiver later reports high accept gap, low queue time, and completed proof. A subsequent connection succeeds.
- Occupied workers: four actual authenticated idle sockets occupy all workers; fifth connection expires while queued, then reports high queue time and completed late proof after holders close. A subsequent connection succeeds.

These are injected-delay controls validating diagnostic discrimination. They are not a spontaneous hosted reproduction. The exact-public Rust library suite, strict collector tests, mobile-probe tooling tests and release test-target check are recorded alongside the separate source capsule.

## Service forwarding and cross-language smoke

The service's `NativeInputErrorForwarder` is a required intermediate boundary: `NativePipe` never forwards arbitrary child stderr. Its strict TypeScript decoder explicitly admits the two new schemas with the same fixed roles/stages and integer 0–60000 duration bounds. Canonical JSON, 384-character scan limits, first-event/count/byte limits and explicit environment opt-in remain intact. The actual NativePipe test covers both schemas with the flag disabled and enabled, alongside hostile extra fields, invalid phases, booleans, fractions, duplicate keys and duration boundaries.

The separate v2 evidence runs all three actual Rust socket controls under the diagnostic flag, streams their real stderr chunks through the TypeScript forwarder, then writes the strict Python collector artifact. It retained 26 sanitized events / 2674 bytes with all three expected signatures. Raw stderr is not saved. The source changes alone do not require a workflow edit; both the service boundary and Python boundary now admit the new schemas.
