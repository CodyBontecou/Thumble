# Cloud controller adoption — October 23, 2026

The development-signed Release phone app and signed sandbox Mac receiver were built and installed locally. Xcode replaced the app on the physical iPhone 17 Pro while preserving its account and cached profiles. The phone paired with the updated receiver using a fresh QR code.

## Live ChatGPT → phone → Mac → ConsolePort/WoW

The existing [ChatGPT pilot conversation](https://chatgpt.com/c/6adc04d3-b338-83ed-874c-30d829cbbbb5) used the connected **Thumble Pilot Cloud** plugin to read the schema and phone, validate, save and deliver a new complete gamepad. The request explicitly preserved existing profiles and excluded spell guesses or game-binding changes.

| Stage | Observed evidence |
| --- | --- |
| Cloud profile | `wow-cloud-adoption-test-v1`, revision 1, **WoW cloud adoption test**, 18 controls |
| Target | **My iPhone**, physical iPhone 17 Pro, registered viewport 874 × 402 |
| Delivery | `aa6dce77-32ed-4b76-8291-c6d8580ea90d` |
| Download | Phone displayed the controller name and revision with **Use this controller on Mac** |
| Explicit adoption | Tapped that action; phone rendered the full gamepad behind **Controller paused** |
| Receiver persistence | Local profile `cloud-7e162aad5e900775815ddaa99c1bf4cb5fee498d`, local revision 1, activation revision 8, `cloudSource.profileId` matching the delivered ID and source revision 1 |
| Receiver readiness | Local status reported `connected:true`, `ready:true`, `revision:8` |
| Phone confirmation | Cloud screen displayed **Ready on your Mac**, explaining the separate saved copy and phone acknowledgement |
| Actual cloud receipt | A subsequent ChatGPT `delivery_status` call returned **rendered**, error `null`, updated October 23, 2026 at 9:37:44 PM America/Puerto_Rico, with no additional delivery sent |
| WoW state | Safe, out-of-combat character in Northshire Valley; ConsolePort HUD visible |
| Movement | A short left-stick gesture visibly moved the character and cleared AFK |
| Camera | A short right-stick gesture visibly rotated the scene relative to the abbey |
| Menu | Phone Menu opened WoW's ConsolePort game menu, including its controller navigation hints; a second press closed it |
| Jump | Read-only Thumble Bridge character export showed `PAD1` effective binding `JUMP`. A was tapped once, and the player explicitly confirmed seeing the character jump |
| Modifier combinations | Not yet verified in live gameplay |
| Finish state | Cloud controllers screen open; leaving the controller screen releases inputs and pauses play |

ChatGPT reported that it first saved an overlapping draft as `wow-cloud-adoption-test` revision 1, then saved the corrected controller under the delivered `-v1` ID. Only the corrected revision was delivered. This remains a layout-quality issue to address in agent validation: schema validity alone does not guarantee comfortable targets. The rendered B target is also narrower than the other face buttons; this is a successful transport/adoption test, not an ergonomic approval of the generated layout.

Screenshots: [arrival](mac-adoption-2026-10-23/controller-arrived.png), [adopted and paused](mac-adoption-2026-10-23/adopted-paused.png), [resumed controller](mac-adoption-2026-10-23/controller-live.png), [Mac confirmation](mac-adoption-2026-10-23/ready-on-mac.png). WoW input outcomes above were observed through the native app screenshot surface; no gameplay scripts, injected Lua, binding changes, combat or quest actions were used.

The earlier six-control `pilot-first-controller` revision 1 was also successfully adopted as a separate local profile before this test. Existing local profiles were preserved. The phone render receipt establishes the rendered revision; the separate native receiver and observed game tests establish adoption and specific working inputs. Neither proves all game bindings or modifier combinations.

## Automated verification

- 175 root JavaScript tests pass, including explicit adoption, old receiver rejection, exact content/provenance checks, account/selection/pairing races and committed LAN-render receipt gating.
- Mobile ESLint and TypeScript checks pass.
- Native catalog tests pass: shared JS/Swift validation corpus, immutable source copies, stale activation conflicts, newer cloud revisions and preservation of existing profiles. Node profile tools can read the adopted native catalog.
- The isolated TLS receiver test passes with a validated profile larger than 4 KiB, using the production phone connection core. It verifies persistence, layout commit, fresh neutral acknowledgement, paused adoption and idempotent retry. Its HID implementation is a non-gameplay stub; it does not prove live game input.
- The physical iOS Release build and Mac receiver compilation/signature verification passed. Android `:tapping-link:compileReleaseKotlin --offline` also passes when `ANDROID_HOME` is explicitly set to the installed SDK; no Android runtime journey was exercised.
- Fixed the receiver build script's empty keychain argument expansion under macOS Bash 3 with `set -u`; syntax and empty/nonempty argument expansion checks pass.

## Remaining checks

Test modifier combinations on the intended character and repeat the journey on Android hardware. Exercise reconnect/restart after adoption, older receiver errors and cloud account switching on hardware. Live Apple sign-in, other AI clients, public marketplace distribution and Google production verification remain separate release work. Hosted character export/import is not implemented.
