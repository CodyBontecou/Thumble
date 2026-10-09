# Virtual controller support: implementation and acceptance gates

## Implementation follow-up (2026-10-03)

The approved implementation is now present in both receivers. **This is not yet a signed-device or game-compatibility certification.** Read-only inspection found no local provisioning profile authorizing `com.apple.developer.hid.virtual.device` for either `com.codybontecou.PocketPadMac` or `com.codybontecou.ThumbleHost`. Apple approval must be confirmed for the exact App ID and distribution scope; the two receivers are separate provisioning identities.

Implemented:

- A canonical [Swift report codec](../Sources/Shared/VirtualGamepadReport.swift) and [shared 34-vector fixture](../Host/fixtures/gamepad/v1.json), consumed by Rust tests: ID `1`, ten bytes, neutral `01 00 00 08 00 00 00 00 00 00`, eight hat directions/null `8`, unitless signed eight-bit sticks, and independent unsigned triggers. Digital trigger holds force full pressure; release restores independently held analog pressure. Eight-bit resolution is retained for this implementation, not certified as a final shipping choice.
- Correct current-state GetReport, explicit type/ID/capacity errors, unsupported SetReport, initial-neutral-report readiness, strict signed Boolean claim inspection, failure neutralization, and retained asynchronous cancellation. Failed devices latch until owner-controlled recovery; a new partial input cannot silently restore an inconsistent subset of held outputs.
- Rust captured mixed bindings/refcounts, lossless unknown persisted gamepad names without raw output, authenticated analog generation/modular sequence checks, finite-value rejection/clamping, dropped-release expiry, and full lifecycle neutralization. Local release/configuration/profile replacement retires the input generation and notifies the phone, preventing queued old inputs from restoring a hold.
- A thread-confined Rust HID owner, bounded command channel/waits, and no unsafe `Send` for CF objects. A timed-out operation can remain pending on that owner; it is not proof that cancellation completed. Recording sends no OS input and never claims HID-ready.
- Receiver-owned installed-control taps/holds, shared physical ownership, strict output-failure propagation/partial cleanup, and a 30-second held-test expiry. Controller-only tests do not require Accessibility; keyboard-bearing tests do. Swift direct element outputs also respect keyboard mode.
- Optional boxed Mac/iPhone readiness and CLI status/doctor/retry/test parity. Runtime commands use a separate correlated, bounded IPC envelope and never use offline mutation fallback. Rust socket/authority failures cannot fall through to stale legacy defaults. Legacy notifications require fresh PID/instance/request correlation, and mutations are scoped to the verified receiver instance.
- Swift workspace sleep handling releases/disconnects and retires HID before restarting on wake. Rust uses a sleep-inclusive continuous input clock; a scheduling gap over 1.75 seconds neutralizes output and retires all input connections on the first resumed input/poll turn, including legacy frames. OS sleep/wake behavior still needs a real signed-device test.
- Main-receiver-only [GUI](../Resources/Mac/ThumbleMac.entitlements)/[Rust](../Resources/Host/ThumbleHost.entitlements) entitlements and [final-artifact verification](../scripts/verify-hid-signing.py). Both release paths gate authorization before notarization/publication. Helpers, CLI and MCP remain unprivileged.

Verification completed locally:

- Full Swift suite: **368 tests passed**, after building `ThumbleCLI` into the same derived-data products directory used by CLI smoke tests.
- `./scripts/verify-stack-safety.sh`: constrained-stack/inline-size regressions, Mac network-frame budgets and Mac/iOS Debug builds passed. No thread-stack increase was used as a fix.
- `CARGO_BUILD_JOBS=2 ./scripts/verify-rust-host.sh`: capability/parity checks, formatting, all-target/all-feature Clippy, workspace tests (**512 reported passed**, zero ignored) and package checks passed with the pinned Rust toolchain.
- Signing verifier: **21 synthetic tests passed**; both release scripts passed `bash -n`.
- Independent compatibility probe typechecked. No release script, account mutation, installation, live OS input, or publishing was performed.

### Operator commands

Only one receiver may own input. Use the packaged CLI/helper siblings or install the matching validated `thumble-cli-bridge` beside a development `thumble` executable; a missing/untrusted helper intentionally fails closed. `thumble status`, `release-all`, and `gamepad` commands route to the owning receiver, not an offline profile backend.

```bash
thumble gamepad status --json
thumble gamepad doctor
thumble gamepad retry
thumble gamepad test UUID                    # declared control UUID, released tap
thumble test down --element UUID#part
thumble test up --element UUID#part
thumble release-all

# Native Rust receiver CLI: use exact opaque IDs returned by controls.
thumble-host controls --json
thumble-host gamepad status --json
thumble-host gamepad doctor
thumble-host gamepad retry
thumble-host gamepad test element:UUID tap
thumble-host gamepad test element:UUID down
thumble-host gamepad test element:UUID up
thumble-host release-all
```

Down holds expire after 30 seconds. Legacy tap `--hold-ms` is restricted to `0...1000`; Rust taps use the receiver's minimum-duration policy and reject that legacy duration override. Recovery releases captured input before retrying. `ready` means a successful initial neutral HID submission, not GameController/SDL/Steam recognition. `entitlementGranted` is the legacy-named field for the inspected signed Boolean claim; release-profile authorization is independently checked.

MCP `host_status.output.virtualGamepadStatus` exposes Rust readiness, and opt-in `press_control` supports installed controller-only taps. MCP retry and down/up holds are **not implemented**; the [capability ledger](mcp/cli-capabilities-v1.json) records these limitations rather than claiming parity.

### Remaining signed/live acceptance

Obtain matching approved profiles through the normal provisioning workflow, without assuming that a grant for one receiver or distribution covers the other. Verify each final development/Developer ID bundle separately:

