# Thumble Android

Native Kotlin/Compose Android client for the existing Thumble Mac receiver.
Full iOS feature parity is an active implementation goal tracked in [PARITY.md](PARITY.md).
The current build includes the tested transport slice plus saved trust, nearby
reconnection, offline practice, profile orientation handling, joysticks, triggers and trackpads. It does not yet
provide full iOS parity.

## Build and install

Requires JDK 17+ and Android SDK 35. The checked-in Gradle wrapper downloads Gradle
8.11.1; dependencies come from Google Maven and Maven Central. Set `ANDROID_HOME`
or create an untracked `local.properties` containing `sdk.dir=/path/to/android/sdk`.

```sh
cd Android
./gradlew :app:assembleDebug :app:testDebugUnitTest :app:lintDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

Open **Thumble** on Android 8.0/API 26 or later. On the Mac, run a current native
Thumble Mac helper that advertises input protocol v3. Keep both devices on the same
Wi-Fi. Disconnect any other paired phone; the host permits one active phone.

1. Tap **Scan Mac QR Code** and allow camera access. Scan the QR displayed by the
   Mac helper. The scanner is bundled and needs no Google Play Services download.
2. Allow local network access when Android requests it. Android 17 requires this
   on the tested Pixel even with this prototype's target SDK 35.
3. Alternatively, enter a `ws://<mac-ip>:<port>` address and the current six-digit
   Mac pairing code. If a QR lacks a code, the app requests a pairing challenge
   and lets you enter the code shown by the Mac.
4. The selected real profile appears. Tap its name to choose another host profile.
   Controls send the host's configured outputs; Android does not reinterpret key codes.
5. Hold multiple buttons simultaneously. Slide between buttons to change a hold.
   Disable **UDP** to exercise the WebSocket-only fallback.

After pairing once, the app remembers this Mac and reconnects when brought to the
foreground. **Disconnect** stops automatic reconnect for that app session;
**Reconnect to saved Mac** opts back in. **Forget saved Mac** removes its saved
credential and profile cache. **Practice with saved keypad** works offline and
suppresses input to the Mac; connected practice also clears prior held inputs.
Profile portrait/landscape preferences are honored, and rotation retains the
connection while releasing active touches.

The Mac still needs its usual Accessibility approval to inject input. Testing
against an isolated helper without Accessibility permission verifies transport
and receive-state behavior without injecting keyboard events into other apps.

## Implemented behavior

- Existing `pocketpad-pair` QR JSON, endpoint retry, expected server identity check,
  manual pairing and pairing-challenge code entry. No QR/credential logging.
- Saved Mac trust encrypted using an Android Keystore AES-GCM key; transient QR
  codes and realtime tokens are not persisted. Private files are excluded from backup.
- Foreground trusted reconnect with capped exponential retry, network-availability
  wake-up, explicit disconnect/forget, revocation handling, and server identity checks.
- Native NSD/Bonjour lookup scoped to the advertised server ID (or QR service name),
  service-only QR pairing, and recovery from an unavailable cached address.
- Saved profiles, local offline profile selection, and persistent practice preference.
  Entering practice clears remote state; practice touches suppress digital, analog and pointer input.
- Native portrait/landscape profile locks, orientation variant selection, and connection
  retention through configuration changes; a ViewModel retains pending/paired
  connections across activity recreation, and fresh clients reload saved trust.
- Protocol-v3 UUID button and canonical element-part frames, byte-compatible with Swift/Rust shared fixtures.
- Single-owner joysticks with independent digital directions, canonical analog targets,
  dead zones, sensitivity, inversion and cardinal snap. Triggers support orientation,
  transformed analog values and digital threshold crossings with paired press IDs.
- Trackpad pointer movement, two-finger scrolling, one-/two-finger tap clicks,
  natural-scrolling/sensitivity preferences and cancellation/slop rules.
- Independent analog/pointer sequence streams, coalesced analog updates, active-axis
  refresh and immediate final neutral. Native accessibility direction/trigger/click
  actions retire the affected physical capture without releasing unrelated controls.
- UDP authentication with the session's realtime token on the same host/port as
  the WebSocket. Five hello attempts spaced 50 ms apart, matching iOS behavior.
- Every input edge is sent on UDP and mirrored immediately on WebSocket with TCP no-delay. A failed
  UDP socket, missing realtime token, or the UDP toggle leaves WebSocket delivery
  active. The host deduplicates matching generations and sequences. UDP counters
  count successful local sends, not acknowledged delivery; the existing protocol
  has no UDP acknowledgement. WebSocket loss ends the session.
- Per-pointer physical press identity, two fingers on one button, sliding handoff,
  250 ms heartbeats and active-hold refreshes. Touch edges are queued before visual
  updates, independently of Compose recomposition.
- Generation barriers and release-all on disconnect, cancellation, focus loss,
  profile replacement and backgrounding. Retired surfaces cannot re-press controls.
