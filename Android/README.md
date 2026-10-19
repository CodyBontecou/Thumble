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

Calibration, offline layout editing/reconciliation, haptics, installed-skin resolution,
vector display lists, broader symbol coverage and complete typography remain unfinished. Apple continuous
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
virtual HID controller or that pointer input has reached an AppKit view.

The normal receiver was subsequently updated with the pointer ordering fix and
passed the real keyboard UDP-loss regression again (six AppKit events; all three
UDP releases dropped; no held inputs). Its five profiles and runtime options are
unchanged. The current Lux portrait screenshot still has overlapping controls;
renderer/layout fidelity remains open in PARITY.md.

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
Vector assets, installed skin asset hydration, full typography, cross-platform color-management and fractional-cap
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
receipt are under `app/build/evidence/icons-artwork/`. Full vector/skin rendering,
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