```bash
python3 scripts/verify-hid-signing.py '/path/Thumble Mac.app' --require-hid \
  --bundle-id com.codybontecou.PocketPadMac --distribution development
python3 scripts/verify-hid-signing.py '/path/Thumble Host.app' --require-hid \
  --bundle-id com.codybontecou.ThumbleHost --distribution developer-id

# Rust packaging, only when authorized to sign/package (not executed here):
scripts/release/macos-host.sh --sign 'Developer ID Application: …' --hid-profile '/path/approved.provisionprofile'

# Separate consumer process, while the signed receiver/phone are active:
swift scripts/probe-gamepad-compatibility.swift 3 > /tmp/thumble-gamepad-observation.json
```

The [read-only probe](../scripts/probe-gamepad-compatibility.swift) never creates a controller or injects input. It records matching IOKit devices, descriptor hash/raw element values, `supportsHIDDevice`, GameController enumeration/profile/state, and OS version. It is a snapshot, not an automatic compatibility pass; compare an off/on baseline and exercise each control while collecting observations.

For **each receiver**, record artifact/signature/profile scope and executable/package hash, descriptor hash/identity, OS/architecture, then verify all buttons/menu/select/stick clicks, all eight hat directions plus neutral/opposites, both sticks including Y polarity, independent/digital triggers, overlapping mixed outputs, dropped releases, disconnect, mode/profile/orientation replacement, CLI recovery, sleep/wake, shutdown and disappearance. Repeat with SDL raw joystick **and** semantic gamepad mapping (record GUID/mapping/library version), Steam Input on/off and actual named games. Minimum macOS 14/Intel runtime acceptance is also outstanding. Do not infer Xbox protocol, XInput, rumble, or universal game compatibility from generic HID publication.

The original investigation/plan below is retained as the baseline and primary-source rationale. Its repository observations describe `d9e3e52`, not the updated implementation.

## Original recommendation

Treat “proper controller support” as **the paired iPhone appearing as a real, system-wide Mac gamepad**: buttons, D-pad, two sticks, and independent analog triggers, while preserving mixed keyboard/pointer output.

**Prove signing and consumer compatibility with the existing Swift receiver first; then implement the tested contract in the standalone Rust host.** The approved user-space HID route does not require a Thumble DriverKit/system extension, but device creation does not guarantee Apple GameController, SDL, Steam, or game recognition. The primary-source evidence and unresolved compatibility questions follow the plan below.

The original research inspected `d9e3e52`, with Xcode 26.6/macOS 26.5.1 locally available. It initially changed only this document. The follow-up above describes the subsequent code/signing-configuration changes and separates tested implementation from unverified live compatibility.

## Baseline implementation at d9e3e52

| Area | What exists | Remaining work |
| --- | --- | --- |
| Swift HID backend | [`VirtualGamepadInjector.swift`](../Sources/Mac/VirtualGamepadInjector.swift) already creates an `IOHIDUserDevice` and sends buttons, hat, sticks, and triggers. | Signing, descriptor corrections, callbacks, lifetime, and honest readiness. |
| Swift routing/safety | [`MacControllerServer.swift`](../Sources/Mac/MacControllerServer.swift) already implements mixed outputs, gamepad-button reference counts, analog sequencing, release-all, and stale analog expiry. | Preserve these semantics and verify them against a real device. |
| iPhone | [`GamepadOutputTypes.swift`](../Sources/Shared/GamepadOutputTypes.swift), [`IOSContentView.swift`](../Sources/iOS/IOSContentView.swift), and [`ControllerClient.swift`](../Sources/iOS/ControllerClient.swift) already support sticks/triggers, dead zones, sensitivity, inversion, coalesced analog messages, and final neutral releases. | No replacement touch UI/basic transport is needed; expose host output failures. |
| Configuration | [`MacControlOutputBinding.swift`](../Sources/Mac/MacControlOutputBinding.swift) and [`ThumbleCLI.swift`](../Sources/CLI/ThumbleCLI.swift) already expose keyboard/controller/custom modes and semantic mappings. | Saved controller mappings are not proof of working injection. |
| Mac signing | [`project.yml`](../project.yml) and the generated Xcode project declare no Mac `CODE_SIGN_ENTITLEMENTS`; only iOS has an entitlement file. | Wire the approved capability into the actual Mac executable and final package. |
| Rust core | [`core.rs`](../Host/crates/thumble-core/src/core.rs) rejects `GamepadAnalog`, retains only `output.keyboard` for digital holds, and has no gamepad effects; [`binding.rs`](../Host/crates/thumble-core/src/binding.rs) retains gamepad names only for migration. | Controller support is a substantive core change, not just signing. |
| Rust platform | [`output.rs`](../Host/crates/thumble-host/src/output.rs) and [`platform/macos.rs`](../Host/crates/thumble-host/src/platform/macos.rs) execute keyboard/pointer output only. | Add an actual HID adapter, controller tracking, and diagnostics. |
| Packaging/ownership | [`macos-cloudflare.sh`](../scripts/release/macos-cloudflare.sh) exports the Swift GUI; [`macos-host.sh`](../scripts/release/macos-host.sh) bundles Rust without HID entitlement/profile steps. [`ThumbleMacApp.swift`](../Sources/Mac/ThumbleMacApp.swift) refuses legacy editing while Rust authority is active. | Validate both distributions; preserve one authoritative input owner. |

### Concrete Swift fixes found during inspection

