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
| Orientation preferences and variant selection, uninterrupted rotation, calibration | GamepadOrientationCoordinator, ThumbPlacementCalibrationView | Native locks, variant selection and rotation without activity recreation implemented/tested on Pixel. Thumb capture, per-device/display/profile/orientation persistence, scoring, explicit repair acceptance and editor Undo are implemented; API 26 trace/estimate/cancel/save-failure and private Rust acknowledgement/restart acceptance pass. Physical ergonomic/device geometry acceptance remains open |
| Buttons, element parts, per-touch hold/slide/release behavior | TouchCaptureView, ControllerClient | Buttons and canonical joystick/trigger parts implemented; Pixel mixed holds, capture, cancellation, accessibility actions, and Rust recorded bindings verified; broader geometry/device coverage pending |
| Joystick directions, analog sticks/triggers, pointer trackpad/move/scroll/click/drag | ControllerClient, shared keypad renderers | Implemented joystick capture/transforms, analog coalescing/refresh/neutral, trigger thresholds, trackpad movement/scroll/taps. Pixel native gestures → Rust recorder pass with direct UDP and mid-hold UDP loss; API 26 emulator → real AppKit movement/scroll/left/right clicks and receiver-level drag/cancel now pass healthy UDP and UDP loss. Physical pointer acceptance and actual HID consumer output remain pending |
| Haptics, control/accessibility feedback, keep awake, appearance/settings | IOSLocalKeypadUX, IOSContentView | Basic accessibility and keep-awake implemented. Button/trackpad haptic model, style cascade, activation routing and Android waveform output now implemented; 53 local tests and 40 exercised Pixel methods pass. Persistent five-level intensity settings and local preview are implemented/verified; tactile comparison, settings theme/geometry matrix and remaining feedback/settings remain open |
| Full renderer: element kinds, style tokens, layers/action sets, skins, vector/raster assets, fills, text, hit regions, dark/light | Shared skin compiler/resolver/renderers, ControllerClient | Native size/center/clamp rules, builtin override ownership, design layer order, all seven canonical shapes, per-corner radii, solid/linear/radial/tile fills, profile appearance, legend visibility and accessibility names implemented. Pixel pixel/gesture/portrait/landscape captures pass. Canonical raster asset references/inline data, fit/crop/tile/nine-slice modes, JPEG EXIF orientation, image adjustments, native token/inline state inheritance, core fill/foreground/border/opacity/scale and authored text fields are now implemented/tested. Passive artwork planes (including blend/rotation/opacity/order), text/raster icons, native icon/legend placement and template symbol equivalents are implemented/tested. Stacked outer shadows, glow, masked inner shadows/highlights, bevels, state marks and whole-face blur are implemented with Pixel pixel/gesture/capture acceptance. Matching installed-skin hydration is now connected to the live controller (see acceptance below). Control-specific font metrics, scaling floors, fixed authored sizes, absolute tracking, multiline alignment and grapheme-aware short labels now have API 26/Pixel acceptance. Captions and host-authoritative binding hints now have API 26/Pixel rendering, persistence, input-retention and real Rust/CLI acceptance (see below). Broader symbols and exact platform font designs remain open; native continuous corner curves are not exact. Authored Lux positions remain overlapping |
| Profile selection/default, orientation mutations, profile launch targets, capability/readiness display | ControllerClient, IOSContentView | Selection, cached default identity and native default/orientation/launch request generation implemented. Orientation mutations are capability-gated; launch is suppressed offline. Ordinary connected practice permits explicit launch, matching iOS. Offline default choices persist locally. 57 local tests pass; API 26 native action/menu checks pass. Rust orientation and launch execution are now installed on the normal Mac. Swift CLI launch routing passes all four selectors through the Rust authority; actual private app activation, key neutralization and missing-app recovery pass Android acceptance. Broader consumer/UI acceptance and attachment editing remain open |
| Local layout editing, offline pending edits and reconciliation, color preference | ControllerClient pendingKeypadLayoutEdits, IOSLocalKeypadUX | Per-profile System/Light/Dark choice, offline persistence, trusted-Mac reconciliation, active/inactive appearance sync with native orientation mirroring and restart acceptance implemented (latest sections). Durable generic layout editing, native orientation-aware replacement and recovered-profile adoption are implemented (latest sections). The visible editor now has emulator acceptance; real-Mac UI and installed-skin replay pass for built-in and grouped custom-button edits/deletion. Focus/resize/detach/cancel retirement, real Home/foreground recovery and rotation now have API 26 editor acceptance (latest sections); additional control kinds, broader interruptions, TalkBack and wider device/performance acceptance remain open |
| Skin library/import/export/apply/detach/remove, .pocketpad sharing/review | IOSSkinLibraryView, IOSContentView, shared skin packages | Archive/store foundation implemented: bounded ZIP/ZIP64, payload integrity, duplicate JSON rejection, private atomic installation/version policy/exact export/removal and asset decoding pass JVM/API 26 tests with four existing native packages. Pure appearance stages now pass Swift-generated cascade/override/library/corner fixtures on JVM and API 26. Canonical-model compatibility and whole-profile application now match native fixtures. Strict appearance-model normalization is now integrated. Matching installed references now resolve and hydrate in the live controller on a worker, with safe saved-appearance fallback and cache invalidation. Apply/reapply/detach and atomic pending selection persistence now match native transition fixtures; basic import review and profile-menu actions are implemented and exercised offline. A dedicated library, read-only current/package previews, apply/fork, outgoing share/save, guarded removal, document export/cancel and Back now have API 26 acceptance (latest section). External ACTION_SEND/ACTION_VIEW skin files now route to bounded import review with temporary content-URI grants; cold/warm opens, retained recreation, Import and Install & Apply have API 26 acceptance. Full manifest/profile normalization, Files-provider navigation, actual process-death restoration, bundled-library migration and wider UI/device coverage remain open. Authenticated package installation and real Mac receiver synchronization now pass physical Pixel acceptance (see latest section); legacy/bundled-library migration and full native renderer acceptance remain open; no publishing or approval implied |
| Shared build deep links, preview/keep, pending artifact store, practice preview, Mac adoption and retry/cancel | IOSBuilderArtifactPickup, IOSPendingBuilderArtifactStore, IOSContentView | Partial: pickup, protected store, native profile compatibility matrix, Practice Preview and Android-to-Rust adoption/retry/cancel with CLI replay are implemented and locally verified; production browser association and broader device/API matrix remain open |
| Onboarding, connection/settings navigation, error recovery | IOSContentView | Four-step native Android setup guide, durable completion, established-install migration, explicit replay, Back/skip/finish, and incoming-link bypass implemented. Pixel live/replayed navigation and API 26/Pixel persistence/recovery tests pass (see latest section). Cold first-run UI, full geometry/theme/permission and accessibility matrix remain open |
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

## Real Mac receiver skin synchronization (2026-10-19)

This acceptance supersedes the earlier receiver-skin-support gap. The Rust Mac
receiver now owns a private atomic archive library, delegates package inspection,
version policy and apply/detach to the native Swift bridge, and advertises skin
capabilities only after that subsystem opens successfully. Authenticated phone
messages run on a bounded worker; native decoding never holds the input mutex.
Profile changes recheck the configuration revision and current authenticated
connection, release captured input, persist atomically, then install and publish
the authoritative profile. Failed changes receive no false acknowledgement, so
the Android pending-selection journal remains intact. Import never adopts an
archive's embedded profile. Removal rejects packages referenced by a profile.

The primary `thumble skin` runtime commands route to this same receiver authority:
list/import/export/apply/detach/remove, with exact `identifier@version` selectors.
Import supports native newer-only, same-version replacement and explicit downgrade
policies. A stopped/unreachable Rust owner cannot silently redirect writes into a
legacy profile store. Existing pure authoring/validation commands remain native.
Receiver reference selection currently requires an explicit version; package-path
application should be performed as import followed by apply. Existing legacy
library/bundled-package migration and large-package transport remain separate work.
The receiver sync budget is 3 MiB per CLI archive and 4 MiB of Base64 library replay;
the existing 8 MiB wire frame limit still applies. This is not chunked transport.

The final physical Pixel 7 / API 37 run uses the actual staged Rust receiver and
Swift CLI/bridge over the LAN, with private Mac state and normal phone trust and
skin archives preserved. It verifies:

- Initial Mac-to-phone archive replay and a visibly rendered installed skin.
- Native phone import review, archive upload, apply and detach; the journal clears
  only after the real Mac commits and returns the authoritative profile.
