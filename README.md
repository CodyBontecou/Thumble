# Thumble

A phone gamepad for World of Warcraft: Forever and ConsolePort. Targets iOS and Android, with a minimal macOS menu-bar receiver over local Wi-Fi. Public launch target: November 4, 2026.

## Current state

This repository contains the React Native/Expo controller, a shared JavaScript layout/mapping API, and a signed macOS menu-bar receiver. QR invitations pair one phone over certificate-pinned TLS WebSockets. Native HID reports are recognized by Apple GameController and WoW Classic with ConsolePort. Physical Android movement, camera, menu and trigger input have been verified in-game, including release when backgrounded. Physical iPhone QR pairing, HID delivery, movement, camera rotation and Menu are also verified. See [validation evidence](docs/validation.md) for exact versions and remaining checks.

Local profile MCP tools, atomic profile storage, and acknowledged live layout delivery are implemented. [Thumble Bridge](docs/companion-addon.md) adds character exports, skill-binding proposals, in-game review/Apply, and confirmed phone-label synchronization. Public distribution signing, store submissions, Forever-client gameplay and latency qualification remain outstanding. See [agent profile workflow](docs/agent-profiles.md) for setup and recording instructions. The [latency report](docs/latency.md) contains measured baselines, an isolated parser improvement and the rejected Wi-Fi-lock experiment.
```sh
npm test
npm run check
npm run lint --workspace @tapping/mobile
npm run typecheck --workspace @tapping/mobile
```

Run `npm install` before the complete test suite and mobile lint/type checks. The controller-only tests and syntax check can run without dependencies. Node 22 or newer is required.

For the mobile development app:

```sh
npm install
npm run start --workspace @tapping/mobile
# In another terminal, select an explicit device:
npm run ios --workspace @tapping/mobile -- --device SIMULATOR_UDID
```

Metro uses port 8088. The Android build command is `npm run android --workspace @tapping/mobile`. Native projects are generated with Expo Prebuild. Production identifiers are `com.thumble.ios` (iOS), `com.thumble.android` (Android), and `com.codybontecou.PocketPadMac` (Mac). The Mac keeps its existing identifier to reuse Apple’s approved production virtual HID capability while displaying Thumble Receiver. Public distribution requires a matching Developer ID profile and signing certificate. The old repository is not a runtime dependency.

For bundled hardware testing without Metro, run `npx expo run:ios --configuration Release --device IPHONE_UDID --no-bundler` or `npx expo run:android --variant release --device ANDROID_SERIAL --no-bundler` from `apps/mobile`. Configure `ANDROID_HOME` to the installed SDK. Build the Mac receiver using [its instructions](apps/receiver/README.md), then open Connect Mac on the phone.

## Demo and Pro

The full app has a 30-minute total connected-use demo, including agent-created
custom layouts, saved profiles and integrated dictation. Pro is a $19.99 USD
base-price one-time native store purchase that only removes the time limit.
No visual editor is planned. Setup and local practice remain free. Purchase initiation stays
disabled until production store products and first-party verification are configured.
See [monetization setup and verification](docs/monetization-setup.md).

## Shared controller API

The [Wi-Fi/UDP comparison](docs/network-udp.md) records physical iPhone and Pixel WebSocket/UDP/WebSocket runs, bounded one-way timing estimates, independent HID observations and security tests. Authenticated UDP remains opt-in; WebSockets remain the default. The [input reliability report](docs/input-reliability.md) covers burst handling, sustained holds, recovery, and final physical iPhone 17/Pixel checks in WoW with ConsolePort.

```js
import { Controller, xboxProfile } from '@tapping/controller';

const controller = new Controller(xboxProfile);
controller.update('left-stick', [1, 0]);
controller.update('a', true);
const gamepad = controller.snapshot();
controller.update('a', false);
controller.releaseAll();
```

Profiles are JSON data. Each profile declares normalized control geometry, labels, colors, and mappings to canonical gamepad outputs. ConsolePort mirror profiles also carry validated icon names, button badges, modifier outputs and display layers. Validation rejects unsupported output types, ambiguous analog ownership, invalid geometry, and unknown fields. Profile replacement validates and copies the complete candidate before changing the active controller; replacement releases all inputs. The receiver must deliver that neutral state before publishing a new layout revision.

The local MCP server calls the same validation and profile API. Agents can read, validate, save and activate layouts; the paired phone renders them live. There is no visual editor. Game actions remain in WoW/ConsolePort; this API defines physical gamepad inputs. The [companion addon workflow](docs/companion-addon.md) connects player-exported character data to proposed bindings, with a player Apply step in-game.

`InputWatchdog` neutralizes stale input using a caller-supplied monotonic clock. It is a **state helper**, not a running timer or HID driver. A receiver must poll it, authenticate input, reject stale sessions and packet sequences before `accept`, and write the resulting neutral report to the virtual device.

## Design and launch gates

- [Cloud controller pilot: contracts, configuration and QA](docs/cloud-pilot.md)
- [Architecture and implementation sequence](docs/architecture.md)
- [WoW and ConsolePort research](docs/research/wow-consoleport.md)
- [Onboarding and acceptance criteria](docs/onboarding.md)
- [Implementation and verification evidence](docs/validation.md)
- [macOS virtual gamepad investigation](docs/research/macos-virtual-gamepad.md)

The name “Xbox-style” describes the familiar control arrangement. The diagnostic also implements Thumble's Xbox-compatible HID descriptor and neutral report shape; this is not Xbox certification or evidence of universal game compatibility. The [MIT notice](ThirdParty/SteamControllerBridge-LICENSE.txt) accompanies the retained descriptor.

The LAN receiver and QR pairing implementation are in [apps/receiver](apps/receiver/README.md). The iOS/Android app uses a local Expo native module for certificate-pinned TLS WebSockets. See [the wire protocol](docs/lan-protocol.md) for authentication, input freshness and release behavior. A bundled phone build can run without Metro; development builds use port 8088.
