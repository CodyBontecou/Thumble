# iPhone 17 Pro orientation verification

Verified October 24, 2026 on Cody's physical iPhone 17 Pro, iOS 27.0.1.

## Build

The original CocoaPods failure came from restricted network access. Hermes' prebuilt-artifact lookup failed and fell back to a source build, which then required the unavailable `cmake`. Running `pod install` with network access selected and checksum-verified the cached SDK-compatible Hermes 260318099.0.4 archives. All 122 pods installed successfully; no source build or additional CMake installation was needed.

Built and signed a fresh Release app from `apps/mobile/ios/Thumble.xcworkspace`, scheme `Thumble`, for the iPhone 17 Pro. Xcode reported `BUILD SUCCEEDED`. Installed `com.thumble.ios` in place, preserving app data. The compiled Info.plist supports portrait and both landscape orientations.

Local logs: `build/portrait-pod-install.log`, `build/portrait-ios-device.log`, `build/portrait-ios-install.log`.

## Hardware results

| Check | Result | Evidence |
| --- | --- | --- |
| Launch disconnected while phone is upright | Portrait | `disconnected-portrait.png` |
| Connect the controller | Automatically switches to landscape | `connected-landscape.png` |
| Confirm real receiver connection | Menu displays connected status and Disconnect Mac | `connected-menu.png` |
| Leave controller for Getting started, keeping connection alive | Portrait allowed; rotating sideways and back upright returns to portrait | `onboarding-connected-portrait.png`; user also confirmed |
| Return to connected controller while upright | Landscape enforced again | `returned-controller-landscape.png` |

The transparent controller menu stayed landscape when first opened. General screens release the orientation restriction rather than forcing portrait immediately: the hardware check included a physical tilt to generate an orientation event. Physical rotation cannot be injected by Argent on an iPhone.

Pairing used the existing isolated real receiver protocol with a linked gamepad stub. No game input was sent, and the controller remained paused. The QA receiver was stopped afterward.

The final navigation fragment `.argent/flows/iphone17-orientation-return.yaml` replayed uninterrupted: 9 passed, 0 failed, 0 errored, including screen identity and idle checks. It requires the connected controller foregrounded and an available isolated test receiver. It verifies navigation; the screenshots and physical rotation establish orientation. Capture used the physical iPhone accessibility fallback; the final replay resolved all semantic targets without warnings.

The first attempt was interrupted by a transient USB/runner disconnection and was discarded. The successful attempt above was recorded separately.

## Checks

- Final connection, onboarding, and pairing-link tests: 48 passed.
- Final mobile lint and TypeScript checks passed.
- Intermediate typecheck runs reported errors in concurrently edited controller/onboarding files; those edits were left intact. The final check was clean. Logs: `build/portrait-lint-final.log`, `build/portrait-typecheck.log`, `build/portrait-tests-final.log`.
