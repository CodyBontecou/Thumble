# iOS simulator bank artwork witness

`Rewrite/tooling/run_bank_presentation_ios_probe.py` drives a separate
`BankPresentationUITests` target created by `prepare-ios-bank.rb`. It uses the
owned simulator, the actual bundled React route, normal native invitation entry,
real Keychain enrollment, production saved-map admission and role 11 cosmetics.
The service is an isolated recording-only synthetic fixture; no game, optical
capture, user configuration, or physical input backend is involved.

The fixed gesture contains at most three active pointers. South stays held while
left/right trigger captures select base, left, right and both banks. The test
checks visible screen pixels in both themes, changes all appearance variants
through the real configuration CAS path while both triggers and South remain
held, and requires the native recording witness to prove at least 1.5 seconds of
that exact report with no neutral pulse and the unchanged 350ms input TTL. Done
must return Home and acknowledge neutral cleanup.

Public XCTest gestures cannot express arbitrary independently held fingers. The
small Objective-C helper therefore uses guarded selectors from the installed
XCTest event-synthesis runtime, a pattern also described by
[Appium's input-event documentation](https://github.com/appium/appium-xcuitest-driver/blob/master/docs/guides/input-events.md).
The three paths start together and contain explicit stationary endpoints before
each 100ms transition; an arrival-time keyframe alone would slowly drag across
the intended hold window. This is simulator tooling evidence, depends on
the installed Xcode runtime, and fails rather than skips if those selectors are
unavailable. The helper belongs only to the separate UI-test runner; preparation
checks that it is absent from the production app source target. No private API,
test input registry, injected controller map, or secret bridge is added to the
product app.

Visible pixel checks sample a supported `simctl io screenshot` capture of the
owned simulator, including the native
accepted-touch highlight composited over the React Image. The oracle accounts
for the existing system-blue 30% highlight; it does not redraw a detached image
or infer a bank from callback counts. XCTest's app/screen capture exhibited
orientation cropping in initial attempts; those raw failures are retained, and
XCTest attachments are not substituted for the supported simulator capture. Screenshots and raw UI logs remain in
`RUNNER_TEMP`, because XCTest may record the typed synthetic invitation. The only
stdout result is bounded outcome/count metadata. Result admission requires the
exact single test class/method, zero failures and zero skips; an unrelated or
empty successful test run fails the witness.

Use a fresh private output directory and an explicitly selected frozen service
probe when reproducing a reviewed source snapshot:

```sh
RUNNER_TEMP=/private/tmp/thumble-ios-bank-proof \
python3 Rewrite/tooling/run_bank_presentation_ios_probe.py \
  --derived-data /private/tmp/thumble-saved-map-app-build \
  --service-probe /absolute/reviewed/Rewrite/tooling/presentation-service-probe.ts
```

`--service-probe` loads the reviewed probe module from that explicit absolute
path. Its module-relative runtime uses that snapshot's native receiver rather
than a live worktree binary. The separate iOS-only adapter has a fixed 180-second
fixture watchdog for manual entry and the 62-second gesture; the existing
60-second SDK probe and all product deadlines remain unchanged. Record the
receiver SHA256 with the source snapshot when reporting a run.

The runner restores the simulator's original appearance, the prior local probe
configuration, and its child service. It never installs on a physical phone or
modifies another simulator. Passing this witness would establish synthetic
simulator artwork/input integration; gameplay, physical multitouch, and real
optical game-data acceptance remain separate gates.

## Current acceptance status

The original pixel fixture did not reliably distinguish adjacent banks: eight
raw RGB levels become only five or six levels after the native 30% highlight,
so tolerance-five acceptance boxes overlap. A regression against the original
fixture fails with a six-level separation. Earlier pixel observations therefore
do not establish unique bank identity, even where the rest of a run progressed.

The iOS-only adapter now explicitly selects a wider synthetic palette: initial
red values `0,16,...,112`, refreshed values `128,144,...,240`, green `64` and blue
`255-red`. At 70% image opacity, every held-state RGB box is separated by at least
11 integer levels, greater than twice the unchanged five-level tolerance. A
focused test decodes all 16 actual generated PNGs and checks all 120 pairs. The
XCTest also checks every pair with the actual runtime-resolved light/dark UIKit
highlight, including held and unheld states, before admission. Unexpected tint
changes fail the witness instead of weakening its oracle. Default Android/SDK
fixture bytes, input geometry, timeouts and product behavior remain unchanged.

The corrected palette passed a full local simulator run: exactly one XCTest case, zero failures and zero skips, all four banks in both themes, appearance CAS, held-report continuity through refresh, and neutral release on Done. The strict runner reported `status: passed`; all 15 screenshot boundaries observed an active receiver before and after capture. The dark/both-trigger screenshot was also visually reviewed. This establishes this local synthetic artwork witness; it does not establish physical-phone, real-game, latency or endurance acceptance.

Earlier attempts remain failed. The corrected three-pointer trajectory reached
all bank/theme pixels, the appearance CAS and held-report check in one local run,
then exposed a final fixture-key mismatch (`neutral`/`completed`, not `ok`). The
next run used the corrected keys and passed CAS/held verification, but later
failed with the native receiver's first termination reason `input_expired`.
Native state was already inactive before the failing capture. Earlier malformed
XCTest captures and interpolated gesture trajectories are preserved as failed
QA attempts. None is reclassified as a passing test, and no input deadline was
increased. A subsequent attempt stopped at setup because the selected Ruby lacked `xcodeproj`; selecting the existing system Ruby resolved that setup issue before the passing run.

For CI, create and boot a dedicated simulator named
`Thumble Rewrite Bank CI <suffix>` (ASCII letters, digits, underscore or hyphen;
1–64 characters), pass its canonical uppercase UUID using `--device`, and set
`RUNNER_TEMP` to a fresh nested private directory such as the job's
`private/bank-ios`. The runner checks the UUID against the authoritative available
simulator inventory before touching appearance or building. Only that naming
policy or the explicitly owned local simulator is admitted; unknown, duplicate,
unavailable, unrelated, and physical-device identifiers are rejected.

Cleanup independently attempts server shutdown, native child shutdown, original
appearance restoration, and prior configuration restoration. Cleanup failure
cannot replace the original test exception; it forces a failed sanitized result.
The final CI runner ownership/cleanup changes have focused unit coverage and were used in the complete passing local run. Hosted CI acceptance remains separate.
