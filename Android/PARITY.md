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
| Joystick directions, analog sticks/triggers, pointer trackpad/move/scroll/click/drag | ControllerClient, shared keypad renderers | Implemented joystick capture/transforms, analog coalescing/refresh/neutral, trigger thresholds, trackpad movement/scroll/taps. Pixel native gestures → Rust recorder pass with direct UDP and mid-hold UDP loss; actual Mac pointer/HID consumer output and drag coverage remain pending |
| Haptics, control/accessibility feedback, keep awake, appearance/settings | IOSLocalKeypadUX, IOSContentView | Basic accessibility and keep-awake implemented; remaining settings/feedback missing |
| Full renderer: element kinds, style tokens, layers/action sets, skins, vector/raster assets, fills, text, hit regions, dark/light | Shared skin compiler/resolver/renderers, ControllerClient | Native size/center/clamp rules, builtin override ownership, design layer order, all seven canonical shapes, per-corner radii, solid/linear/radial/tile fills, profile appearance, legend visibility and accessibility names implemented. Pixel pixel/gesture/portrait/landscape captures pass. Canonical raster asset references/inline data, fit/crop/tile/nine-slice modes, JPEG EXIF orientation, image adjustments, native token/inline state inheritance, core fill/foreground/border/opacity/scale and authored text fields are now implemented/tested. Passive artwork planes (including blend/rotation/opacity/order), text/raster icons, native icon/legend placement and template symbol equivalents are implemented/tested. Stacked outer shadows, glow, masked inner shadows/highlights, bevels, state marks and whole-face blur are implemented with Pixel pixel/gesture/capture acceptance. Broader symbol coverage, vector display lists, installed-skin hydration and full typography remain missing; native continuous corner curves are not exact. Authored Lux positions remain overlapping |
| Profile selection/default, orientation mutations, profile launch targets, capability/readiness display | ControllerClient, IOSContentView | Selection only; honor server capabilities and authoritative responses |
| Local layout editing, offline pending edits and reconciliation, color preference | ControllerClient pendingKeypadLayoutEdits, IOSLocalKeypadUX | Missing; conflict/ack/restart tests required |
| Skin library/import/export/apply/detach/remove, .pocketpad sharing/review | IOSSkinLibraryView, IOSContentView, shared skin packages | Missing; editable source and native renderer validation required; no publishing or approval implied |
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

Next acceptance area: actual Mac pointer/HID consumer output and broader gesture/device
coverage. Next implementation area: vector display lists, broader symbol coverage, installed skin resolution, renderer/skin fidelity and editing,
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
