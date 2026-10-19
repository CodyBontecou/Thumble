# WoW controller patterns — 9 October 2026

This supplements [support research](wow-controller-support-2026-10-09.md). Evidence tiers: Blizzard announcements/notes; addon-owner documentation/source for that addon's behavior; Valve documentation for Steam Input. Addon observations are not an official Blizzard specification. No client or physical controller was tested.

## Forever: confirmed boundaries and observed patterns

Blizzard confirms a native Gamepad (Alpha) interface. September 24 adds compact presentation of the active bar, fixed party-member D-pad targeting outside raids, friendly/hostile targeting-side swaps, and Druid form/Hunter and Warlock pet/Paladin aura/Warrior stance flyouts. October 1 makes gamepad UI bindings static; rebinding affects keyboard/mouse UI. October 8 adds action-bar Edit Mode, per-UI-type saved layouts, raid traversal updates, and moves compact-bar settings into Edit Mode. [Official development notes](https://us.forums.blizzard.com/en/wow/t/wow-forever-beta-development-notes-%E2%80%93-updated-october-8/2360696)

The inspected official notes do **not** publish the complete default button table or an exact freely assignable spell capacity. Do not present one as official.

TriggerBar's author describes the existing native UI as four sets: **no trigger, LT, RT, LT+RT**, totaling 32 displayed slots. Their addon lays these sets beside one another, highlights the held-trigger section, and does not change bindings, targeting or shortcut/radial menus. This is primary developer observation of the beta's UI, not proof that all 32 slots accept arbitrary spells. [TriggerBar owner description](https://www.curseforge.com/wow/addons/triggerbar)

ControllerForever's owner describes replacing the native assignments on A/B/X/Y and other buttons, with LT/RT layers, targeting and wheels. This confirms that the addon's customized base face-button rotation is a deliberate modification; do not confuse it with Blizzard defaults. Its trackpad wheel selection and rear-button setup are addon features. [ControllerForever owner description](https://www.curseforge.com/wow/addons/controllerforever)

**Capacity interpretation:** four visual groups of eight imply 32 button/layer positions, not 32 freely assignable attacks. Preserve native reserved base functions until verified in the installed client. The precise default A/B/X/Y, D-pad, shoulder, menu and targeting combinations need a client capture. Three held-trigger banks may be the useful combat surface; their exact editable slots remain to be tested.

**Paging:** modifier banks, action-bar pages, class/form states and menu contexts are distinct. Holding LT should change the displayed layer immediately and return on release, rather than silently cycle a persistent page. Exact native page IDs and class replacement rules were not established. Compact mode is presentation, not extra capacity or arbitrary binding permission.

## ConsolePort conventions are a separate design

ConsolePort's Xbox source maps actions across unmodified, SHIFT, CTRL and CTRL-SHIFT combinations. Base A is Jump; shifted A is an action, CTRL-A opens its Quick Menu, CTRL-SHIFT-A its Utility Toggle. B/X/Y and D-pad combinations map to ordinary and multi-action-bar slots; Back combinations cover bags, character, map and autorun. The source supports alternate generated left-hand/trigger layouts. Therefore there is no universal ConsolePort layout to label as Blizzard's native LT/RT defaults. [Owned Xbox preset source](https://github.com/seblindfors/ConsolePort/blob/master/ConsolePort/Model/Gamepad/Xbox.lua)

Its Steam Deck preset explicitly maps emulated paddles through F1–F4 and supplies its own settings. Those mappings are an addon preset, not guaranteed unique native paddle IDs in Forever. [Owned Deck preset source](https://github.com/seblindfors/ConsolePort/blob/master/ConsolePort/Model/Gamepad/Deck.lua)

ConsolePort rings support press-point-release selection or explicit acceptance, a selectable Movement/Camera/Gyro stick, quest-item/extra-spell insertion, and shared versus character-specific ring data. These are useful conventions for an infrequent utility surface. [Owned ring database source](https://github.com/seblindfors/ConsolePort/blob/master/ConsolePort_Rings/Database.lua)

## Steam Deck and Steam Input lessons

Valve documents two trackpads and four assignable rear grip buttons. Its stated ergonomic purpose for grip buttons is operating controls while thumbs remain on sticks/trackpads. That hardware advantage does not automatically transfer to a flat phone touchscreen. [Valve hardware](https://www.steamdeck.com/en/hardware), [Valve specifications](https://www.steamdeck.com/en/tech/deck)

Steam Input supports small overlapping action-set layers, user-triggered layers in legacy mode, and multiple simultaneous layers. Valve warns that later layers override conflicts and excess layers confuse users. A legacy layer is not automatic game awareness: the user activates it. This is a good model for stable shell plus class/context patches, not evidence of native WoW or Thumble integration. [Valve action-set layers](https://partner.steamgames.com/doc/features/steam_controller/action_set_layers)

Valve radial menus support icons, explicit center cancel, configurable activation and up to 20 sectors. Trackpad-only touch-menu grids support up to 16 buttons. These are Steam Input capacities, not WoW native action-bar limits. They suggest optional utilities without requiring an oversized combat grid. [Valve radial menus](https://partner.steamgames.com/doc/features/steam_controller/radial_menus), [Valve touch menus](https://partner.steamgames.com/doc/features/steam_controller/touch_menus)

## Recommended Thumble pattern (proposal)

- Two stable movement/camera surfaces, separate target/interact controls, and **two four-icon crossbars** corresponding to D-pad and face buttons. Native base functions stay recognizable; holding LT, RT or both replaces crossbar ability pictures with the matching bank. The active modifier state must match the actual emitted inputs.
- A persistent bank preview helps learning; compact active-bank mode saves screen space. Keep this a user choice. Do not add persistent page cycling to the primary combat path unless the native client requires it.
- Move infrequent utilities—mount, bags, map, professions and class tools—to an explicit drawer or small radial with a cancel center. A direct emergency/interrupt control should remain accessible; the exact action and input are chosen per build.
- Keep positions stable across characters/specs, with user locks. Change pictures and class accent instead of moving the entire layout. Snapshot actual action slots after talent changes; manual build selection remains the fallback. Distinguish Forever talent trees/dual spec from Retail loadouts.
- Offer healer-friendly target controls reflecting native party targeting and a separate raid navigation workflow. Druid form/Warrior stance/pet actions are context, not a replacement for all utility controls.
- **Ergonomics gate:** a phone requires movement + modifier + attack simultaneously, possibly camera/targeting too. Physical triggers and rear paddles offload this from thumbs; drawn controls cannot. Test simultaneous touches, grip/reach, accidental releases, trigger release before attack release, focus changes, and reconnect. Consider large edge holds, explicit one-shot bank selection or touch latch options only after input semantics and stale-state recovery are proven. Do not promise comfortable two-thumb chording from visual inspection alone.

Implementation should begin with native input recognition and a recorded default control map from the exact Forever build. Then prototype the modifier interactions with placeholder icons before final artwork. No source or skin edits were made for this research.