- Canonical profile arrays, Swift's alternating-array UUID maps, selected-profile
  identity, portrait/landscape variants, basic button shape/color/rotation/z-order,
  passive labels and starter default placement. Native size/center/clamp rules preserve
  authored aspect ratios and oversized frames. Builtin-only overrides, explicit design
  layer order, asymmetric hit regions and distinct legend/accessibility names are honored.
  All canonical shapes, per-corner radii, solid/linear/radial/tile fills, profile color
  schemes and label visibility are implemented. Profile bindings remain on the Mac.
- Native camera permission, Android local-network permission, light/dark shell,
  safe-area/keyboard insets, accessible native button labels and keep-awake while paired.

## Deliberate slice boundaries

Calibration, offline layout editing/reconciliation, installed-skin resolution,
broader symbol coverage and complete typography remain unfinished. Apple continuous
corner curves still differ from Android rounded paths. Advanced controls have
physical-device and Rust recording evidence; real Mac pointer/HID consumer acceptance
and broader device geometry remain pending. Unsupported interactive control kinds are omitted and listed above
the keypad. Basic rendering is not a claim of full iOS visual parity. Shared build
pickup/adoption, skin sharing/library, onboarding and additional settings are also
tracked in the parity checklist.

Bonjour service-only QR codes work over the shared LAN. Apple peer-to-peer-only
networking still needs an Android equivalent; this remains a parity gap. Older
receivers without input protocol v3 require an update. The existing `ws://` LAN
protocol is allowed explicitly in the manifest; this client does not introduce TLS
to the host. Six-digit pairing codes remain memory-only; saved trust is encrypted.

The initial build pins SDK/target 35 and cached toolchain versions. Upgrade the
Android target/toolchain and complete the broader device/permission matrix before
Play Store release. This is an installable development slice, not a release build.

## Verification

```sh
./gradlew :app:testDebugUnitTest :app:connectedDebugAndroidTest :app:lintDebug
```

Unit tests use the repository's real profile/template JSON and shared wire vectors.
The device test generates/decodes a QR bitmap, connects to a loopback WebSocket/UDP
host, loads a real profile and dispatches native two-pointer MotionEvents through
the controller surface. It checks matching UDP/WS frames, hold refreshes, releases,
UDP-disabled fallback, cancellation and rejection of touches from retired surfaces.
The optical camera-to-Mac-screen scan still needs a physical line-of-sight pass.

An optional live Mac test is skipped in the normal suite. Build both APKs first,
grant local network permission through the app, then run:

```sh
./gradlew :app:assembleDebug :app:assembleDebugAndroidTest
python3 scripts/verify-mac.py --cli /absolute/path/to/packaged/thumble --serial DEVICE_SERIAL
```

Add `--render-ui` to verify and capture the visible controller through the real activity
(`app/build/evidence/vertical-slice-controller.png`). This uses the same connection
entry point as the QR scanner; it does not add an intent/deep-link backdoor.

The script reads pairing data from the CLI in memory, installs the APKs, pairs,
loads the selected profile and disconnects. It refuses to replace an active phone.
`--exercise-input` is restricted to a receiver with input disabled. The native
helper can also be checked with `--native-domain DOMAIN --native-home TEST_HOME`;
use a separate app identity and `CFFIXED_USER_HOME` to keep test defaults and the
native authority lease isolated. Native checks require a realtime UDP token and,
with `--exercise-input`, assert that its receive capture confirms two simultaneous
UDP holds, both releases and a WebSocket fallback down/up pair. Nothing enables
Accessibility or stops/reconfigures your regular receiver.

Verified on 2026-10-19 with a physical Pixel 7 running Android 17: unit tests,
on-device multitouch/transport test, debug build/lint, and live pairing/profile/input
exchange with an isolated native Swift Mac helper. The helper's capture confirmed
four UDP edges and two WebSocket fallback edges, with no held inputs afterward.

Live native status is refreshed through a correlated, read-only publishStatus IPC
probe in `scripts/native-status.swift`, rather than trusting stale saved defaults.
The native UI screen test also passed on the Pixel with a real synced profile.

## Normal Mac receiver upgrade (2026-10-19)

The normal per-user Rust receiver was upgraded to the current protocol-v3 build
and installed, with its CLI and sibling bridges, under
`~/Library/Application Support/ThumbleHost/bin/`. It runs detached on port 8765,
with Bonjour and configuration writes enabled. Recording-only mode was retained
for the initial upgrade test. The subsequent real-keyboard test below enabled
input and verified macOS Accessibility permission; the normal receiver now runs
without `--no-input`.

The previous store used state schema 2 and named input slots. The receiver itself
still rejects those records: no implicit migration or legacy input aliases were
added. `scripts/prepare-receiver-upgrade.py` performs an explicit offline rebuild
for this requested upgrade, copying outputs onto each already-declared UUID and
materializing joystick direction outputs. It does not allocate or infer control
identities. The candidate was accepted by the new receiver and tested with Android
before being installed into the normal state directory.

