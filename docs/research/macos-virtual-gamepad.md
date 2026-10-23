# macOS virtual gamepad feasibility

Researched October 23, 2026. Target: phone controller over local Wi-Fi → minimal macOS menu-bar receiver → system-visible gamepad → WoW/ConsolePort. The desktop may require a small native module even though the shared API and mobile app use JavaScript.

## Signed follow-up: capability and GameController recognition verified locally

The user confirmed that both store accounts exist and HID access is approved, and directed this clean-slate project to use the signing setup in `/Users/codybontecou/dev/Thumble`. Read-only inspection found team `67KC823C9A`, Mac app ID `com.codybontecou.PocketPadMac`, iOS app ID `com.codybontecou.PocketPad.iOS`, and Android application ID `com.thumble.android`. The old repository was not modified.

A current Mac development provisioning profile for the Mac App ID contains `com.apple.developer.hid.virtual.device = true`. The development signing identity is available outside the execution sandbox. Do not infer missing certificates from the sandboxed `security find-identity` result: that view reported zero identities, while the normal keychain view exposed the existing development identity.

`tools/build-macos-hid-probe.sh` now builds an app-like diagnostic, embeds the matching profile, signs it with Apple Development and the HID entitlement, and passes `codesign --verify --strict`. It neither installs nor publishes the app. Profile/certificate files remain outside source control. The configuration deliberately retains the existing App ID so this test does not assume that a new App ID inherits the approval.

On this stock Mac, running the signed probe as uid 501 returned **SUCCESS**. An independent `tools/observe-macos-gamepad.swift` process saw the device. The generic descriptor was **not supported by GameController** and did not enumerate as a controller.

The probe's `--xbox` mode reuses only Thumble's 212-byte Xbox-compatible descriptor, with the matching VID/PID and USB transport; the MIT notice from its original author is retained in `ThirdParty/SteamControllerBridge-LICENSE.txt` and included in the probe bundle. It implements neutral GetReport replies in the matching 20-byte input format. This is a descriptor/protocol compatibility test, not a VID-only change. It sends no button/movement reports.

The independent observer then reported:

```json
{
  "gameControllers": [{
    "category": "Xbox One",
    "extendedGamepad": true,
    "vendorName": "Tapping HID capability probe"
  }],
  "hidManagerOpenResult": 0,
  "probeHIDDevices": [{
    "product": "Tapping HID capability probe",
    "supportedByGameController": true
  }]
}
```

The device exited automatically after ten seconds. This validates local **development signing, device creation and framework recognition**. It does not validate input value delivery, public Developer ID distribution/notarization, additional Mac hardware/OS versions, latency, or WoW/ConsolePort gameplay. Those remain gates. Thumble's own current support notes contain prior input-value experiments, but this new project's observation above is intentionally narrower.

The sections below preserve the initial unsigned investigation and distinguish platform facts from the follow-up evidence.

## Decision

Start with a user-space virtual HID backend (`IOHIDUserDeviceCreateWithProperties`, or CoreHID on a suitably recent deployment target). Treat **working signed distribution and detection inside the exact target WoW client as release gates**. Neither a network receiver nor a successful gamepad descriptor proves WoW compatibility. A November 4 public release must not be promised until these gates pass.

