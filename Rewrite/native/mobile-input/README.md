# Native phone input module

Native input libraries target iOS 17+ and Android API 26+. The isolated Android platform TLS adapter requires TLS 1.3/ALPN support (API 29+); this does not lower the input core baseline or settle the final launch OS matrix. The UIKit surface and Android `View` consume native touch events and sample from native display callbacks. React owns presentation and configuration; it never receives the touch queue or schedules controller packets.

The Swift package exports `MobileInputCore` and `MobileInputUIKit`. The Android library produces an AAR containing the same engine/surface contract and the generated Kotlin gamepad DTO. The portable `@thumble/client/mobile-input` entry validates configuration and checks local native activation receipts. Isolated native TLS clients now exchange control and sealed input frames with the synthetic recording receiver. React Native application/bridge wiring, device enrollment, native network-worker integration, OS input and retained profile storage remain pending.

## Activation and ownership

A control map contains version 1, canonical decimal u64 generation/revision strings, and 1–64 normalized rectangles. Native and TypeScript validators check finite geometry, minimum dimensions, viewport bounds, unique bounded IDs and known semantic actions. Generations strictly increase; revisions cannot go backwards. Native configuration validates completely before releasing the previous map. Receipts acknowledge only the local native map, not a host profile transaction.

Rectangle order is paint order: the last hit region wins. Sticks capture one finger per semantic stick, normalize to a circular range and retain capture outside the rectangle. Buttons and held triggers contribute while their own captured rectangle contains the finger. Multiple fingers/controls mapped to one semantic button are reference counted. Touch IDs are independent of Android pointer-array indices. At most 16 touches are captured. Unknown delayed moves/ends never create a new capture.

Create an `InputEngine` on the native UI thread, give it a nonblocking native output sink, install a validated map on `InputSurface`, and admit the acknowledged generation through the native owner. A sink returns `false` on backpressure/disconnection; native state becomes neutral and disconnected. Kotlin also retires state on callback exceptions. Swift enforces main-actor isolation; Kotlin checks its owner thread.

Every connected event and native tick emits a full semantic state with a generation and strictly increasing decimal sequence. Local feedback observes the same native state. Practice mode releases host state first, then provides local feedback without output. Idempotent practice settings preserve touch tracking.

Touch cancellation, backgrounding, screen lock, rotation/resize, profile replacement, disconnect, practice transitions and disposal release all touches. Any retired connection requires a fresh activation generation before reconnecting; prior touches never replay. Disposal is terminal. Surface callbacks fence touches predating map installation, and native sampling does not depend on React renders. A host receiver lease remains the independent fallback when a native sender or transport fails.

## Headless checks

From `Rewrite/`:

```sh
bun install --frozen-lockfile
bun run mobile:prepare
swift test --package-path native/mobile-input/ios
bun run mobile:ios:sdk --sdk iphonesimulator
bun run mobile:ios:sdk --sdk iphoneos
```

The SDK commands produce static libraries/modules and SHA-256 metadata under ignored `reports/`. They compile the actual UIKit surface; they are not signing, installation or gameplay acceptance. The Swift fixture preparation copies canonical test resources into an ignored test-only directory. No duplicate fixture becomes an independent authority.

From `Rewrite/native/mobile-input/android/`, with JDK 17 and an Android SDK containing platform/build tools 35:

```sh
./gradlew --no-daemon testDebugUnitTest assembleDebug lintDebug
```

Gradle 8.11.1, AGP 8.9.1 and Kotlin 2.1.20 are pinned. The wrapper distribution checksum is pinned and its upstream license/notices are retained. Android build products, caches and local SDK paths are ignored.

Both languages execute all 34 retained report vectors and the canonical `packages/fixtures/mobile-input-v1.json`: 15 scenarios, 102 event expectations. Additional tests cover malformed maps, bounds, immutable ownership, transport failure, terminal disposal and thread safety. The TypeScript suite validates the same expected semantic states/report bytes and the bounded configuration client.

`.github/workflows/typescript-rewrite-mobile.yml` separates native SDK/library checks from the portable host matrix. It runs Swift tests, direct SDK compiles, generic iPhone/Simulator Xcode package builds, Android unit tests, AAR assembly and lint. The packet snapshot passed hosted native SDK checks; later native TLS client changes require their own publication and CI evidence. Physical multitouch, haptics, native sample timing under JS load, authenticated delivery and real games remain later acceptance requirements.

## Authenticated input packet layer

`InputPacket.swift` / `InputPacket.kt` implement the native v1 AES-256-GCM sender, receiver and bounded output channel. The channel can serve directly as the input engine's native output callback. It checks generation and contiguous native sample sequence, owns encryption, and fails neutral through the engine on transport rejection. It has no JS callback, backlog or network listener. Actual UDP/TLS socket selection remains to be connected by the native networking adapter.