All five profile identities/names, declared element UUIDs, layouts, selected/default
profiles, server identity, and existing trusted clients were retained. Twelve stale
Soft White Pro layer references to absent controls were omitted from the candidate.
Unused named-slot records and the old transaction history remain in the original
private backup. Configuration revision advanced from 17 to 18. The old receiver
was rebuilt from commit `15bcb61` and tested with the backup for rollback.

The private backup is `backups/android-v3-1792408500/` inside the normal state
directory. It includes the original `state.json`, `prepared-state.json`, a tested
`thumble-host.previous` binary, and `runtime-options.json`. To roll back, stop the
current host, atomically restore the original state with mode 0600, and start the
previous binary with the saved flags. Do not overwrite state while a host owns it.

Verification against the normal receiver on the physical Pixel 7 passed pairing,
protocol-v3 negotiation, decoding all five real profiles, displaying the selected
League of Legends · Lux profile, concurrent button holds, hold refreshes, and
release on disconnect. The host accepted 11 input frames with zero rejected
inputs, zero expired holds, and no held keys/elements after the test. Its companion
CLI can list the retained profiles. That initial Rust upgrade used WebSocket
fallback; the later UDP implementation and packet-loss test are documented below.
The native Swift receiver's UDP path was verified separately during the initial slice.

Upgrade preparation regression tests:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts -p 'test_prepare_receiver_upgrade.py'
```

The Lux profile still contains trackpad/joystick controls and a landscape-oriented
layout. Advanced controls remain pending; orientation locks were added in the
later session/practice milestone below.

## Real keyboard delivery on Mac (2026-10-19)

The physical Pixel 7 drove the visible native controller surface using two-pointer
MotionEvents on the real Lux Q and W controls. A focused AppKit responder received
Q down, W down (both held), W up, Q up, Q down, and Q up after touch cancellation.
This verifies application delivery through the normal Rust receiver's CGEvent
output over WebSocket fallback. The responder and receiver both ended with no
held keys, and the phone disconnected. Real input remains enabled.

To repeat after building both APKs, grant `thumble-host` Accessibility permission,
then run the following with the normal Lux profile selected. This command brings
a dedicated keyboard test window to the foreground. Keep it focused during the
test. The runner checks focus, exact key codes, overlapping holds, releases,
disconnection, and receiver output state, and sends emergency release on exit.
The general `verify-mac.py --exercise-input` recording-only guard remains in place;
real injection requires an explicit running keyboard probe and expected key codes.

```sh
python3 scripts/verify-real-keyboard.py \
  --cli "$HOME/Library/Application Support/ThumbleHost/bin/thumble" \
  --serial 2C061FDH200CJN \
  --adb "$HOME/Library/Android/sdk/platform-tools/adb" \
  --control-ids 00000000-0000-0000-0000-000000000107,41CAA0C2-FBDC-5AA6-9972-45FB5D824E6D \
  --expected-keycodes 12,13
