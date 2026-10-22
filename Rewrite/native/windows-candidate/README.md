# Windows candidate mapping experiment

This independent, standard-library-only Rust crate maps Thumble canonical v2 20-byte reports into values for evaluating HIDMaestro **2.0.3**, commit [`63cc6481f9e82fc8600bda8aaa65cb3271113a19`](https://github.com/hifihedgehog/HIDMaestro/tree/63cc6481f9e82fc8600bda8aaa65cb3271113a19). It does not select a launch backend or create a controller. No SDK, driver, OS API, installer, certificate, elevation, subprocess, timer, output worker or configuration authority is included. The existing receiver remains recording-only.

The public seam is `map_report(&[u8]) -> Result<CandidateState, MappingError>`. The caller must already know the source protocol is v2: these bytes do not independently carry a schema version. Length, report ID/length header, reserved button bit 11 and six reserved tail bytes are checked. Contradictory D-pad bits return `UnsupportedDpad`: those are known source bits the candidate's eight-way hat cannot represent, not a redefinition of canonical protocol validity. No malformed/unsupported report is silently repaired.

## Pinned profile and API interpretation

The exact candidate is [`profiles/microsoft/xbox-360-wired.json`](https://github.com/hifihedgehog/HIDMaestro/blob/63cc6481f9e82fc8600bda8aaa65cb3271113a19/profiles/microsoft/xbox-360-wired.json), ID `xbox-360-wired`, VID/PID 045e:028e, with `xusbCompanion` presentation. This is different from Thumble's native 20-byte report: do not submit that report as the profile's native HID bytes.

The pinned [`HMGamepadState`](https://github.com/hifihedgehog/HIDMaestro/blob/63cc6481f9e82fc8600bda8aaa65cb3271113a19/sdk/HIDMaestro.Core/HMGamepadState.cs) API defines usage-keyed `float` axis values. This crate returns `f32` values for exactly these profile roles:

| Source v2 field | Candidate usage | Interpretation |
| --- | --- | --- |
| left stick X | X, 0x0130 | signed -32768/0/32767 → 0/0.5/1 |
| left stick Y | Y, 0x0131 | signed -32768/0/32767 → 1/0.5/0 |
| right stick X | Rx, 0x0133 | signed -32768/0/32767 → 0/0.5/1 |
| right stick Y | Ry, 0x0134 | signed -32768/0/32767 → 1/0.5/0 |
| left trigger | Vx, 0x0140 | 0–255 → 0–1 independently |
| right trigger | Vy, 0x0141 | 0–255 → 0–1 independently |

Signed halves scale separately to preserve exact neutral 0.5 and both extrema; no deadzone or clamping is applied. Y inversion is explicit: the canonical report is XInput-upward, while the SDK is downward. The pinned [`HMController.PackXusbSlice`](https://github.com/hifihedgehog/HIDMaestro/blob/63cc6481f9e82fc8600bda8aaa65cb3271113a19/sdk/HIDMaestro.Core/HMController.cs) documents the SDK-to-XInput Y inversion. Actual SDK packing/readback and its final integer quantization remain unverified here.

Buttons map to the pinned API's A/B/X/Y, bumpers, Back/Start, stick presses and Guide flags; D-pad maps separately to its named hat values. The retained Home bit is preserved as Guide, not dropped or reassigned. Upstream's companion carries Guide separately from the profile's ten ordinary HID buttons and describes extended XInput handling. This does not certify Guide availability through ordinary XInputGetState, every consumer, or WoW. Digital trigger buttons have already become analog trigger bytes in v2; this crate invents no additional trigger-click flags.

`capability()` returns static mapping evidence with `backend_available:false`, `sdk_linked:false`, `driver:NotInspected`, and `gameplay_verified:false`. The reason is `mapping_only_no_sdk_or_driver_probe`. It must not be presented as an OS discovery result or proof that a machine lacks a driver.

## Headless verification

Run from the repository root:

```sh
cargo +1.88.0 test --locked --manifest-path Rewrite/native/windows-candidate/Cargo.toml
cargo +1.88.0 clippy --locked --manifest-path Rewrite/native/windows-candidate/Cargo.toml --all-targets -- -D warnings
```

Portable tests include every retained `Host/fixtures/gamepad/v2.json` vector, all 65,536 signed axis values, all 65,536 trigger pairs, simultaneous supported buttons, malformed/reserved reports, contradictory hats and truthful static capability data. Tests use the existing fixture through `include_str!`, without copying it or adding a JSON dependency. CI should run this crate separately; it does not change existing Cargo workspaces or the receiver's output boundary. Lifecycle fencing belongs to the separate output-core work.

## Licensing and remaining adoption gates

The pinned upstream [MIT license](https://github.com/hifihedgehog/HIDMaestro/blob/63cc6481f9e82fc8600bda8aaa65cb3271113a19/LICENSE) and [third-party notices](https://github.com/hifihedgehog/HIDMaestro/blob/63cc6481f9e82fc8600bda8aaa65cb3271113a19/sdk/HIDMaestro.Core/THIRD-PARTY-NOTICES.txt) were reviewed before implementation. This is an independent mapping implementation from protocol/API facts; no upstream implementation, profile asset, SDK, Microsoft build tool or third-party driver is vendored or redistributed. A future integration must separately inventory its actual payload and notices.

Upstream [`HMContext`](https://github.com/hifihedgehog/HIDMaestro/blob/63cc6481f9e82fc8600bda8aaa65cb3271113a19/sdk/HIDMaestro.Core/HMContext.cs) documents elevation for controller creation and installation, and constructor background staging/probing. It must not be instantiated by a read-only doctor. Privileged broker design, supported OS/architecture, dependency packaging, production signing, clean installation/removal/coexistence, neutralization through real output failures, native consumer readback, and gameplay remain separate gates.
