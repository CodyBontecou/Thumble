# Android / iOS parity acceptance

Goal: implement all user-visible iOS functionality on Android, with equivalent
platform-native behavior. This remains an active goal until each row is implemented
and verified. A transport-compatible vertical slice is not full parity.

Baseline: current Sources/iOS and the shared controller/profile/skin models,
reviewed 2026-10-19. Update this inventory as additional iOS behavior is found.

| Requirement | Authoritative iOS sources | Android state / required proof |
| --- | --- | --- |
| QR/manual pairing, challenge, expected server identity | QRCodeScannerView, ControllerClient | Implemented; decoder and physical network tests pass; optical camera scan still needs verification |
| Saved trust, smart reconnect, changed addresses, foreground/background recovery, forget Mac | ControllerClient trusted credentials and MacServiceDiscovery | Implemented with Keystore storage, capped retry, network wake-up, disconnect/forget and revocation/identity guards; Pixel tests retain pending/paired sessions during recreation, suspend on real backgrounding, and pass real Mac fresh-store reconnect; broader API/device matrix pending |
| Nearby discovery and service-only pairing QR | MacServiceDiscovery, shared PairingPayload | LAN NSD and service-only QR implemented and verified against real Mac, including stale cached URL recovery. Apple peer-to-peer-only connection still requires a verified Android equivalent; not complete |
| Offline saved profiles and practice mode with no outgoing input | ControllerClient, IOSLocalKeypadUX | Saved profiles, offline switching and persistent practice implemented; Pixel cache reload and suppression/release tests pass. Advanced control suppression verified through native surface callbacks and heartbeat interval |
| Orientation preferences and variant selection, uninterrupted rotation, calibration | GamepadOrientationCoordinator, ThumbPlacementCalibrationView | Native locks, variant selection and rotation without activity recreation implemented/tested on Pixel. Calibration and wider device geometry remain missing |
| Buttons, element parts, per-touch hold/slide/release behavior | TouchCaptureView, ControllerClient | Buttons and canonical joystick/trigger parts implemented; Pixel mixed holds, capture, cancellation, accessibility actions, and Rust recorded bindings verified; broader geometry/device coverage pending |
| Joystick directions, analog sticks/triggers, pointer trackpad/move/scroll/click/drag | ControllerClient, shared keypad renderers | Implemented joystick capture/transforms, analog coalescing/refresh/neutral, trigger thresholds, trackpad movement/scroll/taps. Pixel native gestures → Rust recorder pass with direct UDP and mid-hold UDP loss; API 26 emulator → real AppKit movement/scroll/left/right clicks and receiver-level drag/cancel now pass healthy UDP and UDP loss. Physical pointer acceptance and actual HID consumer output remain pending |
| Haptics, control/accessibility feedback, keep awake, appearance/settings | IOSLocalKeypadUX, IOSContentView | Basic accessibility and keep-awake implemented. Button/trackpad haptic model, style cascade, activation routing and Android waveform output now implemented; 53 local tests and 40 exercised Pixel methods pass. Persistent five-level intensity settings and local preview are implemented/verified; tactile comparison, settings theme/geometry matrix and remaining feedback/settings remain open |
| Full renderer: element kinds, style tokens, layers/action sets, skins, vector/raster assets, fills, text, hit regions, dark/light | Shared skin compiler/resolver/renderers, ControllerClient | Native size/center/clamp rules, builtin override ownership, design layer order, all seven canonical shapes, per-corner radii, solid/linear/radial/tile fills, profile appearance, legend visibility and accessibility names implemented. Pixel pixel/gesture/portrait/landscape captures pass. Canonical raster asset references/inline data, fit/crop/tile/nine-slice modes, JPEG EXIF orientation, image adjustments, native token/inline state inheritance, core fill/foreground/border/opacity/scale and authored text fields are now implemented/tested. Passive artwork planes (including blend/rotation/opacity/order), text/raster icons, native icon/legend placement and template symbol equivalents are implemented/tested. Stacked outer shadows, glow, masked inner shadows/highlights, bevels, state marks and whole-face blur are implemented with Pixel pixel/gesture/capture acceptance. Matching installed-skin hydration is now connected to the live controller (see acceptance below). Broader symbol coverage and full typography remain missing; native continuous corner curves are not exact. Authored Lux positions remain overlapping |
| Profile selection/default, orientation mutations, profile launch targets, capability/readiness display | ControllerClient, IOSContentView | Selection, cached default identity and native default/orientation/launch request generation implemented. Orientation mutations are capability-gated; launch is suppressed offline. Ordinary connected practice permits explicit launch, matching iOS. Offline default choices persist locally. 57 local tests pass; API 26 native action/menu checks pass. Rust orientation and launch execution are now installed on the normal Mac. Swift CLI launch routing passes all four selectors through the Rust authority; actual private app activation, key neutralization and missing-app recovery pass Android acceptance. Broader consumer/UI acceptance and attachment editing remain open |
| Local layout editing, offline pending edits and reconciliation, color preference | ControllerClient pendingKeypadLayoutEdits, IOSLocalKeypadUX | Missing; conflict/ack/restart tests required |
| Skin library/import/export/apply/detach/remove, .pocketpad sharing/review | IOSSkinLibraryView, IOSContentView, shared skin packages | Archive/store foundation implemented: bounded ZIP/ZIP64, payload integrity, duplicate JSON rejection, private atomic installation/version policy/exact export/removal and asset decoding pass JVM/API 26 tests with four existing native packages. Pure appearance stages now pass Swift-generated cascade/override/library/corner fixtures on JVM and API 26. Canonical-model compatibility and whole-profile application now match native fixtures. Strict appearance-model normalization is now integrated. Matching installed references now resolve and hydrate in the live controller on a worker, with safe saved-appearance fallback and cache invalidation. Apply/reapply/detach and atomic pending selection persistence now match native transition fixtures; basic import review and profile-menu actions are implemented and exercised offline. Full manifest/profile normalization, system document navigation acceptance, full preview/library/share/remove UI and Rust receiver skin support remain missing; authenticated incoming package installation is now implemented (see latest acceptance); full native renderer acceptance is still open; no publishing or approval implied |
| Shared build deep links, preview/keep, pending artifact store, practice preview, Mac adoption and retry/cancel | IOSBuilderArtifactPickup, IOSPendingBuilderArtifactStore, IOSContentView | Missing; shared artifact validation/adoption contract must match |
| Onboarding, connection/settings navigation, error recovery | IOSContentView | Minimal connection screen; native Android flows and full screen/device QA required |
| Transport v3: UDP auth/mirroring/fallback, generation/sequence safety and neutralization | ControllerClient, Rust/native receivers | Physical Pixel + Mac real-keyboard UDP/drop tests pass; advanced native gestures → Rust recording pass with UDP loss. Receiver pointer ordering now deduplicates relative deltas while preserving delayed reliable button releases |
| Release readiness: supported Android APIs/devices, permissions, network change, interruptions, packaging | Android manifest/toolchain + iOS feature inventory | Development SDK/target 35, min 26; wider device/API/accessibility matrix and release packaging pending |

