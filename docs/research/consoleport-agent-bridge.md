# ConsolePort binding bridge feasibility

Checked October 23, 2026 against the maintainer's current public source. The companion addon and local tools are now implemented; see [the current workflow and validation limits](../companion-addon.md). This document retains the design research. Live export and review have been checked in Classic Era; player Apply and the Forever client remain separate verification steps.

## What can be connected

The phone profile already supports arbitrary labels. To make those labels correspond to real actions, an agent also needs character-specific binding information: gamepad button → WoW binding/action slot → spell. Class alone is insufficient because spells, ranks, talents, action pages, stances, modifiers, and existing player bindings differ.

ConsolePort exposes `GetCurrentBindings()`, `GetActionBinding(index)`, `GetCurrentBindingOwner(bindingID)`, and `GetActionPageDriver()` in its [public API](https://github.com/seblindfors/ConsolePort/blob/master/ConsolePort/API.lua). These provide useful inspection points for a companion addon. ConsolePort's [loadout model](https://github.com/seblindfors/ConsolePort/blob/master/ConsolePort_Config/Model/Loadout.lua) resolves action-slot labels using the current page and action information. An export should include the page/stance context rather than assuming one permanent ability per gamepad button.

ConsolePort already has [import/export UI](https://github.com/seblindfors/ConsolePort/blob/master/ConsolePort_Config/View/Config/ImportExport.lua), including binding and action-bar data, validation, a preview, and an Apply action. Its binding evaluator saves changes through the addon's compatibility layer. Its [binding controller](https://github.com/seblindfors/ConsolePort/blob/master/ConsolePort/Controller/Bindings.lua) also loads and saves presets. Reuse the supported import path where practical; writing the addon's SavedVariables while the game is running is not a reliable live-update channel.

## Recommended first version

1. A small Thumble companion addon exports the current character's game build, ConsolePort version, class/spec, active action page, gamepad modifiers, bindings, action slots, and resolved spell IDs/names as copyable data.
2. A local MCP tool imports that data and builds a coordinated phone profile plus a binding plan. It keeps the two artifacts separate: labels/geometry can go live immediately; bindings remain pending until the game confirms them.
3. The player pastes the plan into the addon, reviews exact changes and conflicts, and clicks Apply outside combat. The addon validates available spells, updates only requested bindings/slots through supported APIs, and exports the applied result. The agent must not report “Charge is bound” until that result is provided.
4. The player imports that result back into the local tool, which synchronizes the phone labels to the confirmed bindings.

This is an explicit import/export handoff. Do not assume a WoW addon can open a local MCP socket or read an arbitrary changing file. SavedVariables can support a slower export path after the game flushes them, but should not be sold as a bidirectional live socket. The first version should use copy/paste and documented addon APIs rather than client memory access, injected code, pixel channels, or gameplay commands.

Binding configuration and gameplay are distinct: the proposed tool changes setup; it never casts a spell. Combat-sensitive changes should be rejected with instructions to apply outside combat, rather than auto-applied on a later event. Verify the exact Forever client and ConsolePort release before shipping this bridge; Retail API behavior is not proof of Forever compatibility.

## Recording today

Use the implemented profile MCP tools for the live phone transformation. Thumble Bridge can now export learned spells, prepare a binding plan, and show the exact in-game review. The player applies it and exports a verified result before the tools synchronize labels and explicitly activate the phone profile. Use a character that has learned Charge and Execute for that script; the level-1 test character can demonstrate Heroic Strike and Perception instead. Do not describe a pending receipt or an unacknowledged phone update as a completed round trip.
