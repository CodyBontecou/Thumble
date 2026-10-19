# WoW controller research — 9 October 2026

Scope: primary-source research for a customizable Thumble controller. No game client was tested, controller was installed, or skin was authored. Product ideas below are proposals, not existing Thumble features.

## What Blizzard confirms

WoW: Forever's closed beta began September 17 and runs through October 21. The beta remains subject to change. [Blizzard beta announcement](https://worldofwarcraft.blizzard.com/en-us/news/24304160/the-world-of-warcraft-forever-beta-now-live)

Forever has a native gamepad interface, labeled **Gamepad (Alpha)** in the September 24 notes. Those notes add class flyouts: Druid forms, Hunter/Warlock pets, Paladin auras, and Warrior stances. They also add fixed party-member targeting outside raids and options to swap friendly/hostile modifier sides and targeting controls. [Blizzard development notes, September 24](https://us.forums.blizzard.com/en/wow/t/wow-forever-beta-development-notes-%E2%80%93-updated-october-8/2360696)

The October 1 notes explicitly say **gamepad UI bindings are static**; gamepad rebinding affects the keyboard/mouse interface. Therefore arbitrary in-game native-controller rebinding must not be promised. October 8 adds gamepad action-bar Edit Mode support, saves layouts per UI type, moves compact-bar settings into Edit Mode, updates raid traversal, and fixes inputs after looting. The old October 1 warning about switching UI modes resetting Edit Mode should not be presented as the latest state without qualification. [Blizzard notes, October 1 and October 8](https://us.forums.blizzard.com/en/wow/t/wow-forever-beta-development-notes-%E2%80%93-updated-october-8/2360696/4)

Retail already has native gamepad input/APIs: Blizzard's Dragonflight accessibility article describes controller/touchpad/gyro API improvements, gamepad action-bar icons, mixed gamepad/mouse input, action targeting, and an Interact Key. That establishes input support, not parity with Forever's new gamepad interface. [Blizzard accessibility article](https://news.blizzard.com/en-us/article/23876525/accessibility-updates-in-dragonflight)

ConsolePort's owner describes it as a suite addressing controller UI navigation, tailored gameplay UI, and targeting; since Shadowlands it uses native gamepad controls without an external mapper. This is a separate addon route, not required for Forever's native interface. [ConsolePort README](https://github.com/seblindfors/ConsolePort#readme)

## Class and talent differences matter

Forever revisits original-style talent trees, with points starting at level 10, updated abilities/talents, and an added 16-point milestone. Blizzard says changing talents requires a class trainer; dual specialization becomes available at level 40. Do not import Retail's loadout model wholesale. The official English article was available through the search index but direct fetch returned an error; the French localization independently indexed the same statements. [Blizzard class deep dive](https://worldofwarcraft.blizzard.com/fr-fr/news/24301515/world-of-warcraft-forever-chasseurchasseresse-et-druidedruidesse)

Retail has saved talent loadouts and specialization switching. Blizzard documents user-facing loadout/spec commands in its accessibility article. The current Blizzard UI-source mirror additionally exposes `C_ClassTalents.GetActiveConfigID`, `GetConfigIDsBySpecID`, `GetLastSelectedSavedConfigID`, `ACTIVE_COMBAT_CONFIG_CHANGED`, and `SELECTED_LOADOUT_CHANGED`; switching functions have restrictions. These are **Retail/live source observations**, not verified Forever API contracts. [Blizzard article](https://news.blizzard.com/en-us/article/23876525/accessibility-updates-in-dragonflight), [Blizzard-generated ClassTalents documentation, mirrored](https://github.com/Gethe/wow-ui-source/blob/live/Interface/AddOns/Blizzard_APIDocumentationGenerated/ClassTalentsDocumentation.lua)

## Feasible integration, with explicit limits

A companion addon could gather a snapshot of occupied action slots and icon identities. The current generated action-bar documentation exposes `C_ActionBar.GetActionTexture(actionID)` returning a file ID, `GetSpell(actionID)`, and `ACTIONBAR_SLOT_CHANGED`, `ACTIONBAR_PAGE_CHANGED`, and pet/override-bar events. An icon file ID is metadata, not PNG bytes. An external icon catalog/resolver remains necessary. These observations come from a moving Retail branch and need capability checks on the chosen Forever build. [Blizzard-generated action-bar documentation, mirrored](https://github.com/Gethe/wow-ui-source/blob/live/Interface/AddOns/Blizzard_APIDocumentationGenerated/ActionBarFrameDocumentation.lua)

ConsolePort declares both account-wide and per-character SavedVariables. Its binding controller supports named conditional presets, honors the current account/character binding set, and routes preset changes through safe callbacks. Blizzard's secure templates map modifiers and button clicks to secure actions. A Thumble companion should observe state and export configuration; it should leave casting, targeting and protected gameplay actions to WoW's existing input and secure UI. Do not rearrange secure action buttons or bindings arbitrarily in combat. [ConsolePort TOC](https://github.com/seblindfors/ConsolePort/blob/master/ConsolePort/ConsolePort.toc), [ConsolePort binding controller](https://github.com/seblindfors/ConsolePort/blob/master/ConsolePort/Controller/Bindings.lua), [Blizzard secure templates, mirrored](https://github.com/Gethe/wow-ui-source/blob/live/Interface/AddOns/Blizzard_FrameXML/SecureTemplates.lua)

**No live addon-to-Thumble transport was demonstrated.** Do not propose an addon opening an HTTP/WebSocket connection, writing arbitrary external files, or treating SavedVariables as continuous telemetry. A user-triggered export string is the lowest-assumption first bridge. An external companion reading persisted SavedVariables after a UI reload/logout can be investigated, with precise flush behavior tested. Live automatic class/spec/icon synchronization requires a separately proven, supported transport; it is not part of this research's confirmed feasibility. Avoid reading game memory or deriving combat automation from telemetry.

## Suggested product direction

1. **One stable controller shell, many loadouts.** Movement, camera, interaction, target controls, and utility positions stay familiar. Ability pictures and the class accent change. Loadouts are keyed by game flavor/build, character/class, talent setup, and applicable form/stance—not just a display name.
2. **Slot-based binding as the foundation.** The controller button points to a WoW action slot or confirmed native gamepad input; the slot's current spell/macro supplies its picture. Swapping an ability in WoW should update its label after import without regenerating the shell. In Forever, preserve native input semantics and arrange the matching WoW action bars; do not imply Edit Mode unlocks rebinding.
3. **An obvious class/build picker.** Start with manual character, class and named build selection. A change preview shows which abilities move, appear or disappear. Unlearned or missing abilities are visibly unavailable. Retail and Forever use separate adapters.
4. **Easy local editing.** Press and hold an ability to change its slot, picture, size, or location. Add position locks, Undo, reset only this build, copy between builds, and import/export. User edits win over agent suggestions and imported snapshots.
5. **Modifier banks with visual feedback.** Investigate base/left-trigger/right-trigger/both-trigger banks, reflecting the exact native client's semantics after testing. The active bank changes the displayed abilities. Explicit touch bank selection may improve reach; input modifier holds and displayed bank state must stay synchronized. Exact native slot counts and mappings are not established by the official notes inspected here.
6. **Role-specific options.** Add a dedicated friendly-target strip for healer presets; preserve enemy targeting for damage/tank presets. Druid form, Warrior stance and pet-specific panels should follow game-owned contextual bars, with a clear fallback when snapshot state is stale.

Proposed sequence: prove Thumble's virtual controller is recognized by the chosen Mac WoW client; build a manual class/loadout selector and stable slot mapping; then test a user-triggered addon snapshot import. Only add live switching after proving transport, event availability and combat-boundary behavior.

## Thumble architecture fit (parent's local inspection)

`GamepadCustomization.swift` already separates skin references from per-orientation customization/baseline overrides. `KeypadElement` owns independent identity, presentation, output and joystick/trackpad settings. `GamepadOutputTypes.swift` supports keyboard plus virtual-gamepad button sets. There is no class/spec/loadout identity or bank presentation state yet. Add loadout metadata and small layer-aware presentation patches instead of duplicating whole layouts. Preserve CLI parity and stack-size budgets.

`docs/virtual-controller-support.md` describes implemented generic macOS virtual HID but outstanding signed-device and game compatibility certification. Native WoW recognition must be tested before promising plug-and-play gamepad gameplay. These are local code observations, not Blizzard compatibility guarantees.

## Unverified before implementation

- Exact Forever action-slot/page and trigger mapping, including combined modifiers, release order, held inputs and UI focus changes.
- WoW recognition of Thumble's Mac virtual HID and practical movement/camera/targeting behavior.
- Forever addon APIs/events, protected frame constraints, and snapshot export support on the installed beta build.
- Icon provenance/resolution for client file IDs and per-build spell/rank replacements.
- Reliable snapshot synchronization and stale-state recovery; live cooldown/charge telemetry is not promised.
- Physical reach, healer targeting, raids, pet possession/forms, vehicles and accessibility behavior need game-client testing.