## Evidence already present

- Android unit/device tests in app/src/test and app/src/androidTest.
- Native pointer input to normal Mac: scripts/verify-real-keyboard.py.
- Controlled packet loss: --drop-udp; direct Wi-Fi UDP: --require-udp.
- Packet-loss evidence: app/build/evidence/udp-drop/.
- Rust protocol/core/host/CLI and consumer regressions: 568 passing tests at UDP rollout.

Do not mark a row complete from a parser/unit test alone when it requires device UI,
rendering, persistence, or Mac output evidence. No full-parity completion is claimed.

## Latest verified milestone (2026-10-19)

- Build and lint complete (zero lint errors; existing toolchain/icon/backup warnings remain).
- 43 unit tests pass, including geometry, layer/override ownership, icon/legend placement, artwork normalization/blend math, native style inheritance/palette/scales, advanced gestures and wire streams.
- Pixel full suite: 33 methods, 29 exercised; four optional live methods skip without pairing data. The final icon/artwork class passes five methods, including an additional independent legacy surface golden (34 combined methods / 30 exercised). All seven asset/style methods pass expanded EXIF/adjustment coverage. Renderer acceptance includes pixel assertions for shapes, alpha, gradients, all tile patterns, rotated hit insets, and forced-theme hold retention; visible controller captures cover both orientations and canvas color schemes.
- Renderer evidence: app/build/evidence/renderer/renderer-result.json, four PNG captures and renderer-motion.mp4. Asset/style evidence: app/build/evidence/assets/asset-style-result.json and visible normal/pressed PNGs. These do not prove full skin or release performance parity.
- Latest normal Mac real-input regression passes with the icon/artwork build: 2 UDP + 10 WebSocket inputs, exactly six AppKit key events, 25 UDP datagrams dropped including all three releases; no held keys.
- Icon/artwork evidence: app/build/evidence/icons-artwork/icon-artwork-result.json and four visible controller captures. Legacy compositing is forced-path verified on the Pixel, not a claim of actual older-device or release performance acceptance.
- Advanced live test separately passes against a private recording-only Rust receiver: joystick/trigger keyboard bindings, analog output/neutral, pointer move/scroll, left/right click, and WebSocket fallback. Exact edge counts prove mirrored input is not executed twice.
- Controlled advanced UDP loss: 4 UDP inputs + 22 WebSocket inputs; both digital holds release, analog values return to neutral, no expired holds or stuck input. Evidence: app/build/evidence/advanced-rust-drop-result.json.
- Current Rust protocol/core/host regression suite: 368 tests pass (socket tests require local network access).
- Live normal Mac recovery test separately passes service-only QR pairing, Keystore reload,
  native Bonjour discovery after a stale saved endpoint, and decoding all five profiles.
- Final retained-session build passes real keyboard UDP-loss test: 2 UDP inputs + 9
  WebSocket inputs, exactly 6 AppKit keyboard events, 24 datagrams dropped including
  all 3 release frames; no held inputs at end.
- The normal receiver now includes the pointer ordering fix. Post-upgrade real-keyboard UDP-loss test passes again: 2 UDP + 9 WebSocket inputs, exactly six AppKit key events, 24 dropped datagrams including all three releases.
- Actual Mac configuration and all five profiles remain unchanged. Its receiver remains input-enabled with Accessibility trusted and no held inputs. Backup/install receipt: build/AndroidReceiver/advanced-install-receipt.json.

Next acceptance area: physical-device pointer output, actual HID consumer output and broader gesture/device
coverage. Next implementation area: broader symbol coverage, installed skin resolution, renderer/skin fidelity and editing,
calibration, artifact, settings, onboarding and device acceptance rows above.
This milestone does not complete the full iOS parity goal.

