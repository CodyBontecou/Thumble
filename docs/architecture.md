# Architecture and release gates

## Product contract

- JavaScript React Native application for iOS and Android.
- Familiar Xbox-style landscape controller: two sticks, D-pad, ABXY, bumpers, triggers, stick clicks, View and Menu. Multitouch is required.
- Minimal macOS menu-bar receiver with QR pairing, input diagnostics and WoW setup help.
- Local Wi-Fi only for launch; one active phone per receiver as an initial implementation assumption.
- Layouts and mappings are declarative. Players edit them visually in the phone's layout editor and the desktop workspace; the local MCP tools edit the same profiles.
- Public App Store and Google Play launch target: November 4, 2026. Signed/notarized direct Mac distribution is the initial proposal, subject to the HID path. A Mac App Store release has not been assumed.

## Component boundaries

`packages/controller` exists now. It owns profile validation, default layout data, canonical gamepad output, input normalization, profile replacement, and a stale-input watchdog. The module has no platform dependencies and uses JavaScript with no TypeScript build step.

`apps/mobile` now contains an Expo/React Native JavaScript controller, QR/manual pairing, preliminary WoW setup guide, and a local Expo native module for pinned URLSession/OkHttp WebSockets. Use native networking where required; [Expo's custom native code documentation](https://docs.expo.dev/workflow/customizing/) supports that workflow. Gamepad state lives outside React render state. The first touch adapter is JavaScript; native capture/transport and release-build latency measurements are still required before claiming low latency. Keep packet delivery separable from labels, geometry and rendering.

Planned renderer: a small 2D controller scene with normalized coordinates, deterministic hit regions, z-order and touch ownership. React Native views provide accessible labels and onboarding; Skia may draw control surfaces if profiling justifies it. A general 3D game engine is unnecessary for the launch controller. Preserve a renderer-independent JSON contract so richer scenes can be added later.

`apps/receiver` implements the Swift menu-bar shell, native LAN receiver, ephemeral TLS identity, watchdog, and HID adapter. Platform-specific code is necessary to publish a macOS device; JavaScript remains the shared configuration language. The HID implementation is conditional on a distributable entitlement/driver path and verified game detection.

The signed diagnostic now creates a device with Thumble's approved development profile. Its retained Xbox-compatible descriptor enumerates as an extended gamepad in a separate GameController process; the generic descriptor does not. See the [recorded results](research/macos-virtual-gamepad.md). Keep the new app implementation separate from the old Thumble repository; retain only focused native contracts and signing identifiers where justified. The product display name is Thumble. Internal workspace/module names and legacy storage keys retain tapping for compatibility.

Implemented MCP adapter: `packages/profile-tools`, a local stdio process exposing schema, list, get, validate, save, activate and status operations. Whole-profile replacement uses expected revisions to prevent lost edits. An atomic store preserves the active snapshot while a new saved revision is edited. A utility queue watches activations; the receiver releases controls, invalidates old leases, publishes the layout and waits for the phone renderer acknowledgement before issuing a fresh lease. The adapter configures controllers and is outside the input-delivery loop. See [profile workflow](agent-profiles.md).

## Input and connection design

Implemented pairing: a short-lived QR invitation contains a receiver address, pinned identity and single-use secret. A cryptographic handshake establishes an authenticated encrypted session. Do not send a reusable bearer secret in every cleartext input packet. Use an established secure transport rather than custom cryptography. Re-pair/revoke is available from the menu bar. Handle camera denial with a manually entered pairing invitation.

The current vertical slice uses native TLS WebSockets with immediate full-state transitions, 33 ms heartbeats, TCP no-delay and server-clock freshness leases. It releases on stalls and requires neutral recovery. See [protocol v1](lan-protocol.md). Protocol v2 adds layout distribution, renderer acknowledgement and input revision checks; legacy v1 clients support only the built-in layout.

Before release, separate reliable configuration traffic from fresh input. Prototype a native datagram or unordered data-channel path and benchmark it against a simple persistent connection. Select transport after measuring on physical devices. Never queue old analog positions behind configuration or telemetry. Button press/release edges need acknowledgements and bounded retransmission: full-state UDP snapshots alone can lose a short tap entirely. Include full-state heartbeats to repair losses and release held inputs.

Authenticated input must include session identity, profile revision and a monotonically advancing sequence. Reject stale sessions/revisions, duplicates and reordered snapshots; handle sequence wrap explicitly. A fresh authenticated session is required to take over. Expired-session traffic must never re-arm input. Native HID report encoding owns the conversion from canonical axes (positive Y up) to the actual descriptor and WoW mapping.

Touch cancellation, app background, screen lock, profile replacement, explicit disconnect, process shutdown and receiver timeout all release every control. The shared watchdog defaults to 150 ms; the native Wi-Fi receiver uses 300 ms after physical hold testing exposed 150–190 ms arrival gaps. Its separate server-clock lease budget is 500 ms to cover the return/forward exchange; timeout still revokes all leases and requires fresh neutral recovery. It must run in the native receiver on a timely clock even if the UI is busy. Configuration, rendering and MCP work must not delay it.

## Latency measurement

Initial engineering budget: target p95 touch-to-HID under 20 ms on a controlled local network, subject to validation. This is a target, not measured performance or a guarantee on arbitrary Wi-Fi. Send edges immediately; test analog updates at 120 Hz with no backlog. Report input age, loss, jitter and p50/p95/p99.

RTT does not equal one-way latency. Measure native capture → receiver → HID timestamps with a documented clock-offset/error estimate, and use high-speed video for touch-to-visible-game response. Keep input-to-HID separate from WoW's frame time, rendering and server/network response. Stress with multitouch, background CPU load, loss and a congested AP on physical iOS and Android hardware.

## Release gates, in order

1. **macOS feasibility:** create a gamepad under a supportable signed distribution model; observe all controls in a separate process; verify Forever and ConsolePort detection. Establish required Apple entitlement, minimum OS and supported architectures. A root-only lab prototype is not a consumer-ready path.
2. **Vertical slice:** phone touch → authenticated LAN session → native HID → movement/action in WoW, with release-on-disconnect. Run on one physical iPhone and one Android phone.
3. **Controller and configuration:** concurrent sticks/triggers/buttons, ergonomic landscape layout, profile validation/revisions and reliable activation. A scene/rendering engine must earn its cost in this step.
4. **Onboarding:** QR, permissions, pairing retry, controller test and Forever-specific addon setup. Test a fresh Mac user account and clean game configuration.
5. **Public distribution:** enrolled developer accounts, app identifiers, signing/provisioning, store listings, privacy/support pages, reviewer instructions and a receiver download accessible to reviewers. Establish Apple/Google account-specific review/testing requirements. Submit early; review outcomes and entitlement approvals are external dependencies.
6. **Launch:** measured latency and game compatibility evidence, signed/notarized receiver, accepted store builds, recoverable errors, revocation and a tested support path. Do not substitute keyboard emulation and call it virtual HID compatibility.

The deadline is twelve calendar days from the initial planning date. These are acceptance gates, not a day-by-day guarantee. If gate 1 cannot be cleared through a distributable route, escalate the platform/date tradeoff before spending the remaining schedule on UI polish.