- Byte-exact export from the receiver and unchanged profile identity.
- A CLI skin change reaching the phone, releasing a held native-view capture and
  leaving no pressed input in the receiver.
- Receiver restart, saved-token reconnect, archive replay and no pending selection.
- Invalid archive rejection preserving authority, and rejection of in-use removal.

The unchanged Solar Sumi and Foldline Relay packages are fixtures. The Productivity
layout does not satisfy all their captured artwork contracts: the visible warning
correctly gates incompatible artwork while semantic control styling renders.
This proves synchronization and safe rendering, not full skin pixel fidelity,
artwork approval, publication, actual system document-provider navigation or full
Android/iOS parity. No normal Mac receiver installation was replaced by this test.

Reproduce with `Android/scripts/verify-mac-skin-sync.py` and its explicit built host,
CLI, native bridge and CLI-bridge paths. Final device evidence is under
`app/build/evidence/mac-skin-sync/20261019-180518/`; earlier failed harness runs are
retained separately. The final native screenshots wait for rendered controls,
rather than capturing the loading transition. The Pixel was explicitly released
and this run's temporary external files removed after preserving evidence.

Final local gates for this integration pass: 97 Android JVM tests, app/test APK builds and lint; 635 Rust workspace tests plus both explicit native store/runtime acceptance tests; 539 XCTest plus three Swift Testing tests; and the complete Swift stack-safety verifier. The native runtime/store tests are also wired into the macOS packaged-release CI job.

## Pending Android appearance choices: persistence foundation (2026-10-19)

Appearance is a profile customization, following iOS. `AppearancePreferenceJournal` now represents System/Light/Dark choices,
keeps immutable recovery data, scopes each intent to its trusted Mac, and reapplies
only the appearance delta while retaining newer incoming Mac metadata. A matching
value from an authoritative snapshot acknowledges an intent; optimistic snapshots,
untrusted/different Mac identities, and invalid remote enum values cannot clear it.
Deleted profiles recover as an explicit Android layout copy. Recovery remains
pending until an authority accepts it.

Snapshot persistence can now atomically save both skin selections and appearance
choices. Existing snapshot/skin saves retain the appearance journal; corrupt
pending data fails loading instead of becoming an empty successful journal.
The ten new JVM cases cover reconciliation, identity gates, recovery, immutable
serialization, malformed records, and preservation across other saves. All 107
Android JVM tests, debug/app-test APK builds, and lint pass.

This is persistence/model groundwork. ControllerClient load/send/ack integration,
settings controls, live rendering, process-restart/device acceptance, and receiver
inactive-profile/orientation handling remain required before claiming the color
preference feature complete. The physical Pixel was not used. No Swift sources,
Mac receiver installation, profile data, or artwork were changed.


## Android appearance controls and active-profile synchronization (2026-10-19)

This extends the preceding persistence foundation. Keypad settings now exposes
System/Light/Dark with native Material radio controls. The preference governs the
keypad renderer and skin resolution for both orientations; app chrome retains the
system theme, matching the separation in iOS. Settings remain scrollable, support
Done and Android Back, and can be opened from connection or keypad options.

ControllerClient loads, saves and reconciles appearance intents with the skin
journal in one atomic profile-state write. A local change releases old captures
before rebuilding the surface. Reconnect reapplies the pending appearance delta
without discarding newer Mac metadata. Full-profile acknowledgements clear matching
intents; scalar acknowledgements are scoped to their own profile. Failed saves
preserve the previous value. If an echoed value cannot be persisted, the journal
remains pending without repeatedly uploading the acknowledged value.

Rust customization mutations now use the same persist-before-acknowledgement and
rollback protection as orientation mutations. A failed persistence regression
proves that previous authority survives and no profile/customization acknowledgement
escapes. No normal Mac receiver installation or state was changed.

Verification:

- All 108 Android JVM tests, debug/app-test APK builds, and lint pass.
- API 26 device cases cover real Android-store/client reload, skin-save coexistence,
  reconnect/echo, scalar ACK scoping, failed local saves and failed ACK persistence.
- The recorded settings walkthrough and corrected 39-step Argent flow pass, covering
  all choices, both settings entry points, Dark/Light rendering, Back/Done, and
  process restart. Two idle warnings are the blinking connection-address caret;
  subsequent destination/button checks pass. The recording is 30 fps QA evidence,
  not a release-performance/60 fps measurement.
- `scripts/verify-mac-appearance.py` passes against an isolated actual Rust receiver:
  Android Dark then Light are durably acknowledged at revision 3, profile identity
  is retained, real input is disabled and no keys remain held. Android session
  state for this acceptance is memory-only. The normal Mac setup is not selected.
- Rust host unit regressions (198 exercised), Clippy and the complete Swift stack
  safety verifier pass. One optional native bridge test in the ordinary host suite
  remains explicitly skipped; the separate real-receiver appearance case ran.

Evidence: `app/build/evidence/appearance-preference/`, including the real-receiver
receipt, settings recording, visual review frames, and regression logs. The saved
flow is `.argent/flows/android-appearance-settings.yaml`; it assumes an isolated
device with a cached keypad and leaves that keypad in offline practice.

The inactive-profile limitation above is superseded by the following appearance
acceptance. Full inactive-profile/orientation layout synchronization, deleted-profile adoption, generic
layout editing/reconciliation, wider accessibility/device checks and release motion
profiling remain open. This does not establish full Android/iOS parity. The reserved
physical Pixel was not used.

## Inactive-profile appearance and native orientation mirroring (2026-10-19)

Android now uploads pending appearance choices for every profile to the paired Mac,
without selecting those profiles. With its native skin bridge ready, Rust recognizes
appearance-only `gamepad_customization` updates and captures their configuration
revision before queueing them. All other customization fields must match the current
primary layout, apart from its timestamp. Generic layout replacements retain their
existing handler; this does not implement arbitrary inactive layout replacement.

The bounded profile worker runs the existing native `customization.set` operation,
using the same shared model as the CLI. Swift preserves orientation layouts and
mirrors the changed primary layout into its orientation slot. Rust rechecks the
connection, configuration revision and document, keeps newly paired-client trust,
releases input, atomically persists, then publishes the authoritative profile list.
Failure retains the previous authority and leaves Android's intent pending.

Acceptance against an isolated receiver and API 26 Android proves that a cached
inactive profile's Dark intent is acknowledged while the active/default profile
stays unchanged. Active Dark and Light choices then reach revision 4. The receiver
uses the real native bridge, disables input and holds no keys; Android session
state stays in memory. The native packaged-CLI integration additionally checks
orientation-slot mirroring and failed-save rejection without an acknowledgement.
Three pure Rust regressions cover capture boundaries, stale revisions/documents,
new trust preservation and unchanged native results. Generic layout edits,
deleted-profile adoption and the full appearance/device matrix remain open.

Run the real receiver acceptance with the debug app and instrumentation APKs built:

```sh
python3 Android/scripts/verify-mac-appearance.py --serial emulator-5554 \
  --adb "$ANDROID_HOME/platform-tools/adb" \
  --host Host/target/debug/thumble-host \
  --bridge build/MacSkinSyncBinaries/thumble-bridge
```

Verification passes: 108 JVM tests, Android app/test builds and lint, 201 receiver unit regressions (one optional native-bridge case skipped), Clippy, the explicit native receiver/CLI integration, and the complete Swift stack verifier. The API 26 appearance class exercises three local cases; its optional real-host case is skipped there and passes separately with the private pairing fixture.

Evidence: `app/build/evidence/appearance-preference/20261019T231909Z/`, including the final receiver hash and native/Android acceptance logs. A test-fixture startup failure used duplicate template profile IDs; the corrected fixture uses distinct IDs. The initial Clippy large-enum warning is fixed by boxing queue payloads. Failed attempts remain in the evidence record.
The normal Mac installation and reserved physical Pixel remain untouched.

## Durable layout-edit model and native reconciliation oracle (2026-10-19)

The next editor stage now has immutable layout snapshots, intermediate previews,
one completed action per Undo, timestamp-only commit suppression and Cancel back
to the entry snapshot. It is model groundwork: the Android editor controls,
gestures and ControllerClient layout-edit lifecycle are not connected yet.

Pending layout edits retain Mac/profile/orientation identity and exact timestamps.
Profile mutation preserves a previous primary orientation when needed, keeps an
already-saved opposite variant, mirrors the edited orientation into the primary,
and preserves unrelated Mac profile metadata. Reconciliation retains trusted
offline edits until an authoritative echo, isolates other/untrusted Macs, scopes
scalar acknowledgements, and recovers both deleted orientations into one explicit
Android layout without changing selection/default. An earlier orientation edit
cannot silently undo a later profile-wide Saved Mode choice: that later edit must
remain pending until the sequence is acknowledged.

