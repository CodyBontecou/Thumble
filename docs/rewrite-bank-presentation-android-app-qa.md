# Actual Android bank presentation QA

`BankPresentationAppTest` drives the bundled React Native app through its Test
connection route and normal native manual invitation entry. A new owned,
recording-only receiver serves a synthetic South button and independent LT/RT
controls. No game, capture, physical phone, user trust store, or physical input
output is used.

The test sends actual Android multi-pointer MotionEvents: South remains held
while LT and RT select base, left-trigger, right-trigger, and both-trigger banks.
It checks all four light banks, A/B/A reuse, dark theme, and an appearance CAS.
The native recording witness confirms full LT/RT plus South remain held for at
least 1.5 seconds across refresh, unchanged input epochs, a 350ms input TTL,
and zero neutral pulses. Subsequent dark-bank transitions, neutral release,
and Done complete the route.

The image oracle reads the mounted React Image raster only when it is attached,
shown, window-visible, fully inside global bounds, and every ancestor has alpha
at least 0.999. It compares expected synthetic PNG colors. This is not a
composited screen-pixel oracle. A separate full screenshot is saved privately
and reviewed for visible connected state, trigger labels, artwork and Done.
Cleanup independently attempts gesture cancellation, provider reset, theme and
orientation restoration, retaining the primary failure.

`run_bank_presentation_app_probe.py` requires an explicitly selected owned emulator (emulator-5580 locally or
emulator-5554 in its CI job), starts a
loopback-only synthetic service, configures only its own adb reverse mappings,
and admits exactly one named, unskipped JUnit case with zero failures/errors.
Both Gradle aggregate and direct suite roots require exact counters; nested or
extra suites/cases fail. Four parser tests cover positive and rejected reports.
An optional absolute executable `--service-probe` selects an isolated service/native
build without replacing shared binaries; the default remains the local probe.
Private reports stay under RUNNER_TEMP. Failure-only native diagnostics contain
bounded state and reason fields; invitations and raw native logs are excluded
from the runner stdout summary.

The first run timed out during an accidental four-ABI setup build; subsequent
runs explicitly selected arm64-v8a. Two app runs failed on a bank pixel check;
one had a downstream transport closure and remains part of the unresolved
native receiver investigation. A later actual case passed, but exposed a runner
parser that rejected Gradle's valid testsuites wrapper. After correcting that
parser and adding aggregate admission coverage, the complete runner passed
with one case, zero skips/failures, and all five service phases. These results
show the route works; they do not establish disconnect-free endurance or
physical-device acceptance. Earlier failed evidence is retained privately. A subsequent
complete runner pass used the explicit isolated service probe and its aligned
native build, rather than the shared development receiver binary. It again
admitted one case, zero skips/failures and all five service phases.

From Rewrite, use pinned Bun on PATH, JAVA_HOME for JDK 17, ANDROID_HOME,
ANDROID_SERIAL=emulator-5580 and a private RUNNER_TEMP, then run:

```sh
python3 tooling/run_bank_presentation_app_probe.py --platform android -- \
  ./apps/mobile/android/gradlew -p apps/mobile/android \
  :app:connectedNativeQaAndroidTest -PreactNativeArchitectures=arm64-v8a \
  -Pandroid.testInstrumentationRunnerArguments.class=com.thumble.rewrite.qa.BankPresentationAppTest
```
