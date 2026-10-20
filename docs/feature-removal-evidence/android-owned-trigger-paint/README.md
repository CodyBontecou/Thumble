# Android owned trigger paint evidence

`OwnedAppearanceInputDeviceTest` ran on the arm64 API 26 `thumble-parity-api26` emulator. These PNGs are actual offscreen native `ControllerSurface.draw(Canvas)` captures at 1600 × 700, not screenshots of the app's navigation or product-design approval. The test holds the fourth, unrelated button while adding LT and RT, then releases LT and RT independently. Each capture asserts the current action set, displayed icon and exact background pixel. Child View identities and bounds remain unchanged, and matching release edges keep their original press identifiers.

- `base.png`: initial Base state.
- `left-held.png`: unrelated button and LT held.
- `both-held.png`: unrelated button, LT and RT held.
- `right-held.png`: LT released while unrelated button and RT remain held.

The same suite verifies accessibility analog activation strictly above 0.5, focus-loss/profile-revision reset, no stranded state after an accessible click, and differing PNG asset bytes behind an identical asset-icon descriptor. A fake actuator checks haptic routing without vibrating a physical phone. Other native regression suites cover existing controls/transports, renderer, assets/styles, binding metadata and haptic settings. `instrumentation.txt` records the 29-test passing run; `verification.json` records PNG/APK hashes and the 199-test unit count.

This evidence does not establish physical haptic behavior, physical input latency, live WoW-client behavior, or an activated version-5 migration. Original frozen migration fixtures are unchanged.
