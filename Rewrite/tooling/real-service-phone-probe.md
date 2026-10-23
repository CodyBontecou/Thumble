# Real service phone witness

This opt-in QA adapter runs the source CLI service with its native receiver,
persistent host identity, pairing listener and separate saved-configuration owner.
It imports two synthetic profiles through the CLI, activates the second profile,
and verifies native phone input through authenticated service IPC and the actual
recording log. TLS, enrollment, input grants, renewal and management reads use the
ordinary native implementations. OS output remains disabled.

Build the native receiver and install the workspace dependencies first. The SDK
launcher uses the executable Bun script; Bun must be on `PATH` (macOS/Linux).

```sh
bun test tests/probe-phase-gate.test.ts tests/real-service-phone-probe.test.ts
THUMBLE_REAL_SERVICE_PHONE_PROBE="$PWD/tooling/real-service-phone-probe.ts" \
  swift test --package-path native/mobile-input/ios \
  --filter actualRealServiceCatalogReadPreservesNativePhoneHeldInput
THUMBLE_REAL_SERVICE_PHONE_PROBE="$PWD/tooling/real-service-phone-probe.ts" \
  bash apps/mobile/android/gradlew -p native/mobile-input/android --no-daemon \
  testDebugUnitTest --tests '*RealServicePhoneTest'
```

The new Swift and Kotlin cases exercise UDP and TLS fallback independently.
Native sampling continues every 16 ms on the engine owner while a separate v7
management connection reads the exact saved revision, two profiles and selection.
The receiver must record at least 1.5 seconds of continuous held input with its
350 ms input TTL, then acknowledge neutral input after native cancellation.
Both sockets share the verified host pin/authority and native credential source;
credentials never enter a product JavaScript bridge. These cases use memory
credential storage; OS vault acceptance is covered separately.

The adapter also implements the existing `phone_input_probe` byte protocol.
Point `THUMBLE_NATIVE_INPUT_PROBE` at it to run the existing SDK input witnesses
against the actual service. The `b`/`v` renewal gate still requires 75 seconds,
two rotations, no neutral pulse and the unchanged 350 ms TTL. The separate `q`/`j`
catalog gate requires 1.5 seconds; it does not replace the renewal gate.

Observation work is bounded to one in-flight request and 64 KiB recording reads.
A phase gate drains observations before commands change the expected report,
preventing an old held-report observation from crossing phase completion.
An adapter-wide 180 second deadline and signal cleanup stop only the owned
service and remove its temporary runtime. Fixed diagnostics can be enabled with
`THUMBLE_REAL_SERVICE_PROBE_DIAGNOSTICS=1`; the optional diagnostic tag accepts
only the five existing SDK mode names.

The initial offer contains a synthetic enrollment secret for the private test
pipe. Do not publish the offer, endpoint file, identity directory or raw stdout.
Successful public evidence should contain only bounded test outcomes/counts.

This proves native SDK input and saved metadata through the service. The saved
fixture contains empty layouts; converting saved layouts to phone controls and
rendering `onCatalog` in the actual React `NativeController` remain separate
acceptance work. No physical phone, OS output or real game capture is exercised.
