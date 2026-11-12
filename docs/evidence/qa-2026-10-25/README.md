# Scheduled Thumble QA — October 25, 2026, 08:00 Puerto Rico

Result: automated checks PASS; live iPhone/WoW end-to-end session BLOCKED by environment readiness. This is not an end-to-end gameplay pass.

## Passed this run

- 234 repository tests, zero failures. Includes onboarding checkpoints, context invalidation, sync confirmed/skipped decisions, connection input safety and persistence.
- Lua addon core, WoW adapters, discovery and automatic snapshot tests.
- Native ConsolePort sync fixtures: bounded decoding, reload import, all eight layers, actual modifiers, artwork cache/fallback, preserved geometry/mappings, stale/malformed snapshots, character switching, races and idempotence.
- Isolated real TLS receiver catalog regression.
- Isolated TLS receiver plus production phone state machine: profile delivery/neutral acknowledgement, movement/button/shoulder/trigger chord, release on pause/profile switch/disconnect, fresh pairing and recreated phone core retaining the exact profile, explicit resume required. GamepadStub.c discards input and creates no HID. This is transport/report evidence, not real iPhone restart or gameplay evidence.
- Mobile lint and typecheck.
- Fresh authenticated CurseForge dashboard shows Thumble 0.1.2, file 9316122, Approved for 1.15.9. Project Page link is public and the file has a download link. Screenshot and AX snapshot saved here.

## Preparation performed

Classic Era had a local sync-enabled addon still labeled 0.1.1. Verified source Lua and TOC against the released 0.1.2 ZIP, then updated only _classic_era_/Interface/AddOns/ThumbleBridge with the existing backup-capable installer. See classic-era-addon-install.txt for destination and backup. SavedVariables and bindings were not touched. The Forever installation remains its older nonsync 0.1.1 addon; it was not changed because equivalent gameplay compatibility is unverified.

## Live blockers and next action

Argent inventory: Cody Bontecou’s iPhone 17 Pro (00008150-001405DA2188401C) is paired over localNetwork, tunnel disconnected, not connected. iPhone 13 Pro Max and Pixel 7 are connected but are not substituted for the specifically scheduled iPhone 17. No user phone app launch, restart, data change or gameplay confirmation was attempted.

Computer Use app inventory reports World of Warcraft Classic and Battle.net not running. No character is available for label comparison or gameplay checks.

Owner next action: connect and unlock the iPhone 17 Pro over USB, keep it awake; start Thumble Receiver; launch Classic Era and log into a character with ConsolePort enabled; open Thumble on the phone and reconnect to the Mac. Then /reload in WoW to load addon 0.1.2 and save fresh labels. Continue WoW setup to compare base and held modifier layers, then perform movement/release, camera, action, modifier and menu tests, followed by real phone restart and disconnect/reconnect checks.

Existing profiles, player confirmations and unrelated working changes were preserved. Automation is one-time and removed after this audit; resume live QA in this chat when ready. No recurring checks are scheduled.