1. **D-pad:** the hat declares logical `0...8` but sends `8` as neutral. Use eight directional values `0...7` with out-of-range neutral `8`. SDL's inspected macOS backend centers hats with a range other than four/eight; the current range is nine. This is a concrete source-level compatibility bug, not a gameplay-test result. [D1, H1, H2]
2. **Axis metadata:** the hat's physical range `0...315` and angular unit `0x14` leak into sticks/triggers. Scope/reset HID globals. An offline descriptor walk confirmed this inheritance, a 72-bit payload, and ten bytes including report ID `1`. [H1]
3. **GetReport:** the callback returns zero bytes regardless of requested type/ID/current state, sometimes truncating to capacity. Its data differs from the encoder's neutral report (`01 00 00 08 00 00 00 00 00 00`). Return a coherent supported state with correct buffer conventions and reject unsupported/undersized requests. [A1]
4. **Cancellation:** `stop()` drops ownership without retaining the device until the cancel handler completes, contrary to Apple's documented lifetime boundary. Explicitly retire/cancel it on teardown and rapid restart. [A1]
5. **Readiness:** an untested injector reports available; `startLocked()` returns true even if its initial report submission fails; every creation failure is blamed on entitlements. Distinguish not-requested, ready, authorization failure, creation failure, and report failure. Neither a retained reference nor submission success proves consumer recognition.
6. **Keyboard mode:** `needsVirtualGamepadMaterialization` applies its mode gate only to legacy bindings; direct element outputs, triggers, or analog joystick settings can still create a device in keyboard mode. Make all controller paths respect the mode's “controller off” promise.
7. **Semantic mapping:** digital L2/R2 button bits and analog trigger axes are independent. Define digital-to-analog trigger behavior and validate menu/select/stick-click numbering, right-stick/trigger usages, and Y polarity with actual consumers rather than the “Xbox-style” label.

Implementation sources for these findings are the injector and server linked above. Descriptor/callback/lifetime details and primary citations are expanded below.

## Implementation phases

### Phase 0 — signing and compatibility spike

- Confirm the **exact granted key**, supported distribution methods, and enabled App ID. The GUI uses `com.codybontecou.PocketPadMac`; the standalone host uses `com.codybontecou.ThumbleHost` ([build spec](../project.yml), [host Info.plist](../Resources/Host/Info.plist)). Approval for one identifier must not be assumed to cover the other or a similarly named DriverKit key.
- Add a Mac entitlement plist and its `CODE_SIGN_ENTITLEMENTS` setting in `project.yml`; regenerate the project. Enable the managed capability and obtain matching development/distribution provisioning as required by Apple's grant. Do not add HID privileges to iOS or noninjecting helpers.
- Correct the hat, callback, and cancellation issues before relying on a signed smoke test. Inspect the **final executable's** claims and embedded profile authorization, not just Xcode settings. Test development signing and eligible Developer ID export separately; do not invoke upload/publishing steps for this experiment.
- Independently observe IOKit publication and input values. Then probe `GCController.supportsHIDDevice`, enumeration, `extendedGamepad`, and every semantic control. Cache expensive recognition checks rather than running them per input event.
- Test SDL raw joystick **and** semantic gamepad mapping, then Steam Input enabled/disabled and representative real games. Record OS/library/game versions, descriptor hash, identity/GUID, and mapping. An app-local `GCController` snapshot is not a system controller test.

**Exit gate:** the signed device publishes, neutral is neutral, expected APIs/games recognize and map the inputs, and shutdown removes it without stuck state. If only raw HID works, settle the descriptor/mapping strategy and seek Apple guidance where needed **before the larger Rust port**. Do not promise universal/XInput compatibility or merely spoof Xbox/PlayStation VID/PIDs.

### Phase 1 — productionize the Swift receiver

- Extract a pure tested report codec from device ownership; freeze descriptor/report/identity golden fixtures. Consider sixteen-bit stick resolution before freezing the first shipping descriptor; current sticks are eight-bit.
- Serialize lifecycle/submission on one owner executor, publish a small callback state snapshot, and avoid holding callback-needed locks across IOKit calls. Preserve immediate digital edges and final neutral reports. Bound analog coalescing and never discard emergency release.
- Add bounded recovery for failed submissions/neutralization and actionable diagnostics. Preserve keyboard/pointer output if HID authorization is unavailable; never silently replace a user's controller profile with keyboard mappings.
- Keep identity stable through controller-profile changes where possible; neutralize/remove the device when controller output is disabled. Explicitly choose/test disconnected-phone behavior, quit/restart, and sleep/wake.
- Expose equivalent status/recovery/intentional-test actions in app and CLI. This phase hardens existing functionality; it does not require a touch UI rewrite.

### Phase 2 — implement the authoritative Rust controller backend