SessionStore atomically writes snapshot, skin, appearance and layout journals in
the existing bounded private file. Older snapshot/skin/appearance save methods
preserve layout edits. Duplicate-key/invalid UTF-8/depth-bounded JSON parsing and
strict journal validation block malformed records before an overwrite. Forgetting
the Mac clears the journal. The immutable layout type consumes canonical model
snapshots; this is not complete arbitrary-import normalization.

Verification passes:

- All 124 JVM tests, including 16 layout tests and all 18 native template fixtures.
- Six reconciliation cases generated by the real Swift model: offline edit,
  different Mac, untrusted authority, two-orientation recovery, acknowledgement,
  and orientation/global-mode interaction. The native Swift Testing suite verifies
  the checked-in fixture against fresh model results. Its selector and source
  triggers are included in the Rust host workflow for future CI runs.
- Six API 26 device methods exercise real AtomicFile persistence/reload,
  coexistence with other journals, an actual failed write, malformed/duplicate
  JSON preservation and the existing appearance lifecycle. One optional real-host
  appearance method is explicitly skipped in this local suite; this stage makes
  no new live Mac/network acceptance claim.
- Android app/test builds, lint, workflow YAML parsing and the complete Swift
  stack verifier pass, including 28 constrained-stack tests and Mac/iOS frame
  budgets. The local compiler-probe/file-backed-demangler workarounds stay outside
  the repository; production stack sizes/budgets are unchanged.

The native oracle is `Tests/AndroidLayoutEditOracleTests.swift`; its data is
`Host/fixtures/android-layout-edits/v1.json`. Explicit fixture regeneration uses:

```sh
TEST_RUNNER_THUMBLE_ANDROID_LAYOUT_FIXTURE_OUTPUT="$PWD/Host/fixtures/android-layout-edits/v1.json" \
  xcodebuild test -project Thumble.xcodeproj -scheme ThumbleTests \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ThumbleCLITests/AndroidLayoutEditOracleTests CODE_SIGNING_ALLOWED=NO
```

Evidence: `app/build/evidence/layout-edits/20261019T233834Z/`, with source hashes,
the intentionally failing global-mode regression, the initial zero-test selector
result before project registration, and final native/device/build/stack results.
The dedicated emulator is cleanly stopped. The normal Mac and reserved Pixel were
not used. Full edit load/send/reconcile/ack wiring, input suppression, editor
gestures/accessibility, native receiver generic replacement/recovery and all other
open parity rows remain required before claiming Android/iOS parity.

## ControllerClient layout-edit lifecycle and synchronization (2026-10-19)

The previous edit model now connects to ControllerClient. Startup strictly loads
the layout journal and exposes its pending count. Editor startup binds an explicit
profile ID, orientation and fresh token, releases held input and retires the old
surface. Every button/element/analog/pointer input path remains suppressed during
editing. Completed edits save snapshot and all three journals before publishing
success. The editor owner can advance Undo/Cancel state only after that success
callback. Failed preparation or persistence leaves the saved keypad unchanged.

Disconnect, suspend, surface changes, leaving the keypad and an authoritative
profile switch retire the editor token; stale callbacks cannot mutate the new
surface. Completed edits survive those interruptions. Reconnect reapplies pending
layout work to the Mac snapshot while retaining newer profile metadata, then sends
orientation-tagged customization payloads using the existing native protocol.
Wrong/untrusted Mac identities and missing mutation capability suppress uploads.
Acknowledgements are evaluated against original authority before optimistic
overlays; a failed acknowledgement save retains the intent without a resend loop.

Later profile-wide appearance choices also rebase outstanding layout payloads.
Skin changes rebase each pending orientation onto the prepared replacement skin
appearance, preserving its edited geometry. Layout/appearance uploads wait until
that profile's pending skin reference is acknowledged, preventing a layout replay
from undoing the new skin or racing its native transform.

Verification passes: 124 JVM tests, app/test builds and lint; ten API 26
client/persistence/appearance methods exercised plus nine affected skin lifecycle
and incoming-sync methods; the optional real-host appearance method is explicitly
skipped in this local suite. The expanded protocol-peer test covers overlapping
input release/suppression, reconnect with a stale Mac snapshot, retained local
layout/new Mac name, failed ACK persistence without looping, and skin-reference
acknowledgement before the rebased layout upload. The complete Swift stack
verifier passes, including 28 constrained-stack tests and Mac/iOS frame budgets.

Evidence: `app/build/evidence/layout-client/20261019T235254Z/`, with final source
hashes and logs. The temporary compiler/demangler workarounds remain confined to
explicit local build invocations. The dedicated emulator is cleanly stopped; the
normal Mac installation and reserved Pixel were not used.

This is client/API integration tested against a loopback protocol peer. It does
not add the visible move/resize/rotate/delete editor or claim a real Mac generic
layout round trip. Generic Rust layout replacement still needs native model
normalization, orientation handling and recovered-profile adoption. The editor
must edit canonical raw layouts and dehydrate package assets if it works from a
rendered snapshot. Those gates, Undo/Cancel/gesture/accessibility UI, interruption
acceptance and every remaining parity row stay open.

## Native Rust layout synchronization acceptance (2026-10-20)

Full Android customization uploads now pass through the shared native Swift model
on the Rust profile worker. Active and inactive orientation edits preserve profile
metadata, the other orientation and active/default selection. Deleted profiles
recover as `Recovered Phone Layout`. Installed skin assets dehydrate to their
package references, and layout synchronization also works with the archive store
unavailable. The scalar bridge remains a compatibility fallback for older helpers.

Queued full-layout intent takes current receiver authority when preparation starts;
a second revision/document check rejects concurrent changes during native work.
Only the target profile's binding maps are reconciled. Persistence precedes the
authoritative broadcast, failed saves produce no acknowledgement, and identical
layouts do not advance the revision. A full eight-slot queue retains authentication;
a twelve-layout native integration burst verifies convergence through retries.

Final verification: 206 Rust unit tests pass (one optional native test skipped in
the unit suite), Clippy and formatting pass, and the explicit native receiver/Swift
skin CLI integration passes, including exact archive export, in-use removal
rejection, detach/remove/reimport/apply, layout recovery, receiver CLI reads and
queue pressure. The complete stack verifier passes with 29 constrained XCTest
cases and Mac/iOS frame budgets; the focused native oracle/model suite passes.
Android retains 124 passing JVM tests plus app/test builds and lint from this stage.

The final API 26 emulator round trip passes against a private real Rust receiver
for active portrait, offline inactive landscape/reconnect and recovered layouts:
`app/build/evidence/layout-receiver/20261020T021534Z/`. A separate run verifies the
unavailable archive-store path at `app/build/evidence/layout-receiver/20261020T021611Z/`. Both use memory-only Android sessions, input
disabled and zero held keys. No normal Mac installation or state was modified. An
earlier test attempt made a read-only canonical Swift CLI profile query; fixture
profile verification now correctly uses `thumble-host profiles --json`. The reserved
physical Pixel was not used. Local compiler/demangler wrappers remain confined to
explicit temporary build invocations.

CI on published commit `45fc141` is green for Rust host/macOS packaging and Stack
Safety. Hosted macOS runner scheduling caused the queue delays; the preceding
60-minute job passed its checks but timed out in post-job cache upload. The
published workflow fix allows 90 minutes and completed successfully.

The visible move/resize/rotate/delete editor, Undo/Cancel/gesture/accessibility UI,
large-archive transfer and remaining rendering/library parity are still open.
This verifies the receiver/client synchronization foundation, not full Android
feature parity.

Combined source hashes and verification logs: `app/build/evidence/layout-native/20261020T023311Z/`. The dedicated acceptance emulator was cleanly stopped after both final runs.

## Visible Android layout editor (2026-10-20)

The keypad menu now opens an explicit editing surface with Cancel, Undo and Done.
Dragging moves a control; selection exposes four resize corners, a rotation
handle and a confirmed delete command. Built-in deletion hides the stable control
identity, while custom deletion removes the element. Locked controls retain
Delete but suppress geometry changes. Accessibility actions provide four-point
nudges, ten-percent scale steps, fifteen-degree rotation steps and deletion, with
position/size/rotation values. The editor renderer has no runtime-input callbacks;
the client additionally suppresses outgoing input while its edit token is active.