## Effects acceptance (2026-10-19)

- Full physical Pixel suite passes 39 methods: 35 exercised, four optional live tests
  skipped without pairing parameters. All five effects methods pass, covering shadow
  alpha chaining and outsets, masked inner effects, state marks, premultiplied blur,
  unchanged logical hit geometry and four simultaneous pressed faces.
- Shadow arrays now preserve the shared model's 96-point radius/offset budget;
  scalar effect budgets remain distinct. Pixel assertions cover authored offsets
  above 64 and clamping at 96.
- Normal and pressed captures were inspected in app/build/evidence/effects/.
  The visible fixture runs in offline practice mode and sends no input.
- Real Mac keyboard UDP-loss rerun passes with exactly six AppKit events, overlapping
  holds and complete releases: two UDP + ten WebSocket inputs, 24 dropped datagrams
  including all three releases. The first attempt failed its strict AppKit assertion
  because an extra key-down preceded the test sequence; it is retained separately.
- Whole-face blur uses a premultiplied three-box Gaussian approximation. Exact
  native blur/kernel/color comparison, actual older devices and release performance
  remain unverified. Raster/cache budgets do not substitute for performance acceptance.

## Trackpad accessibility capture follow-up (2026-10-19)

Native iOS ends an active trackpad gesture before its accessibility Click or Right
Click action. Android now retires that trackpad's physical captures, emits only the
requested click pair, and refreshes the pressed face for either action. Other held
controls remain active. Retired fingers stay suppressed until lift; a fresh touch
can start a new gesture.

All 45 local unit tests pass; debug app/instrumentation builds and lint pass. New
unit coverage exercises two-finger retirement, no post-action movement/tap, another
button's retained physical identity, fresh touch recovery, and explicit clicks with
physical tap/scroll disabled. The native-view regression compiles but has not run:
Pixel is reserved by another chat. This is not physical-device or real Mac pointer
acceptance; those gates remain open.

## Runtime asset contract correction (2026-10-19)

The earlier "vector display lists" gap was unsupported by the current native model.
`ThumbleVectorCompiler.compileSourceAssets` and `compileCanvases` turn sanitized SVG
into bounded PNG data. `GamepadAsset` carries image bytes; `GamepadImageFillView`
decodes platform images. These paths define no runtime vector display-list payload.
Android already decodes the resulting raster bytes. Installed package validation,
asset hydration, skin resolution and full skin fidelity remain required; this
correction does not mark those rows complete or remove any iOS feature requirement.

## Haptic implementation follow-up (2026-10-19)

Button activations and completed trackpad clicks now queue feedback after input
callbacks. Additional fingers on an already engaged button do not replay activation
feedback; movement, release, cancellation and heartbeat do not generate feedback.
Accessibility clicks follow the same output ordering. Haptic styles resolve from the
native baseline, applicable token and inline visual style, then explicit layout
feedback/style. All six styles and four patterns normalize to shared scalar bounds.

The API 26+ Android output uses bounded amplitude waveforms, touch usage attributes,
the system haptic setting and view visibility/focus guards. Zero intensity, focus
loss, detach, cancellation and replacement retire pending/active feedback. Sharpness
uses a transient envelope approximation; actuator frequency/Core Haptics equivalence
and physical feel remain unverified. Non-amplitude actuators retain timing with the
platform's default strength.

All 51 local tests pass; app and instrumentation builds plus lint pass. Two added
native-view haptic methods compile with a fake actuator but have not run while the
Pixel is reserved. Real motor behavior, tactile comparison, broader device coverage
and persistent in-app global intensity settings remain open. Evidence receipt:
app/build/evidence/haptics/haptics-result.json.

## Persistent haptic settings acceptance (2026-10-19)

This follow-up supersedes the earlier pending native routing and intensity settings
gates. Off/25/50/75/100% are available from Settings on the connection screen and in
the controller profile menu. The local preview disables at Off. Normal app storage
retains intensity across reload and forgetting a Mac; changing practice mode keeps
the value. Failed saves keep the previous selection and expose an error. Settings
changes do not send a Mac configuration mutation or retire an otherwise live input
surface; opening the modal releases any existing touches.

- 53 unit tests pass; full Pixel suite passes 44 methods, 40 exercised/four optional
  live skips. This includes the formerly pending trackpad accessibility method and
  four haptic routing/lifecycle/persistence/failure methods.
- Portrait light-mode settings were inspected; native dialog and selection motion
  were reviewed from the recorded walkthrough. 25% persisted in real app storage,
  Off disabled Test Haptic, and the original 100% level was restored.
- The Android vibration service recorded completed TOUCH effects for the normal
  app preview, including 0.18 peak amplitude at 25% of the 0.72 preview strength.
  This establishes OS submission, not tactile or physical waveform equivalence.
- `.argent/flows/thumble-haptic-settings-final.yaml` passes one uninterrupted replay
  (17 non-echo steps). It requires the saved trusted Mac reachable on Wi-Fi,
  disconnects before local settings, and restores 100%. Its first connected-screen
  idle gate warned because transport counters change; Disconnect was a stable
  target. Subsequent disconnected/settings idle gates passed. All taps use stable
  text/IDs after replacing ambiguous recorded radio targets.