The Rust receiver library exposes the matching packet codec plus `PacketRuntime`, which applies authenticated states through the existing native safety owner. Native leases, held-input TTL, explicit release, monotonic clock checks and a ten-minute grant cap remain independent of JavaScript. Ciphertext replay never renews input TTL, newer neutral snapshots repair lost releases, and generations retire old packets. The CLI's current recording-only process still exposes only its existing private local seam; it does not accept LAN packet grants.

All three native languages match 33 deterministic packet vectors and reject five validly authenticated malformed payloads. A standalone Node/OpenSSL verifier checks the same exact ciphertext/tag/header bytes independently. See `docs/adr/0002-rewrite-input-packet-v1.md` from the repository root. Test keys in these fixtures are public constants. Production keys must arrive through a fresh authenticated native grant and never enter React or profile documents. Pinned host-authenticated TLS libraries exist; phone enrollment, persistent trust/secure storage, product socket routing and physical acceptance remain unfinished.

## Isolated native TLS clients

`ControlTLS.swift` uses Network.framework with TLS 1.3, fixed ALPN/server name, exact leaf pinning and standard Security.framework certificate policy. Its native main-actor interface does not depend on the React runtime. It keeps one frame in flight, at most eight queued control frames and one replaceable latest sealed input snapshot. Coalescing never re-encrypts a packet, and the receiver accepts the newest authenticated full state. Queue overflow, two-second frame deadlines, cancellation and TLS failure terminally close the client. A reconnect requires a new client and fresh grant.

`ControlTLS.kt` provides immutable bounded frames and a full-duplex blocking platform SSLSocket client owned by bounded native reader/writer workers. It validates the exact pin and normal certificate policy, explicitly checks server-auth key usage, forces TLS 1.3/ALPN, and uses a fresh SSLContext for every connection. A deadline watchdog closes the socket to interrupt blocked I/O; lifecycle close can run on any thread. This blocking interface is not an input-engine callback. `NativeTLSDelivery` now provides the nonblocking input sink: one input snapshot slot, eight outgoing controls and eight incoming native control frames. Two native workers isolate blocked reads from writes; a terminal transition discards pending frames before a separate bounded closer interrupts socket I/O. Product enrollment, reliable/UDP routing and reconnect coordination remain required. Older providers fail instead of downgrading; [Android documents TLS 1.3 support from API 29](https://developer.android.com/reference/javax/net/ssl/SSLSocket).

Local integration tests launch the Rust `control_tls_probe` when `THUMBLE_NATIVE_TLS_PROBE` points to its executable. The prepared mobile workflow builds and configures this witness before tests. Without it, socket interoperability tests are explicitly skipped. Both platform paths exchange control and deterministic encrypted input with real TLS, reject replay, and reject wrong pins and pinned certificates with invalid dates, names or server usage. JVM checks exercise the library with the host JDK provider; they do not prove Android's device provider or physical networking. iOS direct SDK builds compile actual platform code. No bootstrap secret, private certificate key or production credential is present in these witnesses.

## Native credential vault

`PhoneCredential.swift` / `PhoneCredential.kt` provide an opaque native record and verified-readback vault. Swift configures a noninteractive device-only Keychain record; Android encrypts app-private no-backup records with an AndroidKeyStore AES-GCM key (API 29+). Both enforce host binding, strict epochs and explicit failure/forget behavior. See `docs/rewrite-phone-credentials-v1.md` for format, policies and test limits. Native enrollment-client wiring remains pending.

Local verification covers 27 Swift tests, 46 Android tests, both iOS SDK compiles, Android AAR/lint, iOS build-for-testing and Android instrumentation APK compilation. The iOS-only synthetic Keychain test and Android synthetic Keystore instrumentation test are prepared but have not executed on OS providers. Hosted enrollment snapshot 9e2f643 excludes all newer vault source.

## Native enrollment clients

`PhoneEnrollment.swift` / `PhoneEnrollment.kt` negotiate control version 2 over the existing pinned TLS transport. They match the invitation authority before proof, persist an opaque credential before acknowledgment, and require the final host completion reply before reporting success. Input remains disabled. Swift runs storage on a native actor; Android's production API requires a worker. Strict shared fixtures cover duplicate/escaped keys, malformed UTF-8, unsupported types and bounds. Actual Network.framework and JDK TLS tests enroll against the synthetic Rust ledger. React Native app wiring, listener/service forwarding, session grants and real phone/gameplay acceptance remain pending.

The mobile workflow now builds both synthetic TLS examples and supplies their paths to tests. It also prepares headless iOS Simulator Keychain and Android API 35 Keystore jobs. Provider result checks require the specific non-skipped test to pass; build-only evidence does not satisfy them. New client/vault source and provider jobs require their own publication and hosted execution.
