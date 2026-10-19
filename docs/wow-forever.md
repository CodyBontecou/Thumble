# WoW Forever native gamepad setup

The `wowForever` template creates a controller-output profile with separate portrait and landscape layouts. It emits native physical inputs: two analog sticks, D-pad, ABXY, LB/RB, held LT/RT, L3/R3, View and Menu. It emits no keyboard shortcuts or digital joystick directions. WoW owns action-bar pages, targeting and ability assignments; the template does not invent a fixed spell-to-button map.

In the macOS or iPhone editor, create a setup from **WoW Forever**. Edit its controls normally; duplicate and name profiles for each character/class/talent build, then select them in the profile picker. Both orientations use the same element identities and input bindings. Editing a visible label does not change what gamepad input it emits.

CLI:

```sh
thumble template install wowForever --name "WoW Mage Frost"
thumble profile duplicate "WoW Mage Frost" "WoW Mage Fire"
thumble profile select "WoW Mage Fire"
thumble gamepad doctor
thumble gamepad status --json
```

The MCP `controller-templates` catalog and typed `template.install` configuration operation expose the same `wowForever` template, revision 1. The HTTP builder template catalog also supports it.

Enable Forever's native Gamepad interface in the game. Arrange abilities in WoW's action bars, including its class-specific form/stance/aura/pet flyouts. Hold a trigger while pressing a face or D-pad control when using the game's modifier inputs. Thumble sends press/release state rather than timed macros. The exact trigger/page/target meanings belong to the selected client build and options.

Blizzard's [October 1 and October 8 beta notes](https://us.forums.blizzard.com/en/wow/t/wow-forever-beta-development-notes-%E2%80%93-updated-october-8/2360696) describe fixed gamepad UI bindings and action-bar Edit Mode. Rebinding the keyboard/mouse interface does not redefine the native gamepad UI. This template follows native inputs and remains user-editable on the Thumble side.

Switching a Thumble profile selects a controller setup. Change the character's talents/specification in WoW itself. Automatic class/talent detection, live spell icon synchronization and an addon transport are not implemented by this template; see the [research](research/wow-controller-support-2026-10-09.md).

## Verification boundary

Implementation checks passed: 60 shared configuration tests, 38 CLI backend tests, 590 Rust workspace tests, all 18 canonical template fixtures, and `scripts/verify-stack-safety.sh`. An isolated receiver with input disabled verified install, idempotent retry, duplicate, select and export, including preservation of the original and default profiles. Fixture regeneration also refreshed existing templates' visual-role metadata to match the current shared factory; their inputs and geometry did not change.

The template is verified against the shared configuration bridge, canonical fixture parity, input bindings, Codable round trips and constrained-stack template coverage. Signing and actual WoW recognition remain separate acceptance gates in [virtual-controller-support.md](virtual-controller-support.md). A successful initial HID report is not proof that WoW recognizes the device. No WoW client or Battle.net app was found in this workspace's `/Applications` inventory during implementation, so no live gameplay result is claimed.

For a live acceptance run, use a receiver signed with the authorized virtual-HID entitlement, verify gamepad readiness, and test both sticks, all buttons, combined trigger holds, targeting, menus, orientation/profile switching and disconnect releases in the installed Forever client. Keep configuration switching outside active held inputs; the receiver retires the previous input generation and neutralizes old holds.

## Ability pictures across trigger banks

Skins can now display different pictures for Base, LT, RT and LT+RT through [held-trigger action sets](skins/css-authoring.md#held-trigger-action-sets). The native `wowForever` profile already emits held LT/RT button edges. A layered skin observes those outputs locally and changes its visible action set while WoW continues to own the actual abilities and targeting.

This is the display foundation for class/spec skins. The existing Fury Forge candidate has static icons; it has not been revised or applied by this change. Class/talent detection, live action-bar synchronization and automatic icon updates from the game are separate integration work.