Geometry patches apply only to the canonical entry layout, preserving unknown
fields and saved asset references. Resolved installed-skin appearance is a worker
projection for display, never copied into the pending journal by an edit. Intermediate
gesture previews stay local. Each completed action persists before entering Undo
history; a failed save restores the last committed preview without consuming
history. Undo persists its previous entry before removing it. Cancel durably
restores the session entry; a failed Cancel keeps editing available for retry.
Done retains saved actions. Hardware Back asks whether to Keep changes or Restore
starting layout, and leaves an unchanged editor directly. Retired client tokens
still reject callbacks from a closed/interrupted editing surface.

Save/error feedback has reserved space to keep canvas geometry stable. Handle
icons use the theme's corresponding foreground color. Light and dark launch-window
backgrounds now match the application surfaces. The reference behavior is the
existing iOS freeform editor in `IOSContentView.swift`; no Appllama connector was
available, and the existing native Android/Compose controls were retained.

Verification on the final editor APK:

- 129 JVM tests pass, including five new geometry/identity/lock/history tests; app
  and instrumentation APK builds and Android lint pass.
- All four visible editor cases pass in light portrait at normal text size and
  dark landscape at 150% text size. They cover actual move/resize/rotation gestures,
  accessibility rotation/deletion actions, delete confirmation/cancellation,
  one-action Undo, Cancel/Done, save-failure retry and hardware-Back Keep/Restore.
- Existing profile-action and practice/orientation regression classes report nine
  methods: seven exercised and two optional real-host methods explicitly skipped.
- Native test snapshots, source hashes, final APK hashes, complete recorded flows
  and sampled motion-review contact sheets are under
  `app/build/evidence/layout-editor/20261020T025646Z/`. Failed harness attempts remain
  in the evidence record. API 26 UiAutomation initially lost its active-window
  lookup after dismissing a dialog; the test service now requests interactive
  windows and falls back to the focused window. Keyboard Back uses the normal
  instrumentation key path after local saving completes.

These UI cases use isolated in-memory profiles and send no Mac input. The reserved
physical Pixel and normal Mac installation were not used. The earlier native
receiver acceptance establishes the client API round trip separately; an actual
new-editor UI round trip to that receiver remains to be verified. Installed-skin
editing, edge/overlap geometry, interrupted gestures/orientation/backgrounding,
full TalkBack navigation, wider device/API coverage, release frame-rate measurement
and the other parity rows remain open. Recorded debug flow review is not evidence
of sustained release performance.

## Visible editor to native Mac acceptance (2026-10-20)

`Android/scripts/verify-mac-layout-edits.py --editor-ui` now drives the actual editor
against an isolated native Rust receiver, rather than calling the editing API
directly. It pairs through MainActivity, moves a real built-in control, waits for
native acknowledgement, performs Undo, moves again, and verifies Cancel restores
the starting layout on the Mac. It then disconnects through the UI, edits offline,
keeps the change with Done, reconnects to the trusted receiver, and waits for the
pending journal to clear. The script independently restarts the receiver and checks
that its saved profiles/revision and CLI-visible profile identity survive.

The same path passes with `--skin` pointing to the existing unchanged Solar Sumi
package. Its installed artwork is present in the display projection, while matching
package bytes stay out of Android's saved profiles, pending layouts and native
Mac profiles. Exact CLI archive export remains byte-identical. Profile identity,
root metadata, active/default selection and the inactive profile are preserved.
The fixture does not satisfy every captured artwork contract; its visible artwork
warning remains, so this proves synchronization and canonical asset handling, not
complete renderer or skin pixel parity. No artwork was created or published.

Real acceptance exposed and fixed two bugs that the earlier offline UI tests did
not cover:

- Built-in geometry patches changed `buttonCustomizations` without updating the
  declared element layout. Swift's canonical reply synchronized both, leaving the
  Android edit perpetually pending. Patches now maintain both representations,
  matching Swift's setter, and update existing custom appearance mirrors too. The
  mirror regression was observed failing before the fix.
- Cancelled skin preview coroutines could queue inside the blocking synchronized
  resolver and keep the latest editor projection disabled after Undo. Both normal
  controller and editor displays now use a shared cancellable gate before that
  work. A regression holds one render, cancels 32 queued requests, then proves only
  the latest queued request reaches resolution. This bounds obsolete work; it is not a
  release frame-rate claim.

The clean implementation passes 131 JVM tests, app/test builds and lint. The final
local device suite reports 15 methods: 12 exercised, three optional live methods
skipped. The optional real-editor method ran separately twice: the unskinned path
reaches revision 6 at `app/build/evidence/layout-receiver/20261020T034943Z/`, and the
skinned path reaches revision 7 at `app/build/evidence/layout-receiver/20261020T034815Z/`.
The latter includes the recorded complete flow, four screenshots and a sampled
motion-review contact sheet. Temporary projection diagnostics were removed from
the app. Failed attempts and public-fixture diagnostics remain in earlier evidence
folders; pairing credentials are never part of those artifacts.

Both real runs use memory-only Android session/profile state and a private receiver
with input disabled and zero held keys. The normal Mac installation and reserved
physical Pixel were not used. Shared Swift/Rust implementations are unchanged in
this follow-up. Custom-control live edit/delete coverage, renderer fidelity,
interrupted gestures/backgrounding/orientation, full TalkBack navigation, release
performance and every other unfinished parity row remain open.

Combined source/APK hashes and final gates: `app/build/evidence/layout-ui-mac/20261020T035219Z/`.


## Grouped custom-control edits and receiver CLI verification (2026-10-20)

The live editor acceptance now also rotates, resizes and deletes a control, with
native acknowledgements and Undo after each action. The Arcade Stick custom-button
fixture includes both a single-child group and a retained group. Custom deletion
now removes stale references from layer order, groups, labels and appearance
mirrors, drops empty groups, and removes all-default design metadata when Swift
would normalize it away. Two JVM regressions were observed failing before these
fixes; snapshots and unrelated metadata remain preserved.

A separate accessibility defect left cached controls disabled after deletion Undo.
The editor now updates the actual child enabled state and sends a content-change
event when readiness or its control set changes. The complete grouped custom-button
flow passes with the existing unchanged Solar Sumi package at native revision 13:
`app/build/evidence/layout-receiver/20261020T040422Z/`. This includes move, rotation,
resize, deletion, each Undo, Cancel, offline Done/reconnect, receiver restart, CLI
profile identity and byte-exact skin archive export. Native persistence excludes
package-owned hydrated artwork. Input remains disabled with zero held keys, and
Android sessions are memory-only. The normal Mac installation and reserved Pixel
were not used.

The native receiver/public Swift skin CLI integration was rerun successfully.
Android app/test builds, lint and all 133 JVM tests pass. Source/APK hashes and
red/green logs are under `app/build/evidence/layout-ui-mac/20261020T040422Z/`.
The published macOS receiver/package and Stack Safety CI runs at `45fc141` were
rechecked and remain successful. These local Android follow-up edits are not yet
published. Full renderer fidelity, additional custom control kinds, interruption
coverage, TalkBack navigation and release performance remain open.

The expanded built-in control flow also passes at revision 12:
`app/build/evidence/layout-receiver/20261020T040544Z/`. Deletion hides the built-in
control while preserving its declaration; Undo restores its original layout.

The final affected API 26 device suite reports 15 methods: 12 exercised and passed,
three optional live methods skipped. Live native editor acceptance ran separately
as recorded above. The dedicated emulator was stopped after verification.


## Editor gesture interruption and lifecycle acceptance (2026-10-20)

iOS clears its canvas edit selection/gestures on disappearance and finishes editing
when the render orientation changes (`IOSContentView.swift`). Android already
retires its edit lease on pause/orientation changes. Its native edit overlay now
explicitly cancels a preview on window-focus loss, detachment, canvas size changes,
ACTION_CANCEL and loss of the tracked pointer. Cancellation restores the committed
preview and releases parent interception; later events from the retired finger
cannot commit. A new pointer can start a fresh gesture.

Two new API 26 device methods cover all five overlay interruptions and actual
Home/foreground recovery plus native portrait/landscape rotation. They preserve a
completed edit and the exact pending journal while discarding a second unfinished
drag. Rotation retains the activity/connection owner, the next editor session has
no stale Undo entries, and a fresh move/Undo works. Offline practice emits zero
UDP/WebSocket input frames. The Home path resumes the existing task through
Android's external launcher: in-process relaunches are intercepted by the
ActivityScenario test monitor. Earlier failed harness attempts are retained with
the evidence rather than reported as product acceptance.