- Evidence: app/build/evidence/haptic-settings/settings-result.json, settings-25.png,
  settings-off.png, settings-motion.mp4 and motion-review.png. Generated evidence is
  ignored build output; the reusable flow is under .argent/flows/.
- Dark mode, landscape, large fonts, the controller-menu entry, actual older APIs,
  tactile comparison, Mac pointer/HID consumer acceptance and release performance
  remain open. The normal Mac is input-enabled, Accessibility-trusted, disconnected
  and has no held input. Pixel-scoped services stopped and phone released to the
  waiting chat after verification.

## Profile action implementation (2026-10-19)

Android retains `defaultGamepadProfileID` from authoritative snapshots and private
saved-profile storage. The profile menu marks the default and can request a new
one using both native ID fields. Orientation requests require the advertised
`gamepad_profile_orientation_preference_mutation` capability, a valid changed
preference and a live connection. They release the retired input surface and wait
for the host snapshot before changing the profile. Launch requests contain only the
selected profile ID and are suppressed offline. Ordinary connected practice still
permits explicit launch. Paths and
bookmarks are never added to the request. Host rejection text is now shown rather
than replaced by a generic pairing message.

All 57 local tests pass; app/instrumentation builds and lint pass. Four native
methods cover actual client WebSocket requests/authoritative replies, cache reload
and the offline menu, and pass in the isolated API 26 emulator. The physical
Pixel was left untouched during this milestone. The isolated API 26 emulator
completed a direct SDK boot after the Argent readiness-wrapper failure; see below.

At that initial UI milestone, the installed Rust receiver supported default-profile
mutation but advertised no orientation capability and only logged launch diagnostics.
Android's native-compatible launch request does not establish Rust launch output.
Rust orientation/launch support, host-failure/UI feedback, live acceptance and
broader profile readiness remain open work.

## API 26 acceptance follow-up (2026-10-19)

A dedicated `thumble-parity-api26` arm64 AVD avoids contention with the physical
Pixel. The SDK direct launch passed boot completion and actual frame checks after
Argent's wrapper failed its shell `awk` readiness command and terminated its own
attempt. No other app/device state was used or changed.

