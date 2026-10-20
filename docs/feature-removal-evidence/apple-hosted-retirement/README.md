# Apple hosted retirement evidence

This batch removes Apple hosted pickup, link download, Practice Preview and phone adoption upload, while retaining local file import and read-only pending-build recovery. It does not retire the paired receiver protocol or stop deployed services.

## Automated checks

- `focused-tests.log`: 68 tests pass, including recovery, portable artifacts, local Mac import, legacy compatibility and 35 constrained-thread tests.
- `stack-safety.log`: final required `./scripts/verify-stack-safety.sh` passes with 35 constrained-thread tests, macOS/iOS Debug builds and unchanged frame budgets.
- `retained-import-tests.log`: final retained protocol/import/recovery tests after the UI changes.
- `cli-import.log`: freshly built Apple CLI and legacy fallback, packaged in a temporary directory with the previously verified Rust bridge siblings, import the original portable fixture with append/no-select. The active setup remains selected. The original unbundled Xcode CLI could not run without its required exact-sibling bridge; the packaged run supplies that dependency.
- `packaged-clients.log` and `binary-hashes.json`: `scripts/verify-apple-hosted-retirement.py` checks the unminified app executables and Debug dylibs. The retired HTTP fetcher, link reference, pickup/preview coordinator and pruning store are absent. Read-only recovery/local import remain. Source associated-domain entitlements are empty.

The package marker check supplements source and tests; it is not a complete network audit.

## Simulator recovery and cancellation

The live recording and final uninterrupted replay use an isolated iPhone 17 Pro simulator on iOS 26.5. No real user profiles or pairing credentials were loaded. Before first launch, its app data contained these files in `Library/Application Support/Thumble/PendingBuilderArtifacts/v1`:

1. `b2100000-0000-0000-0000-000000000001.artifact.json`: exact `Host/fixtures/profile-artifact/v1.json` bytes.
2. The same UUID's `.metadata.json`: `{"expiresAt":0,"state":"adopting","future":"preserve exact bytes"}`.
3. `b2100000-0000-0000-0000-000000000002.artifact.json`: `original incomplete fixture`, without a trailing newline.

The app starts before onboarding/pairing. The flow opens recovery, prepares a valid original profile export, observes the native filename field, dismisses the native sheet, closes recovery and verifies onboarding remains. `source-hashes.json` proves all three originals remain byte-identical after the live cancellation and replay. `native-exporter.png` shows the actual file exporter. A successful system-files save was not exercised; exact export bytes, failed destinations and retry are covered by unit tests.

The saved flow is `.argent/flows/ios-retired-build-recovery-cancel.yaml`. Replay through Argent `flow-execute` with `name: ios-retired-build-recovery-cancel`, this repository as `project_root`, `platform: ios`, and an explicitly selected fresh seeded simulator as `device`. The simulator must use the same device size, English UI, default text size and uncompleted onboarding. Never seed these files into an existing user's installation.

`replay.log` records the final pass: 20 executable steps pass, zero fail/error/skip. Echo steps are not counted. The flow uses two documented coordinate taps, at `(0.73, 0.0955)` and `(0.5, 0.5725)`, plus the native sheet-dismissal swipe from `(0.5, 0.1)` to `(0.5, 0.86)`. AX discovery sees the SwiftUI controls, but the working native UIView tree contains no corresponding labeled/id-bearing controls and runner text probes fail. The flow therefore retains AX-backed raw waits, with the explicit app bundle hint, and verifies each resulting screen. Done uses its native text selector. These coordinate fallbacks are device-specific and do not establish portable QA acceptance. The remote document picker's Cancel tracking view overlaps the visible More control, so cancellation uses the actual sheet-dismissal gesture.

This evidence does not establish physical haptic behavior, device input latency or live WoW acceptance.