The complete editor class passes seven reported methods: six exercised and one
optional native-receiver method skipped. The earlier native receiver tests remain
separate evidence. All 133 JVM tests, app/instrumentation builds and final lint pass. Final
gates, source/APK hashes, resumed/rotated screenshots, the 56-second regression
recording and sampled motion sheet are under
`app/build/evidence/layout-interruption/20261020T041445Z/`. The screenshot review
shows the saved control position in portrait after Home and in landscape after
rotation. The recording also includes deliberate test-host view replacement and
disk-failure feedback; it is functional evidence, not a release frame-rate claim.

These tests use memory-only profiles and the dedicated emulator. The normal Mac
installation and reserved physical Pixel are unchanged. Full TalkBack navigation,
additional control kinds, wider lifecycle/API/device coverage, renderer/library
parity, calibration, artifacts, onboarding/settings and release performance remain
open. Full Android/iOS feature parity is not achieved.


## Android skin library and system export (2026-10-20)

A dedicated Skins screen is available from the connection page and keypad menu.
It lists archive metadata, previews the current keypad and each installed package,
shows compatibility warnings, applies a package, forks the current appearance,
shares or saves the exact archive, and confirms removal. An empty-library state
and persistent touch-target preview setting are implemented. Import review now
includes a read-only preview, author/summary/license and Install & Apply alongside
the existing import-for-later action. Package decoding and projection stay off
the UI thread; library metadata is loaded with each installed entry so cards do
not jump when a second metadata request finishes. Apply waits for its preview.

Previews draw at canonical geometry before scaling and have no runtime callbacks.
They decline touches to allow parent scrolling, hide native control descendants
from accessibility and block descendant keyboard focus. FileProvider exposes only
unique cache exports with temporary read permission; private profile/session paths
are outside its configured root. Save file uses Android's document picker. The
visible exported file is byte-identical to the unchanged Solar Sumi source archive.
Temporary share directories preserve already shared bytes and expire after 24
hours on a later export. No artwork was authored, published or approved. The
fixture's existing compatibility warning remains; this is not full skin fidelity.

Removal rejects references used by any saved profile or pending skin selection.
It persists a bounded intent owned by the paired Mac before removing the local
archive. Reconnect offers the Mac's initial archives to the serial skin worker
before its removal cleanup, preventing that replay from restoring a deleted
package. The intent stays durable until local cleanup completes. A failed journal
clear sends once per connection and retries on reconnect. Revision guards protect
a newer removal from an older completion; disposed owners cannot clear a new
owner's intent. Reimport cancels retained removals before installing. The removal protocol has no explicit persistence acknowledgement. Clearing after
accepted WebSocket enqueue and local cleanup follows current iOS delivery
semantics; it does not prove receiver persistence. Native Mac removal
acceptance for this Android UI remains a separate gate.

The final library/sync/lifecycle suite passes all 16 exercised methods, including
seven new library methods. It covers real touch navigation, in-use rejection,
system sharing and return through Home/the app launcher, byte-exact document
export, picker cancellation, fork/removal, Done and hardware Back. The API 26 image
opens its sole share handler (Gmail welcome) directly; no account, recipient or
message action is performed. Separate tests cover read-only provider access,
private-path rejection, non-interactive previews, journal reload/Mac ownership,
worker replay order, failed writes, per-connection deduplication and disposal before
cleanup. Existing incoming package and native appearance/lifecycle regressions
pass. Earlier broader profile/editor checks also pass; failed library harness
attempts are retained separately and are not reported as product acceptance.

All 136 JVM tests, app/instrumentation builds and lint pass. The complete Swift
stack verifier passes with 29 constrained XCTest cases and Mac/iOS frame budgets;
shared Swift/Rust model sources were not changed in this Android follow-up. The
library flow also passes in dark mode at 130% font scale, with a complete recording
and screenshots. The dark button foreground uses the app's neutral rather than
Material's inherited purple. Final logs, source/APK hashes, screenshots and video
are under `app/build/evidence/skin-library/20261020T050915Z/`. This is debug emulator
functional/visual evidence, not release frame-rate or physical-device acceptance.

Tests use memory-only profiles, a private session-store namespace for persistence
checks and loopback peers. Fixture archives and export files are restored/cleaned;
normal Mac installation/state and the reserved Pixel remain untouched. Full
TalkBack, touch-target setting/recreation acceptance, import-provider navigation,
inbound share-sheet pickup, combined Install & Apply UI acceptance, native removal
sync, bundled migration, full normalization/renderer coverage and the broader
calibration/artifact/onboarding/release requirements remain open.

The final semantic-color build repeats the dark/130% flow and expands the recovery
case to protect both same-owner newer intents and a different disposed owner. Both
methods pass. Final screenshots and the sampled motion sheet were inspected. The
65-second viewing clip retains the complete flow; the full 118-second recording
is also retained. Emulator font/night settings were restored and the dedicated
emulator was cleanly stopped. These follow-up changes remain local.


## External skin-file delivery (2026-10-20)

Android accepts the native `application/vnd.pocketpad.skin+zip` MIME and ZIP/octet-stream
aliases through ACTION_SEND and content-URI ACTION_VIEW. A single controller activity
receives warm deliveries, closes Settings and neutralizes the input surface before
opening the existing import review. Files are read off the main thread with a 40 MiB
archive bound and existing ZIP/manifest checks. No incoming attachment automatically
installs a skin or imports its embedded profile. File/HTTP URIs, multiple attachments
and malformed packages fail with a user-facing error.

The retained session keeps only the newest pending attachment while a read or skin
operation is busy. Recreation retains the controller and review without duplicate
provider reads; cancel consumes that delivery, while explicitly sharing the file again
opens a new review. Saved state retains the recovery URI for a new session, but actual
process-death restoration and provider grant lifetime across that event remain unverified.
Library refresh preserves import errors until dismissal or retry.

The test APK supplies a separate-UID, unexported provider and sender, so permission
denial is enforced by Android rather than simulated by throwing in app code. Acceptance
checks cover cold SEND, warm VIEW over Settings, ClipData-only sharing, review without
installation, cancellation/recreation, queued latest-file selection, denied grants and
malformed archives. Install & Apply preserves profile/default identity, control IDs and
bindings, saves a pending Mac selection and installs the exact archive bytes. These
offline tests assert zero outgoing input. They do not replace physical sharing-app,
SAF picker, current-API or normal-Mac acceptance. No artwork was authored or published.

Final acceptance evidence: `app/build/evidence/skin-inbound/20261020T070203Z/verification.json`.
The final build/lint and all 141 JVM tests pass. The affected device suite reports
30 methods: 29 exercised passes, one optional live-Mac skip, zero failures. This
includes all five inbound delivery methods plus library management, authenticated
incoming sync, skin profile lifecycle and retained session/reconnect regressions.
Screenshots were inspected after preview projection resolved; the compatibility
warning correctly explains the unchanged fixture's canvas mismatch. Earlier failed
harness/product runs are retained separately under `diagnostic-runs`. The required
Swift stack gate passes all 29 constrained-thread tests and Mac/iOS frame checks.
Ordinary launcher intents retain their original identity; only supported external
file deliveries are consumed. No full Android parity completion is claimed.


## Thumb-placement calibration (2026-10-20)

The profile menu now exposes **Calibrate thumb reach**. Its overlay uses the live
controller canvas after Android safe-drawing insets, so its normalized traces and
control geometry share the same coordinate system. Left/right hand capture follows
the native `designMetadata.tags` policy, including one-handed layouts. Each lift
advances one hand; a tap provides the native default ellipse. An accessible estimate
action is also available. Extra pointers, canceled gestures, focus loss and resize
discard the unfinished trace. Backgrounding, recreation, orientation/canvas changes
and incoming navigation retire the edit/input generation.

Reach samples remain device-only, outside backup and profile/skin archives. Private
AtomicFile records are scoped by profile, device, display geometry/density and
orientation, with bounded samples/records, corruption detection and interrupted-write
backup recovery. Completed calibration saves without changing a keypad. The overlay
retains the user's practice choice and gates all input through the existing edit
session; live mock-receiver acceptance proves held-input release and suppression of
stale/new digital, analog and pointer frames. Heartbeats may continue.

The scorer ports `ThumbPlacementScorer` in `IOSLocalKeypadUX.swift`: calibrated reach,
visual safe-area containment, 44 dp minimum size and actual initial hit-frame overlap.
It retains native zone bounding-box intersection behavior and keeps thumbstick capture
separate from its larger retention region. Suggestions port minimum-size repair,
safe-area movement, calibrated reach placement and deterministic expanded-hit packing.
They preserve IDs, bindings, styling and location locks. Geometry work and scoring run
outside the input/UI queues. A stable report panel avoids changing size after scoring.
Left/right zones use solid/dashed outlines, and the score has a polite accessibility
live region.

