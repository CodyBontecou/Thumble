# Thumble

Companion addon for Thumble phone controls and ConsolePort in World of Warcraft.

On macOS, Thumble refreshes gamepad discovery when the Mac receiver disconnects or a replacement controller is not discovered. Recovery waits for neutral controls and pauses during combat. ConsolePort is required for automatic recovery. The addon leaves gamepad support off if you have disabled it.

Install this ZIP with CurseForge, or extract its ThumbleBridge folder into Interface/AddOns for the WoW client you play. Restart WoW on a first install, then enable **Thumble** at character selection. Use `/reload` after updates.

With Thumble 0.1.2 or later and an updated Thumble Receiver, ConsolePort spell labels, artwork and modifier layers can sync to your phone. Keep the receiver running, connect the phone with ConsolePort controls selected, then type `/reload` after loading your character. Open the phone controller and compare labels and held modifier layers with ConsolePort. Reload again after spell or binding changes. This is a saved snapshot, not live cooldown tracking.

If labels do not update, enable **Automatically sync ConsolePort** in the receiver, select **Choose WoW folder…** for a nonstandard installation, and reload again. ConsolePort action bars must be enabled.

Commands:
- `/thumble`: open character export and binding review tools.
- `/thumble discovery`: show gamepad recovery status.
- `/thumble sync`: show snapshot sync status; `/thumble sync off` or `/thumble sync on` changes it for this character.
- `/thumble discovery off` or `/thumble discovery on`: change recovery for this character.

The legacy `/thumblebridge` and `/tbbridge` commands still work. The folder and SavedVariables retain the ThumbleBridge name to preserve existing settings and exports.

The optional review tools export learned spells/current bindings and accept a plan for the player to review and apply outside combat. They never cast spells or automate gameplay. The Thumble phone app currently defaults to ConsolePort controls; AI/MCP controller generation is disabled.

For phone control use, the separate Thumble Receiver and phone app are needed. WoW runs on your Mac. The iOS phone app is available in a limited public TestFlight beta: https://testflight.apple.com/join/kxwHv4qW. The addon itself has no purchase check. See https://thumble.io for app availability and requirements.

Initial gameplay verification: WoW Classic Era 1.15.9 with ConsolePort 3.3.11 on macOS. Other WoW clients have not completed equivalent gameplay validation.
