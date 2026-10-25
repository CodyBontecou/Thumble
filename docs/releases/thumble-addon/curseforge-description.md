# Thumble

Thumble is the companion addon for Thumble phone controls and ConsolePort in World of Warcraft. Our initial focus is WoW on Mac with ConsolePort.

## Keep your Mac gamepad discoverable

If WoW loses the virtual controller after a Thumble Receiver restart, the addon refreshes gamepad discovery. It waits for neutral controls, defers during combat and leaves a healthy connected controller alone outside its recovery window. Automatic recovery requires macOS, ConsolePort and the relevant WoW gamepad APIs. It does not turn gamepad support back on if you disabled it.

Use `/thumble discovery` to see recovery status. Use `/thumble discovery off` or `/thumble discovery on` to change it for the current character.

## Optional character exports and binding review

Open `/thumble` to export learned spells and current bindings, review a pasted binding plan, and apply reviewed changes outside combat. Review and Apply are explicit player actions. Previous bindings can be restored. Every gameplay button press remains yours; the addon never casts spells or sends gameplay input.

The current phone app starts with a built-in ConsolePort controller. AI/MCP controller generation is disabled and is not needed for the default setup. Character exports and binding review are advanced tools, not a required first-run step.

## Install

Install using CurseForge and enable **Thumble** at character selection. Restart WoW for a first installation, or use `/reload` after an update.

For manual installation, extract the `ThumbleBridge` folder from the ZIP into your WoW client's `Interface/AddOns` folder. That internal folder name is retained to preserve settings and exports from earlier versions. The displayed addon name is **Thumble**. Legacy `/thumblebridge` and `/tbbridge` commands continue to work.

## Requirements and availability

- Initial gameplay verification: WoW Classic Era 1.15.9 with ConsolePort 3.3.11 on macOS.
- Automatic gamepad recovery requires ConsolePort; the addon can otherwise load without it.
- Phone control requires the separate Thumble phone app and Mac receiver. WoW runs on the Mac, with the phone connected over the same Wi-Fi.
- The iOS phone app is available in a limited public [TestFlight beta](https://testflight.apple.com/join/kxwHv4qW). Visit [thumble.io](https://thumble.io) for availability and setup information.
- The addon itself has no purchase check. The separate phone app offers a 30-minute total connected-use demo and an optional paid Pro unlock.

The addon does not connect directly to a cloud service or an AI agent. Exports are shared explicitly by copy/paste or a SavedVariables file written by WoW after reload/logout.