Accepting a suggestion saves through the existing layout journal, then opens the editor
with Undo and the original layout as its restore point. Failed layout persistence leaves
the original profile and journal intact and keeps the error in calibration. Cancel/Done
without repair leave the keypad unchanged; a completed reach trace remains saved.
The isolated native receiver fixture verifies an offered overlap repair is acknowledged,
matched to Rust's persisted profile, retained on trusted reconnect and receiver restart,
and leaves profile/default identity, metadata and an inactive profile unchanged.
`Android/scripts/verify-mac-calibration.py` uses a no-input/no-Bonjour receiver, memory-only
Android session state and public template fixtures; it does not replace the normal Mac.

This does not establish physical ergonomic comfort, all repair combinations on every
geometry, a wider Android API/device/accessibility matrix, or release frame-rate parity.
Those requirements and the other open inventory rows remain part of the full goal.

Final checkpoint: `app/build/evidence/thumb-calibration/20261020T074931Z/verification.json`.
All 153 JVM tests, Android build and lint pass. The affected regression suite exercises
29 passing methods plus four explicitly optional external skips (33 total), covering
calibration, editor gestures/history, layout journal/input safety, retained sessions
and incoming skin intents. After hoisting a repeated layout-mode decode, the focused
calibration suite again passes six local methods with its optional native method
skipped. That native method separately passes against the exact final APKs through
`app/build/evidence/calibration-receiver/20261020T081701Z/acceptance.json`: Rust's saved
portrait matches Android, landscape stays unchanged, the primary mirror matches the
portrait repair, and trusted reconnect/restart preserve it. Input is disabled on that
private receiver and no held keys remain.

Final light/dark 130% text flows pass and their stable-panel recordings/frame samples
are retained. Those recordings precede only the equivalent decode hoist; post-hoist
local/native acceptance uses the final binary hashes. Setup/teardown and prior failed
runs are identified separately; no release frame-rate claim is made. The required
Swift gate passes 29 constrained-thread tests and Mac/iOS static frame budgets.
The dedicated emulator is restored/stopped after evidence collection; the physical
Pixel and normal Mac installation remain untouched.

## Shared-build pickup and isolated Practice Preview checkpoint (2026-10-20)

Android accepts the production builder `/share/bar_<digest>#token=<token>` link
through a transient entry activity. The bearer link stays in memory; MainActivity
receives a normal launcher intent. Its retained coordinator bounds downloads to
8 MiB, disallows redirects/cookies/cache/retries, sends authorization only in the
request header, and rejects unexpected origins, paths, MIME types and responses.
Explicit loopback testing is separate from production origin acceptance.