```

Evidence is written to `app/build/evidence/mac-keyboard-events.jsonl` and
`app/build/evidence/vertical-slice-controller.png`. The probe records only events
received by its own focused responder; it does not monitor other applications.

## Rust UDP and packet-loss acceptance (2026-10-19)

The installed normal Rust receiver now listens for UDP on port 8765 alongside
WebSocket. Pairing supplies a fresh session-only realtime token. An authenticated
UDP hello binds its source endpoint to the current WebSocket connection; old
endpoints/tokens are retired on replacement, disconnect, suspension, or shutdown.
UDP accepts only protocol-v3 input/control-liveness messages, with an 8 KiB cap;
profile/configuration messages stay on WebSocket. An unavailable UDP port keeps
WebSocket working and suppresses token advertisement. IPv4 and IPv6 use separate
sockets to avoid macOS wildcard-binding conflicts.

Both lanes share core generation and sequence handling. Digital replay history
covers 4096 sequence positions and tracks ordering per control/part/press identity.
A newer packet from one finger cannot suppress another finger's delayed release.
Exact duplicate sequences and stale downs after a release remain rejected.
Token-free `realtime` counters are visible through both installed CLI status paths.

The physical Pixel 7 test used two native pointers on the visible Lux Q/W buttons
and a focused Mac AppKit responder. A test-only TCP/UDP relay forwarded the first
two distinct downs, then discarded all further UDP while Android's UDP setting
remained enabled. It dropped 23 datagrams, including all three button-up packets.
The receiver accepted two inputs through UDP and nine through WebSocket (including
hold refreshes). The Mac received exactly six key events: Q down, W down with both
held, W up, Q up, Q down, and Q up on touch cancellation. There were no rejected
inputs, expired holds, duplicate output events, or keys left held.

A separate direct Wi-Fi test against the receiver's normal port also passed:
five input frames executed through UDP and six through WebSocket, with exactly
six Mac keyboard events and no held keys. One late retired-generation copy was
safely rejected after a barrier; the harness distinguishes such expected stale
copies from unexpected rejections. Healthy UDP and WebSocket race naturally, so
the precise count accepted through each lane can vary between runs.

The relay adds 75 ms to client-to-host TCP forwarding to make initial UDP execution
deterministic. It does not change payloads or disable Android UDP. This verifies a
controlled network-loss case; it is not a measurement of ordinary network latency.

Repeat the real-keyboard command above with `--drop-udp` to run this packet-loss
case, or `--require-udp` for a direct Wi-Fi run without the relay. Both require the
normal Lux profile and Accessibility permission. Packet-loss evidence is retained
under `app/build/evidence/udp-drop/`, including `mac-keyboard-events.jsonl`,
`udp-input-result.json`, and `udp-drop-relay.json`.

The affected Rust protocol/core/host/CLI-bridge suite passed 378 tests, including
invalid credentials/endpoints, oversized/forbidden UDP packets, mirrored inputs in
both arrival orders, reordered releases, reconnect token rotation, IPv6 release
barriers, occupied-port fallback, suspension retirement, and bounded replay history.
Another 13 tests passed for the cross-platform receiver, and 177 passed for MCP
and gateway consumers after updating their status fixtures (568 Rust tests total).
The previous installed receiver, CLI bridge, and private state were backed up under
`~/Library/Application Support/ThumbleHost/backups/android-udp-1792410508/`.
All five profiles, their configuration revision, selected/default identities,
Bonjour, configuration writes, and real input settings were preserved.

## Session recovery, practice and orientation acceptance (2026-10-19)

Unit tests: 13 passing. Pixel device suite: 15 methods, 12 exercised and three
optional live-Mac methods skipped without pairing arguments. Coverage includes
Keystore encryption and fresh IVs, tamper rejection/key recovery, persisted profiles,
trusted reconnect after transport closure, no replay of old holds, explicit disconnect,
background/foreground, retained activity recreation (including before pairing acknowledgement), expired trust, wrong server identity,
changed endpoints, retired discovery callbacks, service-only QR pairing, offline
profile switching, practice suppression/release barriers, and native orientation
locks without activity recreation.

The normal Mac live recovery test passed service-only Bonjour pairing, encrypted
trust reload into a fresh client/store, and recovery from an intentionally unavailable
saved address. All five real profiles loaded, and the receiver ended disconnected
with no held inputs. Run after building both APKs:

```sh
python3 scripts/verify-mac.py \
  --cli "$HOME/Library/Application Support/ThumbleHost/bin/thumble" \
  --serial 2C061FDH200CJN \
  --adb "$HOME/Library/Android/sdk/platform-tools/adb" \
  --verify-reconnect
