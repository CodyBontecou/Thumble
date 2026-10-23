# Hardware and gameplay validation — October 23, 2026

## Implemented and checked

- JavaScript controller profiles, multitouch ownership and validation: `npm test` passes all 29 tests (19 controller tests, eight connection lifecycle tests and two timing-recorder tests). Includes simultaneous sticks/buttons/triggers, cancellation, profile replacement, deadzones, invalid input and invitation parsing.
- `npm run check`, mobile ESLint and JavaScript type checking all pass.
- Native HID codec checks pass all 15 button bits, signed axis endpoints, positive-up Y, trigger conversion, opposite D-pad cancellation and invalid state rejection. Run `xcrun swiftc apps/receiver/Sources/Report.swift tools/receiver-tests/main.swift -o build/receiver-report-tests && build/receiver-report-tests`.
- Signed macOS 15+ receiver publishes an Xbox-compatible virtual HID gamepad. A separate Apple GameController observer recognizes `Tapping Wi-Fi Gamepad` as an extended Xbox gamepad and observes real phone inputs. Build uses the approved development HID profile and strict signature verification. This is not a notarized public installer.
- iOS and Android native Release builds both succeed and are installed on the physical test phones. Native certificate-pinned TLS WebSockets run without Metro in bundled Release builds. The local Expo module uses URLSession on iOS and OkHttp on Android. QR invitations contain an expiring single-use token and the exact TLS leaf fingerprint. Manual/deep-link pairing has been exercised. Optical QR pairing is confirmed on both physical phones; the user confirmed the Pixel successfully scanned and paired after the Release scanner fix.
- `node tools/test-receiver.mjs /path/to/private-invitation` passes six live protocol checks: invalid token, hello/input/ack/disconnect, duplicate sequence rejection, expired/unknown lease discard plus neutral recovery, idle pause/timeout, and invalid-state rejection. Non-neutral recovery attempts are rejected; applied test input is neutral. The private QA export is opt-in and must not be committed.

## Actual WoW + ConsolePort test

Test host: macOS, WoW Classic Era **1.15.9 (70003)**, ConsolePort **3.3.11**, logged-in character in Northshire Valley. Existing game bindings were retained. This is the installed Classic client, not the forthcoming Forever client.

Physical **Pixel 7, Android 17 / API 37**, bundled Release package `com.thumble.android.tappingdev`:

- Pairing link authenticates over local Wi-Fi; the phone reports connected and receives HID acknowledgements.
- Left stick moves the character in the world; releasing it stops movement. Positive-up Y reaches GameController correctly.
- Right stick rotates the in-game camera and returns to neutral on release.
- Menu opens WoW's controller-aware menu; another press dismisses it.
- LT reaches 1.0 in the independent observer and changes ConsolePort's action bar.
- Backgrounding the phone while LT is held returns LT to 0.0 in the Mac observer and disconnects. Re-entry requires fresh pairing.

The observer output is in [gamepad-live-values.txt](evidence/gamepad-live-values.txt). It includes exploratory attempts before the final passing actions; the observations above describe the confirmed passes. A [connected Android screen](evidence/phone-connected.png) records the controller and neutral readout. Earlier simulator multitouch also demonstrated independent movement plus A, then neutral release; [practice layout](evidence/controller-practice.png).

Physical **iPhone 13 Pro Max, iOS 26.3.1**, Release package `com.codybontecou.PocketPad.iOS.tappingdev`: build succeeds with zero errors (the latest build reports five toolchain warnings), installs and renders the controller. Fixed the SDK 58 scene delegate runtime-name mismatch with a config plugin and isolated the development bundle from stale scene state. The user allowed local-network access and confirmed QR pairing. Automation observed the authenticated connection and independent Mac HID values for LT (1.0 then 0.0) and left-stick positive Y (about 0.518 then neutral). In WoW, a 1.5-second iPhone left-stick hold changed `UnitPosition("player")` X from -8838.900390625 to -8835.2001953125, with Y approximately -102.5 to -102.2. Explicit Disconnect returned the app to practice mode. See [connected iPhone](evidence/iphone-connected.png) and [independent iPhone HID observations](evidence/iphone-gamepad-values.txt). A later Release build also passed right-stick camera rotation and Menu opening WoW’s controller-aware menu. One earlier socket disconnection was observed and fresh pairing recovered.

## Limits and release gates

The observed Android acknowledgement samples varied roughly 13–84 ms, with occasional higher stalls (including a 217 ms sample). These are opportunistic round-trip samples, not a p50/p95 benchmark or touch-to-game measurements. The under-20 ms p95 engineering target has **not** been established. TCP no-delay, immediate transitions and bounded queues are implemented; further Wi-Fi and transport profiling remains necessary.

Still outstanding: complete button/modifier combinations on both phones, loss/congestion/lock/process-kill QA, clean-install onboarding, supported macOS/Android/iOS matrix, Forever-client compatibility, MCP server and profile distribution/revision activation, public Mac distribution signing/notarization, and public store submissions. Public launch readiness has not been established.

The earlier dependency audit reported `node-forge` / Expo CLI advisories; reassess supported toolchain updates before release. No forced SDK downgrade was applied.