Portable v4/artifact-v1 bytes retain their unknown fields and exact encoding.
Validation covers strict UTF-8/I-JSON limits, duplicate keys, RFC 8785 integrity,
portable-field restrictions, profile/control identity and binding ownership,
known layout/appearance models, and executable binding/control-setting types.
Canonicalization uses the Apache-2.0
[java-json-canonicalization 1.1 implementation](https://github.com/erdtman/java-json-canonicalization),
with native fixture hashes, ECMAScript number vectors and UTF-16 key-order checks.
`scripts/verify-shared-build-types.py --bridge ../build/PhoneLayoutBinaries/thumble-bridge`
checks the same 54 executable-setting cases against the native Swift decoder.
This matrix is deliberately narrower than full typed-profile normalization.

Preview & Keep commits exact bytes plus protected metadata to a private no-backup
store before entering preview. The store uses owner-only permissions, bounded
no-follow reads, atomic pair writes, integrity revalidation, record/byte quotas,
TTL pruning and interrupted-adoption recovery. Android device tests exercise the
actual filesystem APIs. A failed keep leaves the review available and never
starts a preview. A new controller session reloads kept records without replaying
the bearer URL or automatically entering preview.

The preview snapshot is separate from paired/saved authority. Input is released
on entry and all input paths are suppressed; profile switching stays local.
Preview cannot edit/default/orient/launch/apply skins or persist a Practice Mode
change. Incoming Mac snapshots still update authority. Closing preview restores
the latest authoritative snapshot and existing preferences. Pending builds can be
reopened or deleted from Shared builds. Review and active downloads survive
Activity recreation, and newer external downloads cancel superseded work.

Acceptance evidence is saved under
`app/build/evidence/shared-builds/20261020T094950Z/verification.json`:
170 JVM tests, all eight shared-build device tests, 25 affected import/editor/
calibration/session device tests, three explicitly skipped live-Mac scenarios,
and full review/keep/switch/close/reopen/delete flows in light/dark at 130% text.
The native executable-setting oracle passes 54 cases. The Swift gate passes 29
constrained-thread tests and Mac/iOS frame budgets. Screenshots, an untrimmed
25-second screen recording, logs and exact source/APK/bridge hashes are retained;
the recording makes no release-performance claim. The original link-delivery
failure was literal quotes introduced by the test sender's UiAutomation command;
the corrected original tests pass. Diagnostic runs are stored separately.

This pickup checkpoint is superseded by the adoption checkpoint below. Verified
production browser association and physical/device acceptance remain open.

## Native profile compatibility and Android-to-Rust adoption (2026-10-20)

The native Swift artifact bridge validates the exact portable bytes and returns
current typed profiles without mutating authority. The compatibility oracle now
covers 94 cases, including all shipped controller templates, mirror defaults and
executable overrides, design metadata, assets, presentation and UUID ownership.
Android compares acceptance and normalized primary control projections against
native fixtures. Safe unknown fields remain in the byte-preserving artifact;
these checks do not claim whole-profile JSON equality for arbitrary future fields.
The real native `left_stick`/`right_stick` spellings now reach Android analog
output; a native-template gesture regression covers the former digital fallback.

Shared builds offer explicit Adopt on Mac confirmation bound to the connected
server. The coordinator records stable operation/record/server/hash metadata
before upload. The client releases input, blocks input and profile mutations,
sends bounded ordered chunks over authenticated WebSocket, and waits for both
an exact result and a full authoritative snapshot containing every destination.
Only then is the pending artifact removed. Failure/cancellation retains exact
bytes for retry; retry to the same Mac keeps the operation identity. The existing
practice preference and Mac default remain unchanged.

The Rust receiver gates capability on native validation and configuration write
authorization. It appends deterministic copies through the CLI import planner,
installs native normalized controls while preserving safe future metadata, and
atomically persists profiles with a bounded successful-operation receipt. Replay
is idempotent across restart. The public `thumble shared-build adopt|status|cancel`
CLI uses the same running authority. Cancellation during native preparation,
metadata conflicts, out-of-order chunks and failed writes are integration-tested.

The first real UI test exposed a Rust hash mismatch: empty optional binding maps
were inserted before hashing. The codec now retains omitted-field presence for
hashing and serialization, with omission/round-trip/tampering regression coverage.
Android's original artifact is accepted unchanged by both native Swift and Rust.

Local acceptance: `app/build/evidence/artifact-adoption/20261020T140733Z/acceptance.json`
records the reviewed Android UI flow into a private no-input receiver, two new
profile copies, unchanged default, authoritative confirmation and pending cleanup,
and public CLI replay before/after receiver restart. The native/CLI suite also
exercises failed atomic persistence and cancellation while native validation runs.
The normal Mac installation is untouched. Test logs and final source/binary hashes
are collected in the verification manifest beside that acceptance receipt.
The final Android build/lint and 175 JVM tests pass. Device regression coverage
passes 13 cases with two explicitly skipped optional live-receiver cases; the
new isolated native UI case passes separately. Both native/CLI integration tests,
all Rust workspace tests, Clippy, and the required 29-test Swift stack/frame gate
pass. The emulator was restored and stopped after capture.

This remains partial Android parity: verified production browser routing,
physical-device/network acceptance, broader API/device accessibility coverage and
other open rows in this document still need their own receipts.


## Installed normal-Mac adoption acceptance (2026-10-20)

Installed the updated Rust receiver/native bridge/public CLI on the existing Mac
installation and the Android app on the dedicated API 26 emulator. Real input and
configuration writes remain enabled on port 8765. Normal-receiver adoption, CLI
replay/status, late-cancel replay, Android cancellation with retained bytes, and
CLI cancellation delivered to Android pass. Only synthetic profiles were removed;
the original five profiles, binding maps, default and selection are unchanged.

Normal-state acceptance exposed legacy inline `modifiers` spelling and native
integral-float JSON round-trip differences. Bridge-only native decoding projection
and exact numeric representation preservation fix those paths without rewriting
original profile metadata or relaxing portable artifact validation. Tests cover
legacy values, array reordering, invalid modifiers and large-integer rounding.
The host unit suite passes 209 cases; three native/CLI integration cases run
serially, the native profile oracle passes 94 cases, and the Swift gate passes
30 constrained-thread cases plus static frame budgets. Clippy passes with the
CI-pinned Rust 1.88 toolchain. Rust 1.98 reports new style lints in existing core
code; no unrelated compatibility refactor was made for those lints.

Evidence and installed/APK/source hashes:
`app/build/evidence/installed-artifact-adoption/20261020T144933Z/verification.json`.
This is emulator-to-normal-Mac acceptance. Physical Android and real Wi-Fi/device
coverage, verified production link association, and other open parity rows remain.


## Physical Pixel 7 Wi-Fi adoption acceptance (2026-10-20)

Updated the existing Thumble app in place on the physical Pixel 7 (Android API
37), preserving its app data. Both reviewed shared-build adoption and the
cancellation test pass against the normal installed Mac receiver over the phone's
`wlan0` route to the Mac LAN address on port 8765. USB provides installation and
test control; application traffic uses the direct Wi-Fi URL, without ADB reverse.

Public CLI adoption replay/status returns the same destination IDs without adding
profiles. A late cancel replays the durable completed result. Production Android
cancellation retains the exact build bytes; a separate pending Android WebSocket
upload is canceled through the public CLI and Android receives the disconnected
result. Cancellation leaves authority unchanged. Test cleanup removes only its
synthetic profiles and restores the original five profiles, binding maps, default
and selection. Real input remains enabled, with no held keys.

The foreground installed app reconnects using its existing saved Mac credentials
and shows the original keypad with UDP + WebSocket transport. Evidence, screenshots,
route details and exact installed receiver/APK hashes are in
`app/build/evidence/installed-artifact-adoption/20261020T145409Z/verification.json`.
This closes the first physical-phone Wi-Fi adoption receipt. The interruption
cases below extend this checkpoint. Other device/API, accessibility and verified
production browser-link coverage remain separate open rows.


## Physical Pixel 7 Wi-Fi interruption recovery (2026-10-20)

Both adoption boundaries pass against the normal installed receiver: Wi-Fi loss
with only the first of eight upload chunks forwarded, and Wi-Fi loss after a
successful Mac commit while its result/snapshot are withheld from Android. A
phone-local test relay gates those exact boundaries; its upstream uses the Mac
LAN address over wlan0. USB controls the test and actually disables/enables the
Pixel Wi-Fi radio. The offline route becomes unreachable, and an actual upstream
ping I/O failure closes the production ControllerClient connection.

The production SharedBuildSession retains one pending build with byte-identical
content, hashes, record, operation and intended Mac identity. Reconnect and retry
produce exactly one profile copy per operation. For the committed case, retry
returns the original destination ID. Both public CLI replays also leave receiver
authority unchanged. Pending bytes are removed only after authoritative Android
confirmation. The harness restores Wi-Fi and removes only receipt-identified test
profiles through the public CLI; original five profiles, all binding maps, default
and selection compare exactly. The installed foreground app reconnects using its
existing saved credentials, with practice off and UDP + WebSocket active.

Repeatable test: `scripts/verify-wifi-adoption-recovery.py`, with physical serial,
ADB path, installed-bin path and explicit receiver-host arguments. Evidence:
`app/build/evidence/wifi-adoption-recovery/20261020T150648Z/verification.json`.
The deterministic gate is test-only; this checkpoint does not cover arbitrary
router outages or long offline intervals. Process-death coverage follows below.


## Pixel 7 process-death adoption recovery (2026-10-20)

Physical Pixel 7 / normal Mac acceptance passes at both boundaries: only one of
eight chunks forwarded, and Mac commit completed with confirmation withheld.
A phone-local test relay gates the first attempt; USB force-stops the actual
Android process. PID absence is checked before inspecting app-private files:
the pending metadata is still ADOPTING, and the two-megabyte artifact hash matches
exactly. No graceful cancellation or lifecycle cleanup prepares the recovery.

A second instrumentation process launches the real MainActivity with the same
isolated production PendingSharedBuildStore and AndroidSessionStore namespace.
Encrypted Mac credentials reload from disk and reconnect directly over Wi-Fi.
SharedBuildSession recovers the interrupted record as FAILED/disconnected while
preserving bytes, hashes, operation, record and intended Mac. The visible Shared
builds screen offers the retained build; tapping Adopt and Add to Mac succeeds.
Pending files disappear only after authoritative confirmation. The committed
case returns the original destination ID, and public CLI replay for both cases
adds no duplicates. Each operation creates exactly one profile copy.

The harness removes only receipt-identified synthetic profiles and its UUID test
namespaces. Original five Mac profiles, binding maps, default and selection are
restored exactly; normal Android pending/session data is untouched. The normal
foreground app reconnects with saved credentials and UDP + WebSocket active.
Repeatable harness: `scripts/verify-process-death-adoption.py`. Receipt, dead-process
file checks, distinct PIDs and retained/confirmed UI screenshots:
`app/build/evidence/process-death-adoption/20261020T151151Z/verification.json`.
This covers force-stop with deterministic protocol gates; reboot coverage follows
below. Storage failure and arbitrary crash timing remain separate cases.


## Pixel 7 reboot adoption recovery (2026-10-20)

The complete physical-reboot run passes during partial upload and after the Mac
commits while Android confirmation is withheld. A phone-local relay gates the
first attempt; USB reboots the actual Pixel, and distinct Linux boot IDs verify
that a reboot occurred. After the user unlocks credential-encrypted storage,
app-private files are inspected before launching Thumble: metadata remains
ADOPTING, and the original artifact SHA-256 and operation ID match.

A fresh MainActivity reloads the isolated production AndroidSessionStore and
PendingSharedBuildStore. Encrypted Mac credentials survive, the interrupted
record becomes retryable, and the visible Shared builds UI completes adoption
through a direct Wi-Fi connection. Both operations create exactly one profile
copy. The committed retry returns its pre-reboot destination ID, and public CLI
replay adds no profiles. Pending files are deleted only after authoritative
confirmation. Cleanup verifies the original five profiles, global/per-profile
bindings, default and selection exactly; normal Android session/pending data is
untouched. The installed foreground app reconnects with UDP + WebSocket active.

Harness: `scripts/verify-reboot-adoption.py`; unlock the phone after each reboot.
Receipt, changed boot IDs, disk hashes and UI screenshots:
`app/build/evidence/reboot-adoption/20261020T152343Z/verification.json`.
One initial partial-upload run retained bytes but timed out in the 35-second
reconnect/recovery wait. The same force-stop scenarios and the complete reboot
rerun passed afterward, without production changes. A subsequent investigation reproduced and fixed a discovery/handshake race,
described below; the original timeout had no trace of its exact trigger. Initial evidence:
`app/build/evidence/reboot-adoption/20261020T151542Z/partial-relaunch.log`.
Failure diagnostics are retained by the harness for future reproduction. Sudden
power loss, storage failure and arbitrary interruption timing remain separate cases.


## Trusted reconnect discovery race (2026-10-20)

A deterministic production-client regression reproduces a startup stall without
rebooting: the cached endpoint has received the trusted hello, then discovery
returns an alternative address whose WebSocket upgrade stalls. Previously the
client canceled the healthy handshake and switched to that alternative; the
cached host's valid acceptance was discarded. The regression failed before the
fix (`cached trusted handshake survives discovery`) and passes afterward on API
26 and the physical API 37 Pixel. Existing session recovery tests also pass.

ControllerClient now keeps an in-progress trusted attempt and inserts newly
resolved addresses into its remaining fallback candidates. Discovery can still
start a connection when no attempt is active. The unchanged identity checks,
endpoint bounds, explicit disconnect behavior and stale-callback guards remain
covered by the recovery suite. No timeout was increased.

The corrected APK was installed in place on the Pixel. Both actual reboot UI
recovery cases pass: connected at 2,896 ms for partial upload and 2,629 ms for the
committed operation, with the original 35-second startup wait. Pending bytes and
encrypted credentials survive, and UI retry plus audited public CLI replay return
exactly one destination per operation. Stack safety passes all 30 constrained
thread tests and both platform frame gates.

During the normal-Mac run another chat added Warband Command, so the harness's
whole-profile-count guard correctly stopped reporting a global pass. Both phone
cases had passed; an operation-scoped receipt/replay audit confirmed no duplicates
and no replay authority changes, and only this run's two profiles were removed.
The unrelated addition was preserved. Reboot evidence:
`app/build/evidence/reboot-adoption/20261020T154758Z/operation-verification-reviewed.json`.
The original untraced timeout's exact trigger remains unproven; the controlled
regression demonstrates the discovery failure mechanism and its correction.

Before/after regression logs, Pixel regression, startup timelines, APK hashes and
stack-gate log: `app/build/evidence/reconnect-startup-fix/20261020T154435Z/`.
The normal Host was subsequently stopped explicitly in another chat for the Mac
editor; remaining recovery reruns use an isolated recording-only Rust receiver.
The isolated CLI uses a private owner-only child-process home so its sanitized
helper cannot route to the user's editor. The test harnesses require an explicit
isolated flag, an isolated server ID and matching state directory for this mode.


Post-fix isolated recording-only Wi-Fi and force-stop recovery reruns both pass,
including retained bytes, UI retry, authoritative cleanup and public CLI replay.
Receipts: `Android/app/build/evidence/wifi-adoption-recovery/20261020T160550Z/verification.json`
and `Android/app/build/evidence/process-death-adoption/20261020T160615Z/verification.json`.
Repeatable isolated runner: `Android/scripts/verify-isolated-adoption-recovery.py`
with explicit serial, ADB, bin and receiver-host arguments. Combined verification:
`Android/app/build/evidence/reconnect-startup-fix/20261020T154435Z/verification.json`.
The driver-only instrumentation fixtures now skip when no external-driver arguments
are supplied. The normal Host remains intentionally stopped for the Mac editor.


## Native typography metrics and tracking (2026-10-20)

Android now mirrors GamepadNativeContentPresentation's control-specific text,
button, joystick, trackpad and trigger font defaults and minimum scaling factors.
Explicit authored sizes remain fixed. Long ordinary labels try 16/14-point faces
and the condensed 14-point fallback, preserving the native lower bound. Ordinary
short labels use the Geist heading tracking default; authored typography retains
its independent tracking and inheritance behavior.

Authored tracking is now an absolute point distance through measurement and
painting, including TextView auto-size probes. Previously a fixed em ratio made
the same tracking value grow or shrink with the chosen font size. A zero-tracking
pressed style removes the old spacing, and release restores normal spacing.
Labels use the existing pinned Swift-compatible grapheme segmentation when
choosing short-label metrics and centered-icon visibility, retaining combined
accent and family/flag emoji legends. Platform SP conversion supports larger
Android font settings without changing hit geometry.

Three native-view regressions failed before the fix. Final acceptance passes all
178 unit tests, zero lint errors, 20 API 26 device methods and 21 Pixel methods
across typography, raster/style, icon/artwork and renderer suites. Five typography
methods include 160% font scaling and preserved press identity through state font
changes. The Pixel matrix was visually inspected. The required stack gate passes
30 constrained-thread tests and macOS/iOS frame checks. The updated app/test APKs
are installed on the Pixel without clearing its saved data; no Mac runtime or
profile configuration was changed.

Evidence, before/after logs, source/APK hashes and native-rendered matrices:
`app/build/evidence/typography-parity/20261020T164218Z/verification.json`.
This advances the renderer row. Caption/binding-hint content, exact platform font
design fidelity, broader symbols, onboarding and the other open parity rows remain
required; this checkpoint does not claim full Android/iOS parity.

## Captions and binding hints acceptance (2026-10-20)

- Android now decodes and persists canonical `bindingPresentations` independently
  of executable bindings. Exact orientation groups win over common groups,
  including an explicitly empty orientation group; omitted metadata retains the
  cache and an empty array clears it. Shared-build practice previews use their
  own snapshot and cannot inherit the connected Mac's hints.
- Controller faces draw authored captions and host-supplied output hints in a
  centered secondary stack with native visibility, duplicate suppression,
  direction order, monospaced 10-point sizing, half-size fitting floor, 0.76
  foreground alpha and one-point spacing. Decorations stay passive; text controls
  can show captions but never output hints. Whole-face blur invalidates its cache
  when hints change.
- The persistent Show binding hints setting defaults on. Turning it off keeps
  captions and the accessibility node's output description. Metadata-only socket
  updates and this preference retain the surface revision and physical press
  identity. Actual TalkBack speech/interaction acceptance remains part of the
  broader accessibility/device row.
- Rust now sends formatted binding metadata with its profile snapshots. Wire and
  CLI display share raw authoritative resolution, orientation and output-mode
  filtering. Legacy joystick mappings fill missing directional outputs while
  explicit empty part bindings remain clears; text/decoration outputs are omitted.
  Native modifier order, key sequences, gamepad display order and unknown numeric
  key names are covered by receiver regressions.
- Acceptance: 184 Android unit tests; Pixel and API 26 caption/hint, typography,
  icon/artwork, asset/style and renderer suites; 213 Rust host library tests
  (one unrelated ignored test); Rust formatting/clippy; Android lint; and the
  required 30 constrained-thread Swift tests plus Mac/iOS static frame gates.
- `scripts/verify-binding-presentations.py` runs a private recording-only receiver,
  checks the public Swift CLI's actual formatted output, and pairs both Android
  devices with that Rust receiver. The physical Pixel uses Wi-Fi. The ordinary
  Mac runtime and profile library are not changed. The test runtime is removed
  afterward. Evidence is under `app/build/evidence/binding-hints-parity/`.
- Exact platform fonts/symbols, continuous corner curves, broader accessibility
  acceptance, onboarding, peer-to-peer discovery equivalence and release/device
  acceptance remain open. This does not complete the full iOS parity goal.

## Setup guide acceptance (2026-10-20)

- Added the native Android Welcome, Permissions, Connect and Use Keypads guide.
  Instructions match Android permission timing, trusted-Mac Smart Connect, QR and
  manual pairing, saved practice, profile menus and the freeform layout editor.
  No permission is required merely to finish or skip the guide.
- Completion is an atomic private record, separate from connection credentials.
  Established installations with saved profiles or trust migrate past first-run
  setup without replacing either. Forgetting a Mac preserves completed setup.
  Save failures retain the guide and permit an explicit retry; corrupt records are
  preserved until explicit completion. Custom session stores predating the guide
  opt out until they implement its durable state contract.
- Setup can be reopened from connection or keypad options. Selected steps survive
  foreground/background navigation; activity recreation uses saved Compose state.
  Incoming shared-build and skin reviews take priority over unfinished setup.
- Four production-store/client instrumentation regressions pass on Pixel/API 26.
  The Pixel's recorded `android-setup-pages` flow passes 46 steps in two complete
  replays: all four pages, Back, finish, reopen and skip, with foreground cycles
  retaining the selected step. These cycles also work around Argent Android
  devtools returning a cached Compose tree. A plain uninterrupted tree refresh is
  not claimed. API 26 Argent helper startup failed; its native instrumentation
  coverage passed, but the visual guide flow was verified on Pixel only.
- The incoming shared-build regression verifies that review opens while the
  completion flag stays false. The manifest-only filter check now scopes its
  query to the app; it does not establish production browser-link verification,
  which remains an explicit separate acceptance requirement.
- Broader cold-first-run UI, landscape/large-type/theme, actual permission denial
  recovery and TalkBack speech acceptance remain open. This milestone does not
  establish full iOS parity.

## Credential-expiry cache audit still required

A live launch rejected the Pixel's previously saved trust. Source comparison shows
Android `forgetExpiredTrust()` calls `store.forgetMac()`, which also removes the
persisted profile/edit cache; iOS `clearTrustedMacCredential()` clears only trust.
The Mac profile library is unaffected. Retaining safe offline profiles while
separately retiring credentials and handling pending journals needs a dedicated
parity fix and recovery regression; it is not covered by setup completion tests.

Final setup-guide verification: 184 Android unit tests, 37 exercised device methods
per device across the setup/session/profile/binding and import suites (42 reported,
five optional live methods skipped), two complete 46-step Pixel flow passes,
zero lint errors, and 30 constrained-thread Swift tests plus both static frame
gates. The skin-import cancellation regression now waits for the replacement
Activity after recreation; its old readiness check could pass on the original
Activity. The focused case and full import suites pass after that correction.
Evidence: `app/build/evidence/onboarding/20261020T173240Z/verification.json`.
Replay using Argent `flow-execute` with `name: android-setup-pages`, the absolute
repository `project_root`, and an explicit Android `device`; start on a device
whose setup is already complete and whose connection screen is available.