```

Credential-free evidence is in `app/build/evidence/session-recovery-result.json`.
The normal Mac input regression still passed after these changes: two UDP inputs,
nine reliable mirrored/fallback inputs, exactly six keyboard events, and no stuck
keys while 24 datagrams (including all three releases) were dropped in the final
retained-session regression run.

## Advanced control verification

After building both APKs and the Rust host binary, run native Android gestures
against a private recording-only receiver without changing the normal Mac profiles:

```sh
python3 scripts/verify-advanced.py --host ../Host/target/debug/thumble-host --serial DEVICE_SERIAL
python3 scripts/verify-advanced.py --host ../Host/target/debug/thumble-host --serial DEVICE_SERIAL --drop-udp
```

This dispatches native MotionEvents through ControllerSurface on the phone and
checks recorded Rust keyboard bindings, stick/trigger values and final neutral,
pointer movement/scrolling and left/right click pairs. Exact output counts detect
double execution of mirrored input. The loss relay drops UDP after the first two
control downs while leaving WebSocket delivery active. Evidence is saved under
`app/build/evidence/advanced-rust*-result.json`; credentials remain memory-only.
This is transport/receiver output evidence, not proof that a Mac game consumes the
virtual HID controller. Real pointer delivery is checked separately below.

The normal receiver was subsequently updated with the pointer ordering fix and
passed the real keyboard UDP-loss regression again (six AppKit events; all three
UDP releases dropped; no held inputs). Its five profiles and runtime options are
unchanged. The current Lux portrait screenshot still has overlapping controls;
renderer/layout fidelity remains open in PARITY.md.

## Real Mac pointer delivery

Use an Accessibility-trusted installed host binary to run against a private
input-enabled receiver and focused AppKit test window:

```sh
python3 scripts/verify-advanced.py --host "$HOME/Library/Application Support/ThumbleHost/bin/thumble-host" --serial DEVICE_SERIAL --real-pointer
python3 scripts/verify-advanced.py --host "$HOME/Library/Application Support/ThumbleHost/bin/thumble-host" --serial DEVICE_SERIAL --real-pointer --drop-udp
```

The window records only events from the private receiver process. Acceptance
requires exactly one movement, one scroll, three click pairs and one held-button
drag/release, in order, plus no held output after disconnect. Drag uses an explicit
client button hold and native trackpad movement; cancellation sends release-all.
This verifies receiver drag delivery, not a new user-facing trackpad drag gesture.
The probe restores the cursor position when it exits. The test leaves the normal
receiver and profiles unchanged and keeps pairing credentials in memory.

Both paths pass on the API 26 emulator. Receipts are
`app/build/evidence/advanced-real-pointer-result.json` and
`app/build/evidence/advanced-real-pointer-drop-result.json`, with host/test/probe
hashes and application events. Physical Android pointer UX and actual gamepad
consumer support remain open.

## Renderer acceptance

`RendererDeviceTest` verifies native geometry, rotated asymmetric hit regions,
forced profile appearance without retiring held input, canonical shapes/corners,
solid transparency, gradient endpoints/radius and all four tile patterns. It also
captures the visible saved controller in portrait/landscape with both canvas color
schemes. Evidence lives in `app/build/evidence/renderer/`, including
`renderer-result.json` and `renderer-motion.mp4`. These are development artifacts;
full skin fidelity and release performance acceptance remain pending.

## Raster assets and style states

Canonical customization asset libraries and inline raster fills now support fit,
crop, tile, nine-slice stretch/repeat, image adjustments, and all eight JPEG EXIF
orientations. Decode results are cached by content/sample size with a 32 MiB LRU;
large images are subsampled to the display frame and a maximum raster budget.
No asset URL is fetched and no image data is written by the renderer.

Style resolution follows native baseline → applicable token → inline style.
State fields inherit individually; active falls back to pressed where appropriate.
Normal and engaged faces are cached. Core fill/foreground/border/opacity/scale and
authored font/legend fields render, while visual scaling leaves the touch region
unchanged. Pointing indicators now draw in their own control layer.

`AssetStyleDeviceTest` covers image pixels, cache/downsampling, resizing modes,
EXIF orientations, adjustment mapping, state inheritance, physical ownership and
visible normal/pressed captures. Evidence is in `app/build/evidence/assets/`.
Installed skin asset hydration, full typography, cross-platform color-management and fractional-cap
comparison remain open parity work. No full skin or release-performance parity
is claimed.

## Icons and passive artwork

Text/raster icons now honor native size, placement, tint, template/original mode,
legend visibility and independent label offsets. Portable drawings cover the ten
SF Symbol names in the checked-in template vocabulary, plus common arithmetic
and playback symbols. Broader symbol coverage is still incomplete; these are
Android renderings rather than Apple glyph exports.

Artwork layers draw in separate underlay/overlay planes with normalized frames,
rotation, opacity, z/id ordering and all five native blend modes. They create no
Views, touch targets or accessibility actions. Android 26–28 uses source-over
software compositing for multiply and soft-light to preserve alpha semantics;
the remaining modes use the platform compositor. See the
[Android blend reference](https://developer.android.com/reference/android/graphics/BlendMode).
The fallback is forced-path tested on the Pixel; actual older-device performance
and the broader device matrix remain pending.

`IconArtworkDeviceTest` verifies pixels, icon modes, gesture ownership, legend
policy, passive layering and blend compatibility. Captures and the acceptance
receipt are under `app/build/evidence/icons-artwork/`. Full skin rendering,
typography and release acceptance are still open in PARITY.md.

## Control visual effects

Controls render stacked outer shadows, glow, clipped highlights/inner shadows,
bevels and state marks. Whole-face blur includes legends, icons and indicators;
visual outsets and scaling preserve the original touch region. Surface-owned caches
are bounded, and large effects use an adaptive raster budget. Shadow arrays use the
shared model's 96-point radius/offset limit.

`EffectsDeviceTest` covers pixels, state changes, physical press identity, four
simultaneous pressed faces and visible practice-mode captures. Evidence is in
`app/build/evidence/effects/`. Blur uses a premultiplied three-box approximation;
exact native kernels/color, older-device behavior and release performance remain
open acceptance work.

Trackpad accessibility Click/Right Click ends only that control's active gesture.
Existing fingers are retired until lift so an accessibility action cannot leave
pointer movement active or cause a second tap on release. Independent button holds
remain active. Local regression coverage passes; the added native-view regression
still requires a device run (see PARITY.md).

## Haptic feedback

Button activation and trackpad clicks now resolve authored haptic feedback through
the native style cascade. Single/double/pulse/buzz patterns map to bounded Android
amplitude waveforms; controls still send input first. The output respects system
haptic settings and retires pending effects on focus/lifecycle changes. On hardware
without amplitude control it retains pattern timing using default strength.

The three-box blur, portable symbols and haptic sharpness envelopes remain platform
approximations. Native-view haptic tests pass on the Pixel with a fake actuator;
the normal app preview also reaches Android’s vibration service. Physical feel and
the broader device matrix remain pending. Persistent intensity settings are covered
below; see `app/build/evidence/haptic-settings/settings-result.json` and PARITY.md.

Runtime artwork uses the native package's compiled image bytes. Shared SVG source
compilation produces PNGs; no separate vector display-list protocol was found in
these native model/renderer paths. Installed skin resolution remains incomplete.
Android references: [VibrationEffect](https://developer.android.com/reference/android/os/VibrationEffect),
[VibrationAttributes](https://developer.android.com/reference/android/os/VibrationAttributes).

## Local haptic intensity settings

Open Settings from the connection screen or controller profile menu. Choose Off,
25%, 50%, 75% or 100%; Test Haptic previews the selected strength locally and disables
at Off. The preference survives restart and forgetting a Mac, independently of
practice mode. A failed write leaves the previous value selected and reports an
error. Opening Settings releases existing touches; changing strength does not
change the Mac's profiles or input generation.

The Pixel full suite now passes 40 exercised methods (four optional live skips),
including native feedback ordering, gesture retirement, cancellation and preference
persistence/failure coverage. The portrait light-mode UI and its motion were
inspected; OS service history confirms completed TOUCH preview submissions. Tactile
comparison and the remaining settings/device/theme matrix are still pending.

Replay the recorded path with:
`argent flow run thumble-haptic-settings-final --device 2C061FDH200CJN --platform android`.
It requires the normal saved Mac reachable on Wi-Fi, disconnects before changing
local settings and restores 100%. The first connected keypad's idle warning comes
from changing transport counters; subsequent navigation targets remain stable.
Evidence and the walkthrough video are in `app/build/evidence/haptic-settings/`.

## Profile actions

The profile menu now displays the host's default keypad and can request a new
default. Portrait, landscape and automatic rotation requests require the Mac's
advertised orientation-mutation capability. Default and orientation values update
from authoritative host snapshots and persist for offline display. Offline menus
allow local default selection and disable host-only orientation changes. Attached
application targets use the native
`launch_profile_target` message with only the selected profile ID; launch is
suppressed offline, while ordinary connected practice permits an explicit launch,
matching iOS. Host rejection text remains visible.

At the initial Android profile-action rollout, the installed Rust receiver
supported default changes but lacked orientation mutation and application launch.
The source orientation path is now verified below; normal receiver deployment and
application launch execution remain open. No normal Mac profiles were changed.

`ProfileActionsTest` covers native payloads, capability guards and default metadata.
`ProfileActionsDeviceTest` passes all four methods in an isolated API 26 emulator:
actual client WebSocket requests/authoritative replies, private snapshot reload and
an accessible offline menu. Broader UI/device acceptance remains pending.

The full isolated API 26 suite passes 43 exercised methods, with four optional live
skips and one API-29-only method not applicable. This found and fixed a real minimum-
API JPEG orientation failure: asset metadata now uses AndroidX EXIF 1.4.2, and the
fixture independently encodes all eight EXIF orientations. See
[AndroidX EXIF](https://developer.android.com/jetpack/androidx/releases/exifinterface).
Evidence and the inspected offline menu capture are under
`app/build/evidence/profile-actions/`. The dedicated `thumble-parity-api26` AVD remains
available, with its emulator shut down after verification.

Rust source orientation support now passes Android interoperability on the API 26
emulator. From the repository root, run:

```sh
python3 Android/scripts/verify-profile-actions.py --host Host/target/debug/thumble-host \
  --serial emulator-5554 --adb "$ANDROID_SDK_ROOT/platform-tools/adb"