See [launch gates](architecture.md), [onboarding acceptance criteria](onboarding.md), [wire protocol](lan-protocol.md) and [macOS HID research](research/macos-virtual-gamepad.md).

## Automation caveat

On this Pixel/Argent version, landscape `gesture-custom` injection uses portrait-oriented touch coordinates while the accessibility tree describes landscape coordinates. For the observed orientation, convert tree centers with `injectedX = 1 - treeY`, `injectedY = treeX`. This was confirmed against native touch diagnostics before the passing gameplay actions. Always release an injected Down with Up, including after a Home-button/background test. Remove temporary touch logging from production code (done). This tooling correction is not part of the app's own touch mapping.

The physical iPhone's local-network system alert exposed a clipped, rotated accessibility tree without its Allow button. Do not infer its target from screenshot pixels; user assistance is required for that prompt in this tooling version.

## Android scanner regression

The user reported that the QR was visible but the Android scanner did nothing. With the scanner open, `ANDROID_HOME=/path/to/sdk node tools/check-android-scanner.mjs DEVICE_SERIAL` reproduced a native failure: the preview stream produced thousands of frames, but the YUV barcode-analysis ImageReader produced zero.

The underlying Release bug was removed no-argument constructors on three manifest-discovered ML Kit component registrars. Native logs showed `NoSuchMethodException` for `CommonComponentRegistrar`, `BarcodeRegistrar` and `VisionCommonRegistrar`. ML Kit could not initialize its dependency graph. A temporary system-scanner probe misleadingly reported Play Services unavailable; its underlying exception came from the same missing registrations. Play Services was installed and enabled.

The final fix uses `expo-build-properties` to retain ML Kit's `ComponentRegistrar` implementations and members. Release optimization remains enabled. The original inline scanner is retained, with duplicate barcode delivery guarded and camera startup failures surfaced. Temporary diagnostics, source-build overrides and the system-scanner experiment were removed.

The final Release build passes `node tools/check-mlkit-release.mjs`: all three manifest-discovered registrar constructors survive shrinking. The same native camera diagnostic now passes with **117 analysis frames** initially and **2,481** on the subsequent sustained check, versus zero before the fix. The user then confirmed that optical scanning and pairing worked, and automation independently observed the Pixel connected.

`node tools/sync-android-config.cjs` applies the configured Expo Android mods to an existing generated project using the same compiler as Prebuild, without replacing its template. New clones still need ordinary Expo Prebuild. Generated native files are not hand-edited.

## Connection lifecycle hardening

Native socket events carry an opaque connection ID; the JavaScript client ignores events from a superseded connection. Android serializes socket replacement and callback cleanup so a failure from an old client cannot cancel its replacement. Pairing preparation is cancellable, including overlapping permission requests. Pause recovery clears held input before resuming with the fresh lease.

Seven deterministic tests cover stale callbacks, cancellation during preparation, overlapping preparation, neutral pause recovery, duplicate acknowledgements, failed initial sends, handshake timeouts and invalid future acknowledgements. These changes address demonstrated lifecycle risks; the cause of the earlier physical iPhone disconnection remains unconfirmed.

The updated Release build was installed on each physical phone. The iPhone remained connected for more than two minutes while movement, camera rotation and Menu were exercised. Explicit disconnect and a fresh invitation re-pair succeeded; the independent GameController observer recorded both sticks returning to neutral. The physical-iPhone Home automation continued to return the app screen, so iPhone background/lock recovery remains unverified. See [recovery observer output](evidence/recovery-gamepad-values.txt).

The Pixel’s updated build likewise remained connected for more than two minutes. Left-stick and LT press/release reached the independent observer. Backgrounding returned the app to disconnected practice mode, and a fresh invitation re-pair succeeded. A separate held-LT test observed LT at 1.0 before Home and 0.0 after Home, before injecting the final touch Up. No iPhone background claim is inferred from this Android result.

## Latency measurement

[Latency report and reproducible evidence](latency.md) now separate native RTT, JavaScript acknowledgement overhead and Mac receipt-to-HID submission. More than 12,000 acknowledged samples were collected across physical iPhone, Android control/candidate/reversal, and direct-parser runs. Native RTT medians were about 9ms on iPhone and 13ms on Pixel; p95 varied materially. Mac processing p95 was below 0.3ms. A Wi-Fi low-latency-lock experiment failed to improve tail latency and was reverted. Direct state validation removes a redundant JSON round trip, saving several microseconds in an isolated benchmark, without an established end-to-end improvement. The under-20ms p95 target remains unproven.

## Controller-only view and captured stick drags — October 23, 2026

The player reported stick movement stopping outside the visible circles. The existing engine and simulator baseline retained an outside drag, so the physical-device cutoff was not reproduced automatically. The phone canvas now explicitly owns the native responder until release or system cancellation. Each stick starts inside its rendered circle, keeps its finger when it leaves the circle or canvas, and projects an outside drag onto the rim without changing its angle. Release, backgrounding, navigation, layout replacement and resize still neutralize input.