- Add deterministic semantic gamepad button/stick/trigger/reset effects. Store the full resolved binding in each physical hold, reference-count overlapping gamepad outputs, and release the binding captured at press time.
- Handle authenticated `GamepadAnalog` with generation/sequence rejection, finite/range validation, mode gating, and per-axis refresh expiry. Extend profile/configuration transitions, release-all, disconnect, heartbeat timeout, and shutdown to neutralize all controller state.
- Add a macOS HID adapter to the long-running receiver and expand `OutputExecutor`/status. Share descriptor/report fixtures with Swift; preserve a no-input recording backend for ordinary CI.
- Use a narrow IOKit adapter, not the short-lived constrained profile-transform Swift bridge ([architecture](rust-host.md)). The existing Rust dependency family has a feasible binding option: cached `objc2-io-kit` 0.3.2 exposes creation, report blocks, dispatch scheduling, cancellation, and timestamped reports ([upstream API](https://docs.rs/objc2-io-kit/0.3.2/objc2_io_kit/struct.IOHIDUserDevice.html)). Dependency features, thread confinement, and unsafe lifetime boundaries still require implementation review.
- Authorize/sign **the host app's executable** with an eligible embedded profile and final-artifact checks. Keep `thumble`, MCP, and the constrained bridges unprivileged IPC clients, not separate controller creators. Keep the host running from its app-like package; copying out a restricted-entitlement Mach-O is not the supported installation shape. [S2, S3]
- Extend installed-control enumeration/testing: [`runtime.rs`](../Host/crates/thumble-host/src/runtime.rs) currently lists/tests only keyboard-bound controls, so controller-only controls would otherwise disappear from CLI/MCP testing. Preserve MCP's explicit input opt-in.

This is the largest coding phase. Reliable WebSocket input is sufficient initially; Rust UDP is a separate latency milestone. Preserve the authority lock and never run two receivers/controllers for the same paired phone.

### Phase 3 — truthful app/CLI readiness and distribution

- Configuration commands already use Rust authority, but `thumble status`, `test`, and `release-all` still use legacy runtime notifications/defaults ([CLI](../Sources/CLI/ThumbleCLI.swift)). Route runtime commands to the actual owning receiver with matching status/release guarantees; stale legacy status is not Rust readiness.
- Add opt-in gamepad status/doctor/test commands, or equivalent extensions of existing commands, with matching UI actions. Distinguish saved configuration, HID readiness, and observed consumer recognition. Bound test input and release automatically.
- Tell the iPhone when selected controller output is unavailable. Introduce optional status/negotiated capabilities compatibly: Swift/Rust currently decode capability arrays as raw-value enums, so blindly advertising a new value can reject an older peer's handshake ([Swift protocol](../Sources/Shared/ControllerProtocol.swift), [Rust protocol](../Host/crates/thumble-protocol/src/message.rs)).
- Add final entitlement/profile verification to both macOS release paths. Ad-hoc/no-sign CI remains useful for codecs/recording tests, but its artifacts must remain controller-unverified rather than substitutes for signed acceptance.

## Validation and first-release boundary

Required evidence:

- **Codec:** neutral/ID/length, all buttons/axes/triggers, eight hat directions/opposites, clamping/nonfinite policy, HID units/ranges, GetReport state and buffer bounds.
- **Safety:** overlapping mappings/touches, duplicate/stale generations/sequences, dropped neutral, hold expiry, mode/profile/orientation changes, release-all, disconnect, sleep/wake, quit/restart, and report-failure recovery.
- **Consumers:** IOKit values, Apple supported-HID/enumeration/extended profile, SDL joystick/gamepad mapping, Steam on/off, and actual gameplay. Registry presence alone is not a pass.
- **Packaging:** development and exported Developer ID signatures/profiles, notarized final bundle, minimum macOS 14 and a current OS, Apple silicon/Intel as supported by universal packaging.
- **Regressions:** Swift tests and `./scripts/verify-stack-safety.sh` for startup/shared-model/protocol changes; Rust formatting/clippy/core/runtime tests and `./scripts/verify-rust-host.sh`; shared fixtures. See [stack policy](stack-safety.md). The original documentation-only investigation ran no application suites; follow-up regression results are recorded above.

Initial scope: **one paired iPhone, one virtual Mac gamepad**, standard buttons/D-pad, two sticks, independent triggers, mixed outputs, reliable neutralization, truthful app/CLI status, and documented tested-game compatibility. Defer rumble-to-iPhone feedback, adaptive triggers, motion/sensors, multi-controller pairing, and Windows/Linux backends. The current descriptor has no Output/Feature reports; local phone haptics are not game-driven controller rumble.

**Original next step:** verify the exact App ID grant and complete phase 0 before the larger port. The follow-up implemented the shared contract/Rust backend against deterministic and mocked boundaries while this live gate remained blocked. Consumer recognition is still the highest-risk unknown; the implementation must not be released as game-compatible without that evidence.

---

## Primary-source research scope and conclusion

The user reports that Apple granted **HID Virtual Device** access. The original research did not inspect the grant, credentials, provisioning profiles, or signed artifacts; the later local profile inspection and implementation status are recorded above. It did not build, sign, or install Thumble, create a device, change the developer account, or test games. Public sources were fetched with `curl`; downloaded evidence and temporary PDF-extraction tooling remained outside the repository. Existing implementation files were read, not modified.

**Conclusion:** `IOHIDUserDeviceCreateWithProperties` is a public macOS IOKit API expressly gated by `com.apple.developer.hid.virtual.device`. Its ordinary application-process implementation opens Apple's existing `IOHIDResource` service; it does **not require Thumble to ship a DriverKit driver or system extension**. A valid grant/signature/profile is an authorization prerequisite, not proof that GameController, SDL, Steam, or any game will recognize the resulting device or map its controls correctly. Generic HID is not an Xbox protocol or Windows XInput implementation.

The promising first experiment is an appropriately provisioned, signed app-like executable publishing an honestly identified generic HID gamepad, followed by independent consumer probes. Keep compatibility claims conditional until those probes and actual games pass.

## 1. Entitlement and implementation route

### Verified facts

- Apple's public SDK `IOKit.framework/Headers/hidsystem/IOHIDUserDevice.h` documents `IOHIDUserDeviceCreateWithProperties` as creating a virtual `IOHIDDevice` in the kernel. It explicitly requires **`com.apple.developer.hid.virtual.device`** and requires at least `kIOHIDReportDescriptorKey` containing `CFData`. Availability is macOS 10.15 and later. [A1, A2]
- The entitlement is Boolean. Apple's short entitlement DocC page describes whether a driver creates a virtual HID device, but does not explain provisioning, system-extension requirements, or GameController acceptance. The API header and implementation are the stronger evidence for the application-process route. [A1, A2]
- Apple's `IOKitUser` implementation looks up `IOHIDResource`, opens it with `IOServiceOpen(..., mach_task_self(), ...)`, and submits the device properties. Apple's kernel user client checks the **calling task's** virtual-device entitlement against `kOSBooleanTrue`; without an accepted entitlement, initialization fails. [A3, A4]
- That user client also accepts an Apple/private HID-manager entitlement. This is not a substitute available through the reported public grant. Apple's old `IOHIDUserDeviceTest` entitlement file uses a different HID-manager key; do not copy it as a third-party signing recipe. [A4, A6]
- In the inspected kernel source, nonprivileged user-created devices are marked virtual (`kIOHIDVirtualHIDevice`). Do not assume a VID/PID or transport string makes a user device indistinguishable from physical hardware. [A5]

### Not DriverKit

These are separate keys, APIs, and packaging paths:

| Route | Relevant entitlement/API | Packaging consequence |
| --- | --- | --- |
| IOKit user device | `com.apple.developer.hid.virtual.device`; `IOHIDUserDeviceRef` | An entitled application process opens the existing Apple user client. No project-owned system extension is required by this route. |
| DriverKit driver | `com.apple.developer.driverkit`, appropriate family/transport entitlements; HIDDriverKit C++ classes | DriverKit extension bundled with an app; macOS installation/upgrade uses SystemExtensions. |
| DriverKit virtual-HID entitlement | `com.apple.developer.driverkit.family.hid.virtual.device` | A distinct documented entitlement, not an alias for the IOKit key. |

Apple requires the base DriverKit entitlement on every DriverKit driver. Its HIDDriverKit documentation describes packaging a driver in an app using SystemExtensions. None of that implies a requirement to convert the existing `IOHIDUserDevice` implementation into DriverKit. Conversely, a grant for a DriverKit-named key must not be assumed to authorize the IOKit key. Confirm the **exact** granted key through an authorized release workflow. [A7–A9]

## 2. Managed entitlement, provisioning, GUI and CLI

### Apple's rules

Apple's managed-capability documentation says approval enables capabilities for App IDs and that eligible newly generated profiles include their associated entitlements. Approval may cover only a subset of distribution methods. Some capabilities require manual entitlement values; legacy additional-entitlement grants may require migration. Approval alone does not update old artifacts. [S1]

TN3125 makes the following distinctions: [S2]

1. A profile **authorizes** entitlements; the executable's code signature **claims** them. Both are needed for restricted entitlements. A profile's entitlement allowlist is not the executable's entitlement dictionary.
2. macOS can run unprovisioned third-party code, but restricted entitlements still require profile authorization. Sandboxing and hardened-runtime configuration are examples of unrestricted entitlements, not evidence that a managed HID key is unrestricted.
3. macOS supports development/App Store/Developer ID provisioning, but not every capability is available for every distribution method.
4. For an app, the embedded profile belongs at `Contents/embedded.provisionprofile`.
5. A **standalone executable cannot claim a restricted entitlement**, because it has nowhere to embed the authorizing profile. Apple directs developers to wrap it in an app-like structure.

Treat this Apple-granted capability as a managed/restricted signing requirement, not a free-form `codesign` flag. The short HID entitlement page does not enumerate its distribution eligibility; this research has not verified the team's eligible profile types or App IDs.

### Recommended signing shape, subject to grant verification

- **GUI injector:** enable the approved capability for the GUI's actual App ID; configure its signing entitlement as Boolean `true`; use the matching development identity/profile locally and, if approved for outside-store distribution, Developer ID Application identity/Developer ID profile for release. Xcode automatic signing can manage this once the App ID capability is configured. Ensure the final executable claims the key and its final bundle contains the correct profile. Do not blindly copy all profile entitlements into the signing plist. [S1, S2]
- **CLI parity:** if the CLI itself opens `IOHIDResource`, it needs its **own valid calling-process authorization**. Neither the parent process's entitlement nor placement beside an entitled GUI executable is proof of authorization. Use an independently provisioned app-like CLI/helper bundle whose main executable implements command-line behavior, or have CLI commands communicate with an entitled app/broker that owns the HID device. For Thumble, the plan above keeps the CLI as an IPC client of the existing long-running receiver rather than a separate HID owner. [A4, S2, S3]
- Apple's restricted-entitlement daemon example removes UI content from an app target and directly launches `Example.app/Contents/MacOS/Example`; being callable from Terminal or launchd does not require a visible GUI. This supplies a documented packaging pattern without a system extension. Copying just the Mach-O out of that structure loses the embedded-profile arrangement. [S3]
- App ID/bundle identifier, team/app-identifier claims, certificate, profile validity, platform/distribution type, and approved entitlement values must agree. Ad-hoc signing cannot provide Apple's managed authorization. A Developer ID certificate, hardened runtime, or successful notarization alone does not replace a profile/entitlement. [S1–S3]
- Re-signing during packaging must preserve the intended entitlement claims and embedded profile; sign nested code from the inside out before sealing the outer bundle. Apple prescribes per-executable entitlement files, `--entitlements` for manual signing, and `--timestamp`/hardened runtime for Developer ID main executables. Do not use `codesign --deep` for signing: it can apply the same options to code needing different entitlements (the existing script uses it only for verification). Remove development-only `get-task-allow` from normal distribution claims. The process performing HID creation is the important entitlement boundary; a noninjecting client need not be granted HID privileges merely for CLI parity. [S4]

### Read-only repository observations

At inspection time:

- `project.yml`: `ThumbleMac` is an app target with automatic signing and hardened runtime; `ThumbleCLI` and `ThumbleBridge` are tool targets with distinct bundle identifiers. None of these three target definitions declares `CODE_SIGN_ENTITLEMENTS`. Their actual grants/profiles were not examined.
- `scripts/release/macos-host.sh`: packages multiple executables inside `Thumble Host.app`, defaults to ad-hoc signing, and its signing invocations do not pass an entitlement file or embed a provisioning profile. Merely changing `--sign` to Developer ID is not a complete managed-entitlement release recipe.
- The repo-specific plan above identifies both receiver targets and keeps CLI parity through IPC to the active owner.

## 3. Recognition is a sequence of independent gates

### HID validity and GameController support are different

A HID top-level **Application Collection**, Generic Desktop usage page `0x01`, Game Pad usage `0x05`, is the normal generic-gamepad starting point. Descriptor usages, report sizes/counts, signedness, ranges, and actual bytes must agree. Device property keys should be consistent with the descriptor. This is HID groundwork, **not a sufficient GameController compatibility contract**. [H1, H2]

Apple exposes `GCController.supportsHIDDevice(_:)` on macOS 11+: it answers whether the framework supports a particular `IOHIDDeviceRef`. Apple also publishes `GCProductCategoryHID` (macOS 13+), the category for products supporting the HID protocol. Neither API's documentation promises that every valid Game Pad descriptor is accepted. [G1, G2]

Apple documents the **extended profile's controls**: four face buttons, two shoulders, two triggers, D-pad, two thumbsticks, Menu, optional stick clicks/Home/Options. This describes a consumer profile, not a published necessary-and-sufficient generic HID usage-number mapping or acceptance algorithm. The sources reviewed did **not** establish a complete current GameController generic-HID descriptor specification. In particular, recognition of virtual transport/devices and analog-trigger usage choices remain real-test questions. [G3]

Apple open-source `IOHIDEventDriver.cpp` provides a narrower implementation observation: `checkGameControllerElement` checks Game Pad/Joystick ancestry, excludes mouse/digitizer ancestry and relative/no-preferred flags, and recognizes particular axes, D-pad usages and button ranges. Its report dispatch also gates on `_authenticatedDevice`; its button mapping is not the same as Thumble's current select/start/home/stick-click numbering. **Do not turn that one driver path into the specification for the modern GameController framework**, or attempt to forge authentication properties. It illustrates why HID conformance and a plausible layout are insufficient evidence. [G5]

### macOS compatibility emulation is not Thumble implementing Xbox

Apple documents a macOS 14+ compatibility layer that synthesizes an Xbox-360-wired-like HID device for a controller **already supported by GameController**. It is disabled by default and can be enabled per game with “Increase controller compatibility.” Supported detection uses the `GCSyntheticDevice` property; Apple says that checking this property is the only supported way to identify those synthesized devices. [G4]

This direction matters: **supported GameController device → optional synthetic HID**, not arbitrary HID → guaranteed Xbox support. Do not set `GCSyntheticDevice` on Thumble to impersonate that service. Even if this optional system layer works for Thumble, it proves neither Windows XInput support nor every macOS game's Xbox recognition. Test duplicate discovery, remapping, and per-game settings separately.

### SDL

The inspected SDL source is an actual macOS IOKit consumer: [D1, D2]

- Matches Generic Desktop Joystick, Game Pad, and Multi-axis Controller; parses axes/buttons/hats from HID elements.
- Applies vendor/product/name ignore rules and other-driver arbitration; creates a GUID using device identity properties. Known VID/PIDs can route to specialized drivers or rejection paths. Spoofing an Xbox VID/PID is not a safe generic-compatibility strategy.
- Joystick discovery and the higher-level **gamepad mapping** are separate. SDL's Darwin backend returns no automatic gamepad mapping; the gamepad layer looks for name/GUID mappings, driver mappings, and a configured default. A newly identified Thumble device may require an explicit mapping before gamepad APIs work.
- Stable, legitimate identity and observed axis/button ordering matter for mapping. Test the versions actually embedded in games (including SDL2), not only today's SDL main branch.

### Steam

Valve's device documentation lists major supported protocols and “Any DirectInput gamepad.” It says Xbox/PlayStation names also include variants using the **same input protocol**. It does not establish that a custom macOS `IOHIDUserDevice` is supported by Steam's macOS input implementation; DirectInput is not a macOS API guarantee. [V1]

Steam Input detection, generic-controller configuration, game-specific remapping, native HID/GameController/SDL paths, and any compatibility layer used for a Windows game are separate tests. No primary evidence reviewed promises custom macOS virtual-HID support across these paths.

## 4. Current descriptor: concrete review findings

`Sources/Mac/VirtualGamepadInjector.swift` currently sends a ten-byte input report: report ID `1`; sixteen button bits; four-bit hat plus four padding bits; signed X/Y/Z/Rz; unsigned Rx/Ry. It has no declared Output or Feature reports. This is a generic layout, not an Xbox/XInput protocol implementation.

**Two concrete descriptor issues should be resolved before compatibility conclusions:**

1. **Hat neutral/range:** the descriptor declares logical hat range `0…8`, null-state flag, and sends `8` for neutral. Eight compass positions should instead have eight in-range values (`0…7`) and an out-of-range null value (such as `8`). The current SDL Darwin code computes `max - min + 1`; if it is neither four nor eight, it treats the hat as centered. Thumble's nine-value range therefore makes this backend center even directional hat values. This is source analysis, not a test result. [H1 §5.10/§6.2.2.5, H2 §4.3, D1 `DARWIN_JoystickUpdate`]
2. **Global-item leakage:** the hat sets physical range `0…315` and angular units, then the stick/trigger items never reset them. HID global items persist until overridden or restored with Push/Pop. Axes therefore inherit the hat's physical/angular metadata. Explicitly scope/reset units and physical ranges before declaring axes. [H1 §6.2.2.7; H2 §4.2]

Other decisions to validate rather than assume:

- ID `1` makes the input report include an ID prefix under HID report protocol; report size accounting is nine payload bytes plus that prefix. Verify callback-specific GetReport buffer conventions as well as injected-report conventions. [H1 §6.2.2.7]
- X/Y and Z/Rz are plausible stick usages; Rx/Ry are rotational axes in HID Usage Tables, not universally defined left/right trigger meanings. SDL can enumerate them as axes, but higher-level semantic mapping and GameController trigger recognition require measurement. Consider descriptor variants using alternative standard trigger/axis usages only with evidence.
- The current button meanings are application choices. Button Page numbers do not universally mean south/east/menu/home/stick-click. Test all mapped controls independently, including optional system-reserved buttons.
- Test center/endpoints, Y orientation, trigger independence and zero/rest behavior, diagonals, opposite-direction combinations, and normalization. Eight-bit sticks are lower-resolution than sixteen-bit designs; changing resolution changes report layout and mappings.
- Do not advertise rumble, LEDs, or feature protocols without defining and implementing the relevant reports. Returning success from SetReport does not create those capabilities.

## 5. Callbacks, activation, cancellation, lifetime and concurrency

### Public header contract [A1]

- Use the symbolic **`IOHIDUserDeviceOptionsCreateOnActivate`** (`1 << 0`) rather than a magic integer. Apple describes it as delaying kernel-device creation until activation to avoid dropped get/set requests. Inspected source internally creates/starts the kernel object earlier with registration suppressed, then registers it during activation; do not rely on undocumented intermediate registry visibility. [A3, A4]
- Register get/set blocks **before activation**. The device must be activated to receive requests.
- Set the dispatch queue once, before activation. After using dispatch scheduling, explicitly activate and cancel; register functions must not be called after cancellation.
- Activation of an active device and cancellation of an already canceled device have no effect. Treat cancellation as terminal for the instance; construct a fresh instance for restart.
- A cancel does not interrupt a callback already executing. Cancellation is explicit, not implicit on losing the reference.
- The device reference should be released **only after cancellation and execution of the cancel handler**. The handler runs on the device's dispatch queue after outstanding events have been handled. Maintain an explicit retirement/lifetime owner through that boundary in Swift; avoid permanent retain cycles.
- `IOHIDUserDeviceHandleReportWithTimeStamp` takes a `mach_absolute_time()`-based timestamp and returns `IOReturn`. Submission success is not proof of delivery to a particular game. Activation returns `void`, not a GameController-ready acknowledgement.

### Callback implementation requirements

GetReport supplies report type, ID, writable buffer, and in/out buffer length. Return the current supported report, respect capacity, and update length. Reject unsupported type/ID or insufficient capacity with an appropriate error rather than claiming success with arbitrary/truncated data. SetReport supplies borrowed bytes, type/ID and length; validate them and implement only advertised protocols. Do not retain raw callback pointers after returning. Apple source copies registered blocks and invokes them while processing a kernel-request queue; get/set requests have deadlines. Keep handlers bounded and nonblocking. [A1, A3, A4]

The current injector's GetReport block returns ten zero bytes (or a shorter prefix), ignores type/ID and current state, and returns success. All-zero bytes are **not** its encoded neutral input report: the injection path prefixes `1` and uses hat `8`. Even after fixing hat semantics, GetReport must use the correct report representation/current snapshot. The current SetReport block unconditionally returns success despite no output/feature reports being declared.

### Thread-safety boundaries and current lifetime concern

The public header does not promise arbitrary concurrent mutation of an `IOHIDUserDevice`. The inspected implementation creates a serial callback queue targeting the supplied queue and uses atomic activation/cancel state bits; this is **not** a blanket thread-safety guarantee for calls, application state or object lifetime. [A1, A3]

Recommended application invariant: serialize lifecycle/report submission on one owner queue; publish a small synchronized current-report snapshot for callbacks; mark stopping before accepting more commands; send neutral when feasible; cancel and retain the retiring device/context until its cancel handler finishes. Avoid synchronously waiting for a callback/cancel handler on that same queue and avoid holding an application mutex across IOKit calls when callbacks may require it. Verify no send-after-cancel, use-after-free, deadlock, or overlap between old and restarted devices.

In `VirtualGamepadInjector.stop()`, the retained property is cleared and `IOHIDUserDeviceCancel` is called without installing a cancel handler or preserving an explicit retirement owner through completion. It also clears application state without sending a neutral report first. This does not follow the header's documented release boundary. Correct lifetime handling is an implementation task, not solved by entitlement approval. Destruction, partial-start failure and rapid stop/start need the same ownership discipline.

Creation can fail for more than a missing entitlement (service open, properties/descriptor, resource allocation). The existing error text attributes every nil result to entitlement requirements. Distinguish authorization evidence from other failures and record numeric submission errors/observable lifecycle milestones. [A3, A4]

## 6. Evidence gaps and future real-code acceptance tests

None of these tests was performed in this research:

1. **Authorization:** verify exact grant/App ID/distribution scope; final signature claims; profile authorizes Boolean HID key, identity and app identifier. Run the shipped GUI/broker/CLI-wrapper executable in its actual packaged location with a valid development profile, then separately with an eligible Developer ID profile. Negative unsigned/ad-hoc tests should fail rather than become the supported installation method.
2. **Publication and HID behavior:** create/activate; independently observe registry identity/virtual flag/descriptor and HID matching; open from another process; inspect elements and every input byte/normalized value. Exercise GetReport, unsupported requests, short buffers and any implemented output reports. Record errors and callback type/ID/length conventions.
3. **GameController:** check `supportsHIDDevice`, discovery/connect/disconnect notifications, `GCController.controllers()`, product category, actual exposed profile/elements, and all value transitions. Distinguish creation from framework acceptance. Check foreground/background event policies and user remappings.
4. **SDL:** separately establish raw joystick enumeration and mapped gamepad recognition using SDL2/SDL3 versions relevant to intended games. Record GUID/mapping, axes/buttons/hats and duplicate devices/driver arbitration.
5. **Steam and games:** identify Steam/macOS/game versions and settings; test Steam Input on/off, generic mapping, native API path, and real gameplay. If testing Apple compatibility emulation, explicitly record its per-game switch and distinguish the `GCSyntheticDevice` entry from Thumble's original device. Windows compatibility-layer results must be labeled separately from native macOS results.
6. **Lifecycle:** repeated activation/cancel/restart, concurrent inputs/reads/stop, process exit/crash, client disconnect, sleeping/waking, multiple consumers and any multi-controller configuration. Demonstrate removal and no stuck buttons; successful cancellation does not document every crash/sleep behavior.
7. **Supported platforms:** minimum supported macOS 14 and newer versions on available Apple silicon/Intel hardware. New SDK headers and open-source snapshots do not establish behavior on all deployed OS versions.

Remaining unknowns include the team's actual provisioning eligibility, current OS generic GameController acceptance/mapping rules for a virtual device, Steam's macOS handling, compatibility across game-bundled SDL versions, and per-game Xbox-specific expectations. These require experiments with genuinely entitled signed code; this document is not compatibility certification.

## Primary-source evidence index

The local header inspected was in the **macOS 26.5 SDK** at:
`/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/IOKit.framework/Versions/A/Headers/hidsystem/IOHIDUserDevice.h`.
GameController headers were inspected in the corresponding macOS framework, not the iOSSupport copy. Header availability annotations are distinct from tested runtime behavior.

Apple source snapshot commits: IOHIDFamily `777ccd9698845aadf711e32d843c8c9b777431d9`; IOKitUser `323ead896d04424f87184d8f6ff0cce811aab106`. SDL snapshot: `4a17e772ea9a4ff77dd10fa6ea6f45fc6731eb01`. These sources explain inspected behavior, not a guarantee that shipping OS/game versions use identical code.

### Apple HID / DriverKit

- **A1:** [Public IOHIDUserDevice header](https://github.com/apple-oss-distributions/IOKitUser/blob/323ead896d04424f87184d8f6ff0cce811aab106/hidsystem.subproj/IOHIDUserDevice.h); local SDK header also read.
- **A2:** [IOKit virtual-device entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.hid.virtual.device) — [DocC JSON](https://developer.apple.com/tutorials/data/documentation/bundleresources/entitlements/com.apple.developer.hid.virtual.device.json).
- **A3:** [IOKitUser IOHIDUserDevice.c](https://github.com/apple-oss-distributions/IOKitUser/blob/323ead896d04424f87184d8f6ff0cce811aab106/hid.subproj/IOHIDUserDevice.c), especially create, dispatch scheduling, activate/cancel, report blocks and HandleReport.
- **A4:** [IOHIDResourceUserClient.cpp](https://github.com/apple-oss-distributions/IOHIDFamily/blob/777ccd9698845aadf711e32d843c8c9b777431d9/IOHIDFamily/IOHIDResourceUserClient.cpp), especially `initWithTask`, `createDevice`, `createAndStartDevice`, `getReportGated`/`setReportGated`.
- **A5:** [Kernel IOHIDUserDevice.cpp](https://github.com/apple-oss-distributions/IOHIDFamily/blob/777ccd9698845aadf711e32d843c8c9b777431d9/IOHIDFamily/IOHIDUserDevice.cpp), `initWithProperties`.
- **A6:** [Apple test entitlement file](https://github.com/apple-oss-distributions/IOHIDFamily/blob/777ccd9698845aadf711e32d843c8c9b777431d9/tools/IOHIDUserDeviceTest-Entitlements.plist).
- **A7:** [DriverKit](https://developer.apple.com/documentation/driverkit) and [HIDDriverKit](https://developer.apple.com/documentation/hiddriverkit); their framework-overview DocC JSON endpoints were read.
- **A8:** [Base DriverKit entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.driverkit).
- **A9:** [Separate DriverKit virtual-HID entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.driverkit.family.hid.virtual.device).

### Apple signing / GameController

- **S1:** [Provisioning with managed capabilities](https://developer.apple.com/help/account/reference/provisioning-with-managed-capabilities), including distribution subsets and legacy migration.
- **S2:** [TN3125: Inside Code Signing: Provisioning Profiles](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles) — [DocC JSON](https://developer.apple.com/tutorials/data/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles.json), especially “Entitlements on macOS” and “Embedding a profile.”
- **S3:** [Signing a daemon with a restricted entitlement](https://developer.apple.com/documentation/xcode/signing-a-daemon-with-a-restricted-entitlement) — [DocC JSON](https://developer.apple.com/tutorials/data/documentation/xcode/signing-a-daemon-with-a-restricted-entitlement.json). Its Endpoint Security example illustrates packaging; it does not establish HID grant eligibility.
- **S4:** [Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac) — [DocC JSON](https://developer.apple.com/tutorials/data/documentation/xcode/creating-distribution-signed-code-for-the-mac.json), especially signing order, entitlements, embedded profiles, and manual signing.
- **G1:** [GCController.supportsHIDDevice(_:)](https://developer.apple.com/documentation/gamecontroller/gccontroller/supportshiddevice(_:)) — [DocC JSON](https://developer.apple.com/tutorials/data/documentation/gamecontroller/gccontroller/supportshiddevice(_:).json); also macOS SDK `GCController.h`.
- **G2:** [GCProductCategoryHID](https://developer.apple.com/documentation/gamecontroller/gcproductcategoryhid) and macOS SDK `GCProductCategories.h`.
- **G3:** [GCExtendedGamepad](https://developer.apple.com/documentation/gamecontroller/gcextendedgamepad) — [DocC JSON](https://developer.apple.com/tutorials/data/documentation/gamecontroller/gcextendedgamepad.json).
- **G4:** [Understanding game controller backward compatibility](https://developer.apple.com/documentation/gamecontroller/understanding-game-controller-backward-compatibility) — [DocC JSON](https://developer.apple.com/tutorials/data/documentation/gamecontroller/understanding-game-controller-backward-compatibility.json).
- **G5:** [IOHIDEventDriver.cpp](https://github.com/apple-oss-distributions/IOHIDFamily/blob/777ccd9698845aadf711e32d843c8c9b777431d9/IOHIDFamily/IOHIDEventDriver.cpp), especially `checkGameControllerElement` and `handleGameControllerReport`; not a complete GameController-framework specification.

### HID / SDL / Valve

- **H1:** USB-IF [Device Class Definition for HID, version 1.11](https://www.usb.org/sites/default/files/hid1_11.pdf): §5.10 null values, §6.2.2 report descriptor/Main/Global items, §7.2 Get/Set Report and §8 report protocol. The PDF itself was downloaded and relevant extracted sections read.
- **H2:** USB-IF [HID Usage Tables, version 1.6](https://www.usb.org/sites/default/files/hut1_6.pdf): Generic Desktop §4.1–4.3 and Game Controls §8.4. These semantic usages are not a guarantee of a particular game's mapping.
- **D1:** SDL [macOS IOKit joystick backend](https://github.com/libsdl-org/SDL/blob/4a17e772ea9a4ff77dd10fa6ea6f45fc6731eb01/src/joystick/darwin/SDL_iokitjoystick.c), especially `GetDeviceInfo`, `AddHIDElement`, `DARWIN_JoystickUpdate`, `DARWIN_JoystickGetGamepadMapping`.
- **D2:** SDL [gamepad implementation](https://github.com/libsdl-org/SDL/blob/4a17e772ea9a4ff77dd10fa6ea6f45fc6731eb01/src/joystick/SDL_gamepad.c), especially `SDL_PrivateGetGamepadMapping` and `SDL_OpenGamepad`.
- **V1:** Valve [Steam Input Devices](https://partner.steamgames.com/doc/features/steam_controller/device). This overview is not a macOS virtual-HID implementation specification.