Prefer the simple user-space path before adding a DriverKit system extension: Apple explicitly describes CoreHID as capable of emulating a virtual game controller and sending input to other apps. This is the relevant system-device abstraction. [Apple CoreHID overview](https://developer.apple.com/documentation/corehid?changes=_1_1)

## Verified platform facts

- The installed macOS SDK publicly declares `IOHIDUserDeviceCreateWithProperties` in `IOKit/hidsystem/IOHIDUserDevice.h`, available since macOS 10.15. Its documentation explicitly requires `com.apple.developer.hid.virtual.device` and requires at least a report descriptor in the device properties. This is a direct local SDK observation, not an inference from the API name. Header inspected: `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/IOKit.framework/Versions/A/Headers/hidsystem/IOHIDUserDevice.h`.
- Apple's public IOHIDFamily source checks `com.apple.hid.manager.user-access-device` or `com.apple.developer.hid.virtual.device` in `IOHIDResourceDeviceUserClient::initWithTask`. If neither authorizes the caller, initialization fails. That function contains no root-user bypass. This supports treating the entitlement as necessary; it does **not** establish every behavior of every shipping macOS build. [Apple IOHIDResourceUserClient.cpp, lines 109–147](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDFamily/IOHIDResourceUserClient.cpp#L109-L147)
- Apple lists a distinct DriverKit entitlement, `com.apple.developer.driverkit.family.hid.virtual.device`, and explicitly directs developers to a request form for it. DriverKit drivers run in user space, are delivered as app extensions, and use System Extensions installation on macOS. Choosing DriverKit therefore adds packaging and activation work; it is not an entitlement-free escape hatch. [Apple virtual HID DriverKit entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.driverkit.family.hid.virtual.device?changes=_4_8&language=objc), [Apple DriverKit overview](https://developer.apple.com/documentation/DriverKit?changes=late_8&language=objc)
- For managed capabilities generally, Apple requires assignment by Apple before enabling the capability. The Account Holder requests access from an App ID's Capability Requests tab. This official help page does **not itself list HID Virtual Device**; verify the exact capability and distribution types in the project's developer account instead of claiming that the generic page proves the classification of this specific key. [Apple capability requests](https://developer.apple.com/help/account/capabilities/capability-requests/)
- `GCController` primarily represents controllers consumed by an app. Apple documents mutable element values for snapshots; `withMicroGamepad` returns a snapshot. These docs do not promise that modifying a snapshot publishes an input device to another application. Do not use snapshot mutation as the receiver's system-wide output backend. [Apple GCController](https://developer.apple.com/documentation/GameController/GCController)

## Local nonprivileged probe

Added `tools/macos-hid-probe.c`. It uses the public SDK API and a small Generic Desktop / Game Pad descriptor (16 buttons, four axes). It sends no input reports, installs no driver, changes no permissions, and releases the ephemeral device immediately if creation succeeds.

Run on this machine:

```sh
xcrun clang -fblocks -framework IOKit -framework CoreFoundation tools/macos-hid-probe.c -o /tmp/tapping-hid-probe
/tmp/tapping-hid-probe
```

Observed on macOS **26.5.1**, build **25F80**, as ordinary user **501**, without an entitlement-bearing app provisioning profile:

```text
uid=501 IOHIDUserDeviceCreateWithProperties=NULL
```

Process exit status: 1. The probe compiles successfully. This result establishes only that this ordinary development process did not create the device. It does not isolate every cause of the failure, prove how a properly signed build behaves, or test root. No root execution or reduced-security configuration was attempted. The cited SDK requirement and kernel source independently explain why an entitlement-free process cannot be assumed to work.

## Distribution and signing: confirmed versus unresolved

Confirmed: the public API explicitly requires the virtual HID entitlement. DriverKit's virtual HID entitlement has an explicit Apple request step. Merely adding a Boolean to a plist is not evidence that a production app is authorized.

Unresolved for this project's Apple team: whether `HID Virtual Device` is available to request for the selected App ID; whether Apple has granted it; which provisioning profiles and distribution methods can carry it; approval timing; and whether any additional user permission prompts occur for a gamepad-class device. The project has not inspected account credentials or tested an entitlement-bearing signed bundle.

The Karabiner project documents a real shipping DriverKit approach and its requested capability set, including `com.apple.developer.hid.virtual.device`, HID family/device/eventservice/transport entitlements, and a separate user-client-access permission. This is first-party evidence for **Karabiner's implementation**, not a guarantee that its exact entitlement combination is required or sufficient for a gamepad. Its existing driver is a keyboard/pointing-device implementation, not a ready-made WoW gamepad backend. [Karabiner-DriverKit-VirtualHIDDevice](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice)

For the minimal receiver, investigate Developer ID signing and notarized direct distribution first; do not silently add a Mac App Store requirement. Mobile App Store and Google Play publication are separate workstreams from authorizing the Mac HID backend. If Mac App Store distribution is desired, separately verify sandbox compatibility and review policy with the actual build.

## WoW compatibility is not yet verified

No authoritative source reviewed promises that the exact target WoW macOS build recognizes arbitrary Generic Desktop HID gamepads. Apple's ability to publish a HID gamepad is therefore insufficient to claim plug-and-play ConsolePort/WoW support. ConsolePort consumes the game's controller facilities; the addon cannot fix an OS-level device that the game does not discover.

Do not counterfeit an Xbox vendor/product identity as a shortcut without understanding driver matching and report/protocol expectations. An Xbox-style phone layout and an Xbox-compatible OS input device are separate properties. The probe intentionally does not claim an Xbox identity.

Required acceptance evidence:

1. A properly signed receiver creates a gamepad on a clean stock Mac with normal security settings.
2. A diagnostic using IOHIDManager sees the device and its descriptor; a GameController diagnostic separately checks `GCController.controllers()` and reports the actual profile/elements.
3. The exact WoW client/version used for launch sees the device, including after hot plug/reconnect. Capture game API device/state results, not only screenshots of the phone.
4. Verify left/right sticks, independent triggers, face buttons, bumpers, D-pad diagonals, menu/view, stick clicks, held modifiers, and simultaneous touches through ConsolePort's wizard and actual movement/camera interaction.
5. Test disconnect, app suspension, Wi-Fi loss and receiver exit: all held controls return to neutral. Measure touch-to-HID and touch-to-visible-game response separately.
6. Repeat the signed installation and onboarding on another Mac; confirm Apple silicon and Intel support only where actually tested.

## Immediate next steps

The Account Holder should inspect/request `HID Virtual Device` for the receiver App ID and confirm the intended distribution profile. Supply Apple a concrete description: paired local-network phone input, user-controlled connection, software gamepad for accessibility/game controls, no unattended automation. Do not claim existing approval or a guaranteed approval date.

In parallel, finish the shared declarative layout/mapping API, touch renderer and authenticated LAN receiver against a diagnostic output backend. Keep HID output behind a narrow native backend interface so CoreHID and legacy IOKit can be evaluated without changing the protocol. Then test the approved signed HID backend against WoW before declaring the November 4 launch achievable.