The play view now shows only controls and a 32-point Thumble app icon inside a 44-point menu target. Profile name, connection status, round-trip time, pairing/disconnect, WoW setup and instructions live in an Expo Router overlay. Opening options releases held input; underlying controls are hidden from accessibility while another screen has focus. Done and tapping the backdrop return to play. The icon is copied unmodified from the original Thumble iOS asset catalog (`Resources/iOS/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`), rather than the rewrite's Expo placeholder.

Release simulator verification used an isolated TLS preview receiver that discards all input. Two fingers held both sticks beyond their circles simultaneously for several seconds, with both output axes remaining active; lifting returned all outputs to neutral. The icon opened the menu and WoW setup remained reachable. See [UI recording](../.argent/recordings/controller-only-preview.mp4) and [controller-only still](evidence/controller-only-preview.png). These are UI checks, not gameplay or latency evidence. The physical iPhone build installs successfully; final player verification of outside-circle drags remains separate.

## Physical sustained-hold diagnosis — October 23, 2026

The player clarified that all held controls were struggling, including buttons. Read-only macOS GameController observation confirmed repeated neutral transitions. A receiver isolated from HID then reproduced the cutoff on the physical iPhone: a five-second LT hold remained held for only 2,274.5 ms under the original 150 ms watchdog / 150 ms lease rules. Its log showed watchdog events both after actual 151–188 ms arrival gaps and while recently arriving packets were rejected because their server leases had expired. Timeout recovery deliberately clears touch ownership, explaining why continuing to hold or dragging farther did not recover the control. The earlier no-timeout simulator mock could not expose this failure.

The same five-second physical gesture with a 300 ms watchdog and separate 500 ms server-clock lease budget produced a continuous 5,001.1 ms hold (148 held snapshots), zero watchdog pauses and zero expired packets during that comparison. All input was discarded; no agent-generated gameplay was sent. See [summary](evidence/hold-reliability/physical-hold-summary.json) and [numeric comparison trace](evidence/hold-reliability/tolerant-input-trace.jsonl). These are single comparisons on shared Wi-Fi, not a gameplay soak or a reliability rate.

`InputTiming.swift` now supplies those bounded deadlines to the actual receiver. Native regression checks replay 170–190 ms gaps, require release after 301 ms silence, and reject a lease at 501 ms. Background, disconnect and explicit cancellation still release immediately. A genuine timeout revokes leases and requires fresh neutral recovery; the fix does not replay a held state after a pause. The controller profiles also correct horizontal direction with `invertX: false` and retain `invertY: true` (Warrior and ConsolePort revision 5, activation 6 acknowledged before isolated testing).

The parallel “Build AI-driven controller app” chat is integrating these findings with its input queue/backpressure work and owns the final combined build and live verification. The receiver source and isolated hold comparison are verified here; combined deployment and sustained gameplay remain that chat's acceptance work.

## Phone profile picker — October 23, 2026

Added **Thumble icon → Profiles** with the shared Mac inventory, current selection, loading/switching states, Refresh, and inline connection/conflict errors. Saved profile bodies are never accepted from the phone; authenticated WebSocket requests choose an existing profile revision with an expected activation revision. Native activation honors the agent store's writer lock and atomic replacement. Switching waits for the matching rendered layout and fresh neutral recovery acknowledgement.

Verification: 72 JavaScript tests pass, mobile source lint/typecheck pass, and `node tools/test-profile-catalog.mjs` passes the native shared-lock/revision/Node-reader checks. A Release simulator app with the final Hermes bundle switched Bonteq → Warrior → Bonteq against an isolated Node receiver that discards input and uses a separate profile store. A previous pass also selected Xbox. Safe-area/notch placement and the disconnected error were inspected. See [picker still](evidence/profile-picker.png) and [UI recording](../.argent/recordings/profile-picker-preview.mp4).

A signed separate iPhone artifact is prepared at `build/Profile Picker iPhone.app`; it preserves the existing native Release binary/frameworks and updates the Expo/Hermes bundle because this feature adds no native phone modules. The receiver is built/signed at `build/Tapping Receiver.app`. Neither is deployed to physical test devices by this chat: the coordinated reliability chat owns the receiver, iPhone 17 and Pixel until its explicit handoff. Actual signed-receiver wire verification and physical installation remain pending there. The default user profiles were not modified by simulator QA.


## Input delivery recovery and physical gameplay follow-up — October 23, 2026

The [input reliability report](input-reliability.md) records the reproduced sender burst failure, native-capacity queue fix, stale-input cancellation, neutral recovery, and coordinated 300 ms receive timeout / 500 ms lease budget. Final physical iPhone 17 Pro and Pixel 7 batches each passed six eight-control cycles with independent HID audit assertions and neutral endings. One iPhone pause recovered outside the cycles; Pixel recorded zero pauses. Backgrounding released controls, including an actively held Pixel trigger. WoW Classic Era with ConsolePort responded during movement/camera/jump checks; a longer combat soak, other networks, and the intended launch client remain unqualified. 78 JavaScript tests, ESLint and TypeScript checks passed. Repeated HID recreation previously hung WoW; final runs preserved the device across phone switching.