```

It starts a private input-disabled receiver,
verifies the default and all three orientation preferences with exact metadata-only
state changes, and stops it. Evidence is in
`app/build/evidence/profile-actions/rust-profile-actions-result.json`.
At that orientation source milestone, the normal installed receiver had not yet been upgraded.
Rust source launch execution is covered below; the remaining parity inventory is open.


## Attached Mac application launching

Android's Launch action now executes in the Rust Mac runtime. It resolves only the
Mac's stored target and releases held input before activation. Failures preserve
the connection. The corresponding Rust CLI command is
`thumble-host launch-profile [PROFILE_UUID] --json`; completion is exposed under
`applicationLaunch` in host status. The command initially reports queueing.

After building both Android APKs:

```sh
cargo build --locked --manifest-path Host/Cargo.toml -p thumble-host
cargo build --locked --manifest-path Host/Cargo.toml -p thumble-host --example application_launch_fixture
python3 Android/scripts/verify-application-launch.py --host Host/target/debug/thumble-host \
  --serial emulator-5554 --adb "$ANDROID_SDK_ROOT/platform-tools/adb"
```

This creates a private input-disabled receiver and a disposable Mac application.
The API 26 emulator passes actual launch/activation through stored path, scoped
bookmark, foreign-bookmark path fallback and bundle ID. A missing target retains
the connection and existing hold; successful launches release the recorded key
while the client remains paired. All private receivers and fixture processes exit,
and the app is unregistered and removed. The normal receiver/profiles are untouched.

A scoped bookmark belongs to its creating code identity; the private harness
creates one in its own receiver process and uses production runtime code. It does
not imply that a bookmark can transfer scope across app identities. Source-hashed
receipts live under `app/build/evidence/profile-actions/rust-application-launch-result.json`.
Normal installation and Swift CLI launch routing were completed in the follow-up below.
Application attachment editing and the remaining parity inventory are still open.


## Normal receiver deployment and Swift CLI launch

The tested Rust host, standalone Swift `thumble` CLI and sibling CLI bridge are now
installed in the normal per-user setup. The existing private state and four old
binaries are backed up; their location and all old/new hashes are recorded in
`../build/AndroidReceiver/launch-install-receipt.json`. Profiles/trust, port 8765,
Bonjour, real input, configuration writes and Accessibility access were preserved.

```sh
thumble profile launch [NAME|UUID|active|default] [--json]
thumble status --json
```

The exact sibling bridge accepts only a bounded typed selector. The running host
resolves it and queues the same launch operation used by Android; it never accepts
remote application target metadata. The initial acknowledgement is not completion:
inspect `response.status.applicationLaunch` in CLI status. Launch failure reports a
coded status while preserving the paired client. Existing legacy routing still
uses its authority checks; Rust failures never fall back to local profile opening.

Final acceptance covers all four Swift selectors against actual private app
activation, five Android launch cases, and post-install real keyboard input with
UDP loss on the API 26 emulator. The latter produces exactly six AppKit key events,
using 2 UDP + 9 WebSocket inputs, with every dropped release recovered and no stuck
input. All five profiles and non-trust configuration remain unchanged.
`app/build/evidence/profile-actions/rust-launch-routing-acceptance.json` records the
checks; the reusable updater is `scripts/install-receiver-update.py` (read-only
preflight by default, explicit `--install` for updates).


## Skin package and private library foundation

Android now has an internal bounded `.pocketpad` archive loader and atomic private
package store. It checks native archive budgets, ZIP/ZIP64 headers and entry kinds,
paths, CRCs, SHA-256 payload descriptors, duplicate JSON keys, core manifest and
compatibility fields, and common asset/style references. The store keeps original
archive bytes and supports version policies, reload, exact export and removal;
physical filenames are hashes, so version text never becomes a filesystem path.

`SkinPackageTest` adds twelve unit checks, including four unchanged native package
fixtures and malformed/corrupt/compression-bomb inputs. The full JVM suite passes
69 tests. `SkinPackageDeviceTest` passes two methods on API 26, including atomic
storage/reload/export, corrupt replacement recovery and native package PNG decoding
through the existing asset renderer. Website package files are test-only resources
and are not bundled into the production APK by these source-set changes.

Evidence: `app/build/evidence/skin-packages/acceptance.json`, `device-result.json`
and retained logs. Full semantic normalization, skin compatibility/application,
live asset hydration and package sync, and library/import/share screens remain
open. These foundation classes are not yet wired into the controller UI/client.


## Native skin appearance stages

The pure Android resolver now matches native-generated orientation/theme/action-set
selection, role/control cascades, local override baselines, style/asset library
merging, image hydration and corner/silhouette rules. The oracle is generated by
Swift tests and shared by JVM and API 26 instrumentation; see
[fixture provenance and regeneration](../Host/fixtures/skin-resolution/v1/README.md).
The current suite passes 73 JVM tests and three API 26 skin resolver methods, with
build/lint and Swift stack safety passing. Evidence is retained under
`app/build/evidence/skin-resolution`.

The canonical whole-profile resolver below extends these appearance stages. Full
model normalization, live skin hydration and skin-management/sync UI remain open.


## Canonical whole-profile skin resolver

Whole-profile resolution now includes backgrounds, artwork, declared buttons,
custom controls, the system toggle and control-bar items. Compatibility checks
match native template/revision and captured-geometry behavior, including hiding
aligned artwork when incompatible while retaining semantic styling. Saved input
identities, bindings and geometry stay intact.

Swift-generated expectations cover 86 full results, 21 compatibility cases,
geometry for 22 fixture layouts and all 68 canonical native canvases. The current
JVM suite passes 76 tests and the combined API 26 profile/appearance suite passes
six methods; builds, lint and Swift stack safety pass. Evidence is under
`app/build/evidence/skin-profile-resolution`.

The engine currently accepts canonical validated model JSON. Full decoding and
normalization, live controller/library integration, apply/detach persistence, sync,
import/share UI and device renderer acceptance remain unfinished.


## Strict skin appearance models and portable text

Imported skin appearances now pass strict native-compatible model decoding before
validation/storage. Nested field types, defaults, empty/duplicate rules, fills,
image caps/insets, shadows, icons, haptics and typography are normalized. Base-bank
style validation uses the native cascade. Malformed replacement imports preserve
the installed package.

Portable native text tables fix API 26 joined-emoji truncation and match Swift
across 1,859 grapheme inputs plus full-domain character-set checks. See
[Unicode provenance](unicode/README.md) and the
[native model oracle](../Host/fixtures/skin-resolution/v1/README.md).
All 83 JVM tests and 13 API 26 skin methods pass, with builds, lint and Swift stack
safety. Evidence is under `app/build/evidence/skin-model-normalization`.

Full manifest/captured/profile normalization, live skin application, persistence,
sync and skin-management UI remain unfinished. Full Android/iOS parity is still open.


## Typed captured skin contracts

Compatibility and complete captured metadata now pass strict typed decoding before
package validation, including control presentation, native surface/chrome paint,
layout matrices and requested/resolved appearance evidence. Normalization and
validation phase order matches native archive reading. Canonical string identities
and Core Graphics array behavior have native regression cases; malformed captured
metadata cannot replace an installed package.

The oracle compares 217 inputs and complete normalized outputs/package acceptance.
All 87 JVM tests and 17 API 26 skin methods pass, along with builds, lint and Swift
stack safety. Evidence is under `app/build/evidence/skin-contract-decoding`.
Full manifest metadata, profile normalization, live skin integration, persistence,
sync, library/import/share UI and release acceptance remain open.


## Live installed-skin rendering

The Android controller now resolves an exact installed skin reference on a worker
and renders its hydrated projection. Saved profiles and host bindings stay intact.
It respects orientation override baselines and the primary theme preference,
caches one archive/projection, waits before enabling a new appearance, and falls
back visibly when a package is missing or mismatched. Library invalidation handles
removal/reinstallation; unchanged projections preserve held touches.

All 90 JVM tests and 25 API 26 skin/asset methods pass, with build/lint and Swift
stack safety. The real activity acceptance installs an unchanged existing package,
checks displayed pixels, compatibility gating, touch retention/release, unchanged
saved data and removal/reinstallation refresh. Evidence is under
`app/build/evidence/skin-live`. This proves the installed-package rendering path;
full native visual fidelity, dynamic action sets, import/share/library UI,
apply/detach persistence, Mac skin sync and full Android/iOS parity remain open.


## Skin lifecycle and pending choices

The controller menu can import a `.pocketpad` document for metadata review, apply
an installed skin, or detach its resolved appearance. Applying/reapplying saves
override baselines and package asset references; detaching retains materialized
appearance. Profile snapshots and pending choices share one atomic private file.
Failed saves preserve the previous keypad, and ordinary snapshot updates retain
pending intent until an authoritative matching profile reference acknowledges it.
The capability-gated client replays archive-before-selection on reconnect and
ignores scalar layout messages as acknowledgments.

Native-generated coverage compares 44 complete profile transitions. API 26 native
review/menu, persistence, restart/reconnect, malformed-journal and save-failure
checks are retained under `app/build/evidence/skin-lifecycle`. The system document
picker is wired but its navigation/selection is not yet exercised; the test feeds
the selected bytes through the same import worker. Full visual/motion/theme
acceptance and the complete library/preview/share/remove interface remain open.
The normal Rust receiver does not yet implement skin sync; pending Android
choices remain queued when the Mac lacks those capabilities. Full parity is open.

This milestone passes 93 JVM tests, combined API 26 acceptance (36 reported
methods, 34 exercised/two optional live skips), debug builds/lint and Swift stack
safety. A separate normal-Mac keyboard UDP-loss regression confirms six real
AppKit events and complete release through fallback.


## Incoming skin synchronization

Authenticated handshakes, profile snapshots and standalone skin messages now
install packages on a bounded worker using native downgrade/replacement behavior.
Malformed typed Data cannot commit profiles, invalid archives preserve prior
files, and other valid packages in the batch still install. Initial skin-backed
profiles wait for that batch; unrelated/exact resyncs preserve held touches.
Active replacements release retired captures, and inactive package changes clear
the decoded cache. Overload reconnects for replay rather than dropping a batch.

The milestone passes 97 JVM tests and combined API 26 acceptance (40 reported
methods, 38 exercised/two optional live skips), builds/lint and Swift stack safety.
Evidence: `app/build/evidence/incoming-skin-sync`. The normal Rust receiver still
needs skin-store/selection/removal support and CLI routing; controlled-host client
acceptance does not establish real Mac skin synchronization or full parity.

## Real Mac skin sync

Authenticated package upload/download and skin apply/detach now work with the Rust
Mac receiver and its native Swift bridge. The receiver persists a selection before
acknowledging it; Android retains unacknowledged selections across reconnects.
The CLI uses the same receiver-owned archive library and profile authority.

A physical Pixel 7 passed initial package replay, native import review and upload,
apply/detach acknowledgement, a CLI-driven skin replacement with held-capture
release, and trusted reconnect after receiver restart. Exact archive export and
invalid/in-use rejection also passed. This test uses a real receiver with private
Mac state; it does not replace the normal installed receiver or change its profiles.
See `PARITY.md` for evidence, reproduction and the remaining UI/rendering gaps.