The minimum-API suite exposed both a platform EXIF fixture-writer failure and an
actual orientation-read failure in the app. The test now builds standard APP1/TIFF
orientation data independently; `AssetImages` uses cached AndroidX EXIF 1.4.2 rather
than the version-specific framework parser. The eight orientation/dimension/corner
assertions all pass on API 26. Source reference:
[AndroidX EXIF release notes](https://developer.android.com/jetpack/androidx/releases/exifinterface).

Final profile behavior preserves iOS's distinction between practice input suppression
and control-plane actions: a connected practice session may explicitly launch its
attached Mac target; offline launch/orientation writes are disabled. A saved offline
default can be changed locally without changing selection or opening a connection.
Connected values still await authoritative snapshots. The offline menu was inspected
and its disabled indicators/neutral surface corrected. Screenshot capture now waits
for UI idle and verifies the foreground app identity; an earlier launcher frame was
rejected as evidence. Broader menu motion/theme/geometry acceptance remains open.

Final API 26 suite: 47 methods, 43 exercised, four optional live skips; the API-29-only
compositor comparison is excluded by its SDK annotation. All 57 unit tests, app/
instrumentation builds and lint pass. Four profile methods verify native client
payloads and authoritative replies, local offline defaults, private cache reload and
the offline menu. The synchronized menu capture was inspected after the final run.
Evidence: app/build/evidence/profile-actions/profile-actions-result.json and
profile-actions-offline-api26.png. The isolated emulator was shut down cleanly; its
AVD remains available for subsequent acceptance work. No normal Mac profile or
physical Pixel state was modified in this milestone.

## Rust orientation protocol acceptance (2026-10-19)

The Rust source receiver now advertises and accepts orientation mutations. It
validates authentication/envelopes and installed IDs, preserves all layout/binding/
unknown fields, increments revision only on change and returns full authoritative
state. Active-profile changes retire held input/generation; inactive changes retain
active holds. Unchanged/stale-ID requests return state without writes. Fault-injected
save failures restore configuration, release input and never acknowledge unsaved
orientation. UDP configuration requests remain rejected.

The Android API 26 client passed its optional real-Rust method through
`scripts/verify-profile-actions.py`: default update plus portrait/landscape/automatic,
exactly four configuration revisions, unchanged selection/layouts/bindings and no
held output. The receiver had real input disabled and used temporary state/socket
paths. No normal Mac profiles, installed receiver files or Pixel state were changed.
The verifier's initial evidence check assumed a revision field in an unnormalized
fixture; it now checks the authoritative pre-test status revision and the strict
rerun passes. The Android method itself completed on both attempts.

Rust protocol/core/host: 375 tests pass, including CLI orientation planning and
socket/persistence-failure cases. Strict Clippy is blocked by pre-existing
`chunks_exact_to_as_chunks`, `useless_conversion` and `unnecessary_unwrap` findings in
unchanged files; the strict rerun excluding only those categories passes. Android
instrumentation build/lint pass. Broader UI acceptance, normal receiver deployment,
application launch, physical pointer/HID and the remaining parity rows stay open.
Evidence: app/build/evidence/profile-actions/rust-profile-actions-result.json.

The direct shared-core consumers also pass 73 tests (receiver, CLI bridge, MCP).
Formatting checks pass on changed Rust files. Scoped emulator services were cleaned
up and the emulator shut down gracefully. The source receiver's full receipt is
app/build/evidence/profile-actions/rust-orientation-acceptance.json; normal receiver
installation and application launch are still pending.


## Real Mac pointer acceptance

`verify-advanced.py --real-pointer` now uses a private input-enabled instance of
an Accessibility-trusted installed Rust binary and a focused AppKit probe. The
probe accepts only that receiver process's events; it installs no global monitor.
The API 26 emulator dispatches native trackpad MotionEvents and verifies the exact
application sequence: movement, left click, scroll, right click, fallback left
click, and held-button drag followed by cancellation/release. The drag button
hold is explicit client transport input, not a new profile binding or tap-and-drag
gesture; native iOS also has no standalone pointer-button profile binding.

Healthy UDP and controlled UDP-loss runs both pass. Loss begins after the two
independent joystick/trigger downs; subsequent pointer actions recover through
WebSocket. Both end unpaired with zero held keys/buttons and no expired holds.
Source/binary hashes and process-filtered application events are retained in
`app/build/evidence/advanced-real-pointer*-result.json`. The normal Mac receiver,
its profiles and installed binary are unchanged. This does not establish physical
Android pointer UX, real gamepad consumer support, or release readiness.


## Rust application-launch acceptance

The Rust Mac runtime now executes Android's existing Launch action against the
Mac's installed target only. It preserves native bookmark/path/bundle resolution,
releases input before activation, keeps the session on failure, and exposes a
queued/completion status plus matching `thumble-host launch-profile` command.

`verify-application-launch.py` runs a private input-disabled receiver and disposable
Mac app. API 26 Android acceptance covers path, same-identity security-scoped
bookmark, foreign-bookmark path fallback, bundle-ID lookup and missing application.
Success requires the fixture to record actual activation and exit, with the client
still paired and its pre-launch recorded key released. Missing-app failure keeps
that hold until normal client disconnect. Profiles/revisions are unchanged.
The local Rust CLI's launch/activation is independently checked.

Evidence: `app/build/evidence/profile-actions/rust-application-launch-result.json`,
including source/binary/APK hashes. Rust host and direct consumer regressions pass
389 tests; Clippy passes with only the three previously documented baseline lint
categories excluded. The Android instrumentation APK builds. The normal installed
receiver and Swift `thumble profile launch` route have not been updated in this
milestone; attachment editing and the broader parity inventory remain open.


## Installed launch/orientation and standalone CLI routing

The normal receiver now includes Rust orientation mutation and attached-application
launch support. `thumble profile launch [NAME|UUID|active|default] [--json]` sends a
bounded typed selector through the exact sibling CLI bridge. Selection resolves
inside the running host's lock, using the existing safe catalog matcher. A caller
cannot send an application path, bookmark or bundle ID through this command. The
CLI reports queueing and a launch UUID; host status reports completion/failure.

All ten isolated cases pass: four standalone Swift CLI selectors, one direct Rust
CLI launch and five Android target/success/failure cases. Fourteen Swift routing
tests, 27 stack-safety tests including a new launch decoder/size budget, and 390
Rust host/bridge/MCP/gateway tests pass. Clippy passes with the existing three
baseline categories excluded.

The update backs up all four installed binaries and private state, preserves
profiles/trust and port/Bonjour/input/configuration-write settings, and rolls back
binaries on failure. Normal setup checks retained all five profiles and
Accessibility permission. Post-install emulator → real Mac keyboard UDP-loss
acceptance passed: 2 UDP + 9 WebSocket inputs, exactly six focused AppKit key events,
24 dropped datagrams including all three releases, no held input. Non-trust
configuration remains equal as decoded JSON after the test; pairing
may update trusted-client records.

Evidence: `app/build/evidence/profile-actions/rust-launch-routing-acceptance.json`
and `build/AndroidReceiver/launch-install-receipt.json`. This supersedes the earlier
source-only installation/routing caveats. Full Android parity remains open in the
inventory above.


## Android skin archive and library foundation

`PackageArchive`, `PackageJSON`, `SkinPackageCodec` and `SkinLibrary` provide the
package-loading/storage boundary. The reader uses the central directory, stored or
raw-deflate payloads, UTF-8/CP437 names and bounded single-disk ZIP64 metadata. It
checks safe paths, duplicate entries, unsupported entry types, local headers,
entry overlap, CRCs, compression ratio and the native 40 MiB archive / 10 MiB entry /
50 MiB expanded / 256-entry budgets. Strict JSON rejects duplicate escaped keys,
invalid UTF-8, non-finite numbers, trailing data and excessive nesting. Manifest
identity, content kinds, resource descriptors/hashes, compatibility declarations,
and common asset/style references are checked.

The file-backed library preserves raw archive bytes, uses hashed physical identity
components, rejects symlink redirection, atomically replaces private files, and
supports native install-policy ordering, reload, exact export, latest-version
lookup and removal. Listing retains summaries rather than every decoded package.
Layouts/packs remain inert; this API does not adopt a profile or execute a binding.

Twelve new package unit tests bring the JVM suite to 69 passing tests. Two API 26
device methods pass with the existing Solar Sumi, Foldline Relay, Indigo Pocket and
Tideglass Field archives. They verify persistence/reload/exact export/removal,
corrupt replacement recovery, strict Android JSON, legacy CP437 names and real PNG
decoding through `AssetImages`. Builds and lint pass. The existing package assets
were used unchanged through test-only Gradle resource roots; no skin was authored,
modified, approved or published.

Evidence is in `app/build/evidence/skin-packages/acceptance.json` and
`device-result.json`, with source/APK/archive hashes and retained logs. This is the
archive/store foundation. Full native semantic normalization (including all nested
skin/profile/captured-presentation fields), locale-sensitive version/name sorting,
compatibility and appearance resolution, asset hydration into live profiles,
package transport sync and library/import/share UI remain open. No full skin
support or Android parity completion is claimed.


## Skin appearance cascade and native oracle

`SkinAppearanceResolver` adds pure stages for orientation/theme/action-set variant
selection, native specificity/ID ordering, default/role/button rules, whole-token
style replacement, baseline-aware local appearance and library overrides,
packaged asset materialization and referenced image hydration. Corner handling
matches native static defaults, dynamic silhouettes, nonnegative unbounded radii,
per-corner precedence and shadow bounds. Resolved JSON owns its nested values;
editing a preview does not change an installed package or saved local appearance.

The expected outputs come from the actual Swift resolver, using four unchanged
Website packages plus synthetic engine test data. JVM and Android API 26 run the
same independent structural comparisons: 80 appearances, 560 control cascades,
80 local/baseline/library cases and 192 corner/silhouette edge cases. These tests
caught and corrected a dual-corner precedence bug. The JVM suite now has 73
passing tests; all three API 26 oracle methods pass. Debug APKs, lint and the full
Swift stack-safety script pass. Fixtures and regeneration commands are under
`Host/fixtures/skin-resolution/v1`; retained evidence is under
`app/build/evidence/skin-resolution`.

This module is not connected to live profiles yet. The following milestone adds
compatibility and whole-profile traversal over canonical models. Full nested
semantic normalization, live integration, sync and library/import/share UI remain open. The synthetic image bytes are intentionally non-renderable test data;
no new skin artwork was authored, reviewed, approved or published.


## Canonical whole-profile skin resolution and compatibility

`SkinProfileResolver` applies the verified appearance stages to a complete canonical
customization: keypad background/accent/labels, declared built-in controls, custom
controls and their element mirrors, the top-bar activation region and control-bar
items. Package and local libraries merge before asset hydration. Saved geometry,
identity, input bindings, advanced-control settings and presentation metadata remain
unchanged. Asset hydration visits appearance fields only; opaque future element
metadata that resembles an image fill is preserved. Native kind constraints remain in force (including text shadows and
joystick silhouettes); spacer appearance stays constrained by the native bar model.

`SkinCompatibility` implements orientation/aspect/required-role checks, canonical
template identity/revision matching, degraded unknown-template behavior and exact
captured-controller geometry checks. Incompatible/degraded aligned skins suppress
aligned artwork/background while semantic control styling remains available. The
captured contract includes the native system toggle, visible control identities,
kind/position/size/optional rotation, bounded safe-area/canvas/control records and
presentation validity. `SkinCanvas` matches all 68 canonical native canvas IDs;
raw alias/model normalization remains part of the unfinished decoder work.

The Swift-generated profile oracle covers 86 full resulting profiles, 21
compatibility/gating cases, visible geometry for 22 fixture layouts and all 68
canonical canvases. Separate assertions verify unchanged element identities,
labels, bindings, advanced settings, presentation and saved JSON. A template
revision above 32-bit range verifies native 64-bit ordering. The complete JVM suite
passes 76 tests, the combined profile/appearance API 26 suite passes six methods,
and debug builds, lint and the Swift stack-safety script pass. Evidence is under
`app/build/evidence/skin-profile-resolution`; regeneration/provenance is documented
with `Host/fixtures/skin-resolution/v1/native-profile-oracle.json`.

This is the render-only engine over canonical validated models. Full nested model
normalization, live controller/library integration, skin apply/detach persistence,
transport synchronization, import/share UI and renderer/physical-device acceptance
remain open. The normal Mac receiver was not changed by this milestone.


## Strict appearance decoding and portable native text

`SkinModelCodec` now decodes and normalizes skin appearances before package
validation and storage. It validates nested fields before discarding duplicates
or empty variants/tokens, preserves native optional/null/default semantics, and
normalizes control states/content, icons, haptics, solid/gradient/tile/image fills,
legacy colors, shadows, artwork frames and style libraries. Image byte caps,
nine-slice fallback and Foundation-compatible Base64 behavior are covered. The
appearance resolver delegates to this decoder instead of maintaining a partial
normalizer. Base action-set style references now use the actual native cascade.
Applied layouts also clear native default haptics and default joystick appearance.

`SkinText` replaces platform-dependent grapheme counting and character categories.
Native-generated tables give consistent truncation of joined emoji, flags,
combining marks and Indic sequences on API 26. Tests compare 1,859 grapheme inputs
with actual Swift results and compare alphanumeric/control/whitespace membership
over the entire Unicode scalar domain. The native runtime has known differences
from both Unicode conformance input versions; these are recorded rather than
silently substituted with a different standard. Sources, licenses, hashes and
regeneration commands are under `Android/unicode`.

The model oracle has 394 cases (171 accepted, 223 rejected), including malformed
nested records, padded binary data and unpaired JSON surrogates. Package JSON
rejects malformed surrogate sequences. All four unchanged Website package skin
models match the native decoder output. A malformed appearance cannot replace an
installed archive; raw archive export remains exact. Existing appearance and
whole-profile/native-geometry oracles still pass. The JVM suite now passes 83
tests; the combined API 26 skin suite passes all 13 methods. Debug builds, lint and
the required Swift stack-safety script pass. Evidence is retained under
`app/build/evidence/skin-model-normalization`.

This completes the checked appearance decoding boundary, not full package/profile
semantic normalization or Android parity. The captured-contract extension below covers typed captured metadata. Manifest
metadata and profile decoding/normalization, locale-sensitive version/name ordering, live
skin integration, persistence/sync/UI and the broader renderer/device/release
matrix remain open. Normal Mac receiver binaries and configuration were not changed.


## Strict compatibility and captured-contract decoding

`SkinContractCodec` now decodes the complete typed compatibility/captured model
before package validation: required/optional fields, enums, integers, UUIDs,
control presentation, native hit geometry, state/surface samples, chrome/container
paint, layout matrices and their requested/resolved appearance evidence. Unknown
fields follow native Codable behavior; presentation rejects unknown fields.
Captured evidence values retain native raw semantics, while nested fill decoding
and custom encoders apply their native normalization. Core Graphics rectangle
arrays consume the native coordinate values and ignore allowed trailing values.

Package loading follows native archive-decoder phase order: compatibility ranges,
revision bounds, empty requirements and duplicate declarations normalize before
semantic package validation. This differs from native authoring validation of raw
source inputs. The runtime reuses the same presentation validator. Canonically
equivalent JSON keys are rejected as duplicates; template/control identity checks
and runtime template matching use canonical string keys without case folding.

Native fixtures cover 217 contract inputs: 56 accepted models, 161 decode
rejections and 49 accepted packages after normalization/validation. Complete model
outputs and package acceptance match Swift. Additional checks cover composed and
decomposed keys, actual rich captured paint, raw evidence values, rectangle array
shape rules and malformed replacement imports retaining the exact prior archive.
The complete JVM suite passes 87 tests, and the combined API 26 skin suite passes
all 17 methods. Debug builds, lint and the required Swift stack-safety script pass.
Evidence is retained under `app/build/evidence/skin-contract-decoding`.

Full manifest metadata normalization (including URL and locale-sensitive behavior),
profile decoding/adoption, live skin integration, apply/detach persistence, sync,
library/import/share UI and broader renderer/device/release acceptance remain open.
NFC comparisons are checked against native equivalent-key fixtures; broader
normalization-version coverage remains part of the runtime matrix. The normal Mac
receiver and unrelated running emulator were not changed.

Canonical-equivalence handling for style/variant/artwork/asset/library identities
and ZIP paths still needs migration and native regression coverage beyond the
contract/template/JSON-key checks added here. Asset-library metadata normalization
also remains separate from the completed appearance model decoder.


## Live installed-skin rendering

The controller now resolves the selected profile's exact installed skin reference
on a worker, then passes the hydrated appearance projection to the existing
native Android surface. The input client and saved profile retain their original
IDs, bindings and JSON. Orientation-specific override baselines fall back to the
primary baseline; the primary color-scheme preference applies to both orientations,
matching iOS. One decoded package and one projection bound the cache. Failed or
mismatched versions fall back to the saved appearance with a visible explanation.

A new resolution request waits before enabling the surface, so a touch cannot
start against an appearance that will immediately be replaced. Library owners
can invalidate the renderer after installation/removal; invalidation does not
wait for an in-flight archive decode on the UI thread. Ordinary recompositions
reuse the projection and retain existing touches. This is not a claim that an
actual skin/geometry replacement preserves a hold; surface replacement still
retires captures safely. Live action-set switching remains separate work.

All 90 JVM tests pass, including 44 native-generated profile projections covering
orientation, forced scheme and primary/orientation override baselines. The API 26
combined skin/asset suite passes 25 methods. A real MainActivity test installs the
unchanged Solar Sumi package privately, displays its semantic styling, compares
the activity pixels with the resolved surface and the raw saved layout, preserves
a hold through a settings recomposition, verifies release and unchanged saved
JSON, and refreshes after removal/reinstallation. Its canonical template lacks
roles required by the package: compatibility correctly gates aligned artwork and
shows a warning. The retained portrait capture includes overlapping authored
Coin/Start geometry; it does not establish native pixel fidelity or complete skin
rendering acceptance. The test restores the prior library state.

Debug app/test builds, lint and the required Swift stack-safety gate pass.
Evidence: `app/build/evidence/skin-live/`. Library/import/share UI, apply/detach
persistence, Mac package synchronization, full manifest/profile normalization,
global style/asset identity normalization and broader renderer/device/release
acceptance remain open. No skin artwork was authored, published or approved.

The normal Mac keyboard UDP-loss regression also passes: two UDP inputs and nine
WebSocket inputs, exactly six AppKit Q/W events, all three release frames dropped
on UDP and delivered through fallback, and no held input at completion. A prior
strict-probe run observed an additional J down/up before the requested sequence;
its failure evidence is retained separately rather than counted as a pass.
The Mac receiver binaries and profile configuration were not changed.


## Skin application, detachment and pending selection persistence

Android now applies skins to the primary and present orientation slots, records
replacement baselines, preserves edits relative to an existing baseline, and
dehydrates only matching package-owned image bytes. Detachment materializes the
currently resolved appearance before removing the reference/baselines; unavailable
packages follow native saved-appearance fallback. Bindings and caller-owned JSON
are preserved. Apply/detach use the same primary theme preference as live rendering.
The native transition oracle compares 44 complete profile results across initial
application, reapplication, package switching, local edits, both schemes, explicit
variants and matching/mismatched/missing-package detachment.

A private atomic profile file now stores the snapshot and pending skin selections
together. Ordinary snapshot saves retain the journal. Last intent wins per profile;
restart retains intent, failed writes keep the prior visible profile/input revision,
and an unreadable journal cannot be silently overwritten. Explicit forgetting
clears the journal. The client uploads package bytes before skin selection when
capabilities permit, retains intent until a matching authoritative profile array
arrives, and replays unacknowledged choices on reconnect. Legacy scalar layout
messages cannot acknowledge a locally retained reference. Server ownership guards
prevent an intent bound to another Mac from being uploaded/acknowledged. New
connections clear old capabilities, and unsupported hosts retain pending intent
without receiving unsupported requests. Oversized uploads remain local with an
error; this does not establish large-package transport parity.

The profile menu exposes document import, installed-skin application and detach.
A native metadata review can cancel without installation; confirmed import installs
the exact archive without applying it or adopting profile bindings. File reading,
archive validation, lifecycle computation and large archive/manifest copies run
off the UI thread. Preparing a skin retires the input surface until commit.
The import review and offline menu journey are exercised through native
accessibility actions on API 26, including installation, apply/detach, retained
last intent, unchanged identity and zero outgoing input. The test feeds document
bytes through the SAF-result worker; actual system document-provider navigation
remains unverified. Captures are light/portrait; dark/landscape/large-font and
motion acceptance remain open. This is basic import/menu UI, not the complete
iOS skin library/preview/share/remove experience.

The normal Rust receiver explicitly rejects skin-package and skin-selection
messages. Android capability gating and mock-WebSocket acceptance do not establish
working Mac skin synchronization. Incoming package installation, receiver-side
skin support and its CLI path still need implementation and real Mac acceptance.
Full manifest/profile normalization, global style/asset identity normalization,
preview/share/removal, release performance and full Android/iOS parity remain open.
No skin artwork was authored, published or approved by this work.

Final verification for this milestone: all 93 JVM tests pass; the combined API 26
suite reports 36 methods (34 exercised, two optional live-Rust methods skipped
without their pairing parameters). App/test APK builds, lint and the required
Swift stack-safety gate pass. Completed import/applied/detached captures were
inspected. The separately supplied normal-Mac keyboard UDP-loss test passes with
two UDP plus nine WebSocket inputs, exactly six AppKit Q/W events, 24 dropped UDP
datagrams including all three release frames, and no held input at completion.
No receiver binary upgrade was required or performed. Evidence is under
`app/build/evidence/skin-lifecycle`.


## Authenticated incoming skin packages

The Android client now handles `skinPackages` on validated initial handshakes,
profile/customization updates and standalone `skin_packages` messages. Native
Foundation-compatible typed Data validation precedes profile acceptance. Unpaired
messages and wrong server identities cannot enqueue an installation; malformed
Data cannot commit an accompanying profile snapshot. Archive validation/storage
run on the skin worker with native allow-downgrade/same-version replacement
policy. One corrupt archive preserves the prior copy and does not prevent other
valid archives in that batch from installing. Package profiles remain inert.

The worker backlog is bounded by whole-message byte charges and job count.
Overload retains trusted reconnect and requests replay instead of silently losing
a valid batch. Initial skin-backed profiles wait for their embedded batch before
accepting touches. Exact resyncs and unrelated package updates retain the current
physical hold; active replacements retire it safely. Changes to inactive packages
also invalidate the decoded cache, so selecting/resolving them later uses the new
package. Standalone package-only messages do not retire the input graph.

All 97 JVM tests pass. The combined API 26 suite reports 40 methods (38 exercised,
two optional live-host methods skipped). Four new native device methods cover
real MainActivity + mock WebSocket delivery, embedded/standalone archives, held
input on the wire, replacement neutralization, inactive cache refresh, identity
rejection, malformed Data/profile atomicity and queue backpressure recovery.
Build/lint and the required Swift stack-safety gate pass. Evidence is under
`app/build/evidence/incoming-skin-sync`. This verifies Android-side synchronization
against a controlled host, not real Mac skin sync.

The normal Rust receiver still rejects these skin messages. Receiver-side store,
selection/removal and CLI routing need implementation and real Mac acceptance.
The existing pure Swift configuration bridge already decodes native packages and
invokes native skin application for reviewed design transactions; it is the
existing seam to extend for ordinary runtime skin operations, rather than
reimplementing the skin model independently in Rust. Ordinary runtime operations
must remain separate from design-review/approval metadata. System document-picker
acceptance, full preview/share/remove UI, manifest/profile normalization and the
broader renderer/device/release matrix remain open. Full Android/iOS parity is
not complete; no artwork was authored, published or approved.

The separate normal-Mac keyboard UDP-loss regression also passes: two UDP plus
nine WebSocket inputs, exactly six AppKit events, 24 dropped UDP datagrams
including every release frame, and no held input. The final combined device
run includes the observed wire release counts and replacement archive hashes.
No normal receiver binaries or profile configuration were changed for this work.
