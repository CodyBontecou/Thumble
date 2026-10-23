# WoW: Forever and ConsolePort

Checked October 23, 2026. Evidence below establishes the intended integration path, not compatibility of an unbuilt virtual controller.

## Verified

Blizzard's [Forever panel recap](https://worldofwarcraft.blizzard.com/en-us/news/24303862/world-of-warcraft-forever-whats-next) announces official gamepad support and a November 4, 2026 launch. The [Battle.net product listing](https://tw.shop.battle.net/en-us/product/world-of-warcraft-forever) identifies Mac and Windows platforms. A public mobile-store launch on the same date is the user's requirement; it is not a promise that review or entitlement approval will finish by then.

The [ConsolePort 3.3.12 release page](https://www.curseforge.com/wow/addons/console-port/files/9278614), dated October 21, explicitly lists Forever and client version 1.60.1. This is our initial test combination; recheck the actual release build before shipping. The addon's [manifest](https://raw.githubusercontent.com/seblindfors/ConsolePort/master/ConsolePort/ConsolePort.toc) includes interface version 16001. Its [maintainer README](https://github.com/seblindfors/ConsolePort) describes use of native gamepad input in modern clients.

Blizzard's [September 22 beta update](https://us.forums.blizzard.com/en/wow/t/beta-client-update-september-22/2358655) identifies build 69977 and addresses gamepad behavior on character selection when a gamepad is active at launch. That historical fix motivates testing both connection-before-launch and hot-plug; it does not prove a current launch requirement.

## Engineering implications and remaining checks

The intended path is phone input → macOS virtual gamepad → WoW's gamepad input → ConsolePort. Addon availability is insufficient evidence that the game accepts a generic virtual HID descriptor on macOS. Test that descriptor with the current Forever client.

Use the Forever game installation in onboarding and in CurseForge, rather than relying on the default Retail selection. The app should link to the maintainer's distribution and guide installation; bundling or modifying the addon is not required for the first release.

Keep two different kinds of mapping explicit: the phone maps touch controls to gamepad buttons and axes; ConsolePort maps those gamepad inputs to WoW actions. Preserve familiar default gamepad outputs so ConsolePort's own calibration and configuration can be used. Do not assume character actions or class-specific layouts without an in-game verification pass.

Record the macOS version, chip architecture, game build, ConsolePort release, virtual-device descriptor revision, and mobile release for every compatibility result. No “works out of the box” release claim until this matrix has a passing physical-device result on both iOS and Android.
