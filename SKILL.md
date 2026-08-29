---
name: thumble-keypad-generator
description: Generate, install, skin, edit, export/import, and runtime-control Thumble keypad profiles using the `thumble` CLI. Use whenever a user asks for a Thumble keypad, iPhone controller layout, game profile, keyboard-to-touch controls, shortcut pad setup, profile/template management, key binding changes, joystick/custom button layout changes, shareable skin creation (material JSON or CSS authoring), or Mac helper runtime actions such as status, pairing code/payload, accessibility, test tap, server restart, or release-all. For unknown games, research or infer controls, write an agent-provided JSON spec, dry-run it, and install it without asking the user unless they explicitly want custom controls.
---

# Thumble CLI / Keypad Generator

Use this skill to configure Thumble from the command line. Thumble turns an iPhone into a programmable keypad/controller for a Mac. The CLI can now do both agent-friendly game profile generation and most saved-configuration/runtime actions exposed by the macOS app.

## Decision tree

- User names a game and wants a keypad/controller profile → generate or write a spec, dry-run, install.
- User wants an emulator/controller-style layout → use `template list` / `template install`.
- User wants to change shortcuts → use `binding` commands.
- User wants shape/color/joystick/layout changes → use `customization` or `element` commands.
- User wants a shareable appearance-only skin (materials or CSS) → use `skin` commands; scaffold with `--css` for CSS authoring.
- User wants to customize the iPhone control bar or one of its buttons → use `control-bar` commands.
- User wants backup/restore/share → use `profile export` / `profile import`.
- User wants pairing/status/server/accessibility/test/release-all → use runtime commands.

## Build or locate the CLI

From the Thumble repo root:

```bash
xcodebuild -project Thumble.xcodeproj \
  -scheme ThumbleCLI \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData \
  build

THUMBLE_CLI="$PWD/build/DerivedData/Build/Products/Debug/thumble"
```

If `build/DerivedData/Build/Products/Debug/thumble` already exists and is recent enough, reuse it. New subcommands land in source before any prebuilt binary: if an existing binary rejects a subcommand documented here (probe with `"$THUMBLE_CLI" skin css capabilities`), rebuild it from the current source.

Note: the `skin` family is CLI-only. It is not part of the MCP tool surface (local stdio adapter or hosted gateway), so skin scaffold/lint/compile/quality/preview always run through the local `thumble` CLI; do not look for skin MCP tools. MCP tools cover status, pairing, input, profiles, configuration drafts, catalog queries, and rendering.

## Generate a game profile

Try built-in game generation first:

```bash
"$THUMBLE_CLI" generate "Hollow Knight" --dry-run
"$THUMBLE_CLI" generate "Hollow Knight"
```

If there is no built-in game template, the agent is the fallback: research or infer controls, write a JSON spec, dry-run, then install.

Research controls in this order when practical:

1. Local game config files or launcher settings.
2. Official docs, in-game manuals, or support pages.
3. Reputable community wiki/default-controls pages.
4. Common genre conventions plus the agent's best guess.

If uncertain, still create a playable spec, set `confidence` to `low`, and mention the caveat in `notes`.

### Minimal agent spec

```json
{
  "gameName": "Celeste",
  "source": "Agent best guess from common/default keyboard controls",
  "confidence": "low",
  "notes": [
    "Generated from the agent's best guess. Adjust in Thumble Mac if your in-game bindings differ."
  ],
  "controls": [
    { "label": "Left", "key": "LeftArrow", "role": "movement" },
    { "label": "Right", "key": "RightArrow", "role": "movement" },
    { "label": "Up", "key": "UpArrow", "role": "movement" },
    { "label": "Down", "key": "DownArrow", "role": "movement" },
    { "label": "Jump", "key": "C", "role": "primary", "widthScale": 1.45, "heightScale": 1.3 },
    { "label": "Dash", "key": "X", "role": "primary", "widthScale": 1.45, "heightScale": 1.3 },
    { "label": "Climb", "key": "Z", "role": "secondary", "widthScale": 1.15, "heightScale": 1.05 },
    { "label": "Pause", "key": "Escape", "role": "system" }
  ]
}
```

Run:

```bash
"$THUMBLE_CLI" generate --spec /tmp/game-keypad.json --dry-run
"$THUMBLE_CLI" generate --spec /tmp/game-keypad.json
# or stdin
"$THUMBLE_CLI" generate --stdin < /tmp/game-keypad.json
```

By default, `generate` installs, selects, and marks the profile as default. If Thumble Mac is running, it reloads and pushes the selected keypad to the paired iPhone.

Useful variants:

```bash
"$THUMBLE_CLI" generate --spec /tmp/game-keypad.json --no-default
"$THUMBLE_CLI" generate --spec /tmp/game-keypad.json --no-select
"$THUMBLE_CLI" install-spec /tmp/game-keypad.json
"$THUMBLE_CLI" generate --spec /tmp/game-keypad.json --json --dry-run
```

Agent specs are planned deterministically in Rust and, when installed, cross
the same revision-safe profile-artifact import boundary as shared profiles.
`--json` emits exactly one generated-profile document for both dry-run and
install; installation receipts go to stderr. Slot/capacity loss and reused
layout defaults are explicit warnings (`--strict-layout` rejects them). Specs
are appearance/layout/binding data only: paths, URLs, embedded assets,
credentials, commands, and asset-backed image/tile fills are rejected.

## Agent spec fields

Top-level fields:

| Field | Required | Purpose |
|---|---:|---|
| `gameName` | yes | Profile name shown in Thumble. Aliases: `name`, `game`. |
| `source` | recommended | Where controls came from, or why this is a best guess. |
| `confidence` | recommended | `high`, `medium`, or `low`. |
| `notes` | optional | Caveats or context. |
| `controls` | yes | Array of control objects. |

Control fields:

| Field | Required | Purpose |
|---|---:|---|
| `label` | yes | Visible text on the iPhone button. |
| `key` | yes | Mac key to inject. Still required for joystick specs. |
| `modifiers` | optional | Array of `command`, `shift`, `option`, `control`. |
| `role` | recommended | `movement`, `primary`, `secondary`, `utility`, `system`; helps placement/style. |
| `button` | optional | Explicit Thumble slot. Usually omit and let the CLI infer. |
| `centerX`, `centerY` | optional | Normalized position `0.0`–`1.0`. Aliases: `x`, `y`. |
| `widthScale`, `heightScale` | optional | Button size multipliers — see [Size controls for thumbs](#size-controls-for-thumbs); omit to get thumb-sized role defaults. Aliases: `width`, `height`. |
| `shape` | optional | `rounded_rectangle`, `rectangle`, `capsule`, `circle`, `ellipse`, `polygon`, `star`. |
| `accentStyle` | optional | `monochrome`, `blue`, `green`, `purple`, `pink`, `amber`. |
| `fill`, `fillHex`, `color`, `fillColor` | optional | Hex fill color like `#7C3AED`, or `fillColor` object. |
| `thumbFill`, `thumbColor`, `knobColor`, `joystickThumbFill`, `joystickKnobFill`, `joystickKnobColor` | optional | Hex color for a joystick's moving thumb/knob. |
| `styleID`, `visualStyle`, `pressedFill`, `stroke`, `strokeWidth`, `foreground`, `glow`, `glowRadius`, `opacity` | optional | Rich design styling fields for reusable/editor-quality appearances. |
| `icon`, `iconName`, `sfSymbol`, `iconText`, `hapticStyle` | optional | SF Symbol/text icon and per-control haptic style. |
| `cornerRadius` | optional | Rounded-rectangle corner radius. |
| `shadowStrength` | optional | Shadow multiplier `0`–`2`. |
| `isHidden` | optional | Hide this control. |
| `isLocationLocked` | optional | Prevent drag repositioning in the Mac editor. |
| `kind` / `controlKind` | optional | `button`, `joystick`, `trigger`, `trackpad`, `text`, or `decoration` for saved element/profile editing. `text` and `decoration` are passive; agent-generated action specs still require a keyboard `key`. |
| `trackpadSettings` | optional | Object with `sensitivity`, `scrollSensitivity`, `tapToClick`, `twoFingerScroll`, and `naturalScrolling` for trackpad components. |
| `sensitivity`, `cursorSensitivity`, `pointerSensitivity` | optional | Trackpad cursor sensitivity multiplier (`0.2`–`4.0` after normalization). Implies `kind: "trackpad"` if no kind is set. |
| `scrollSensitivity` | optional | Trackpad scroll sensitivity multiplier (`0.1`–`4.0` after normalization). |
| `tapToClick`, `twoFingerScroll`, `naturalScrolling` / `naturalScroll` | optional | Trackpad gesture toggles. |
| `joystickMapping` | optional | Object mapping joystick directions to Thumble button slots. |
| `up`, `down`, `left`, `right` | optional | Direction aliases for joystick mappings; values are Thumble slots, not keyboard keys. |

Valid `button` slots:

```txt
up, down, left, right, jump, attack, dash, focus, map, pause,
custom1, custom2, custom3, custom4, custom5, custom6, custom7, custom8
```

### Size controls for thumbs

Thumble renders on a phone held in two hands; controls must be thumb-sized, not mouse-pointer-sized. Do not treat `widthScale`/`heightScale` of `1.0` as "normal button" — think of it as a baseline to grow from.

How sizes resolve on the reference canvas (iPhone-class landscape, ~874×402pt):

- A plain button at scale `1.0` renders ≈86×86pt; the profile-wide `controlScale` multiplies that (`compact` 0.86, `standard` 1.0, `large` 1.14).
- Joystick pads default to `1.35` (~163pt); map/pause capsules use wider bases (~127×62 and ~143×62 at `1.0`).

Recommended scales when writing a spec:

| Role | widthScale/heightScale | Rendered size | Notes |
|---|---|---|---|
| Primary actions (jump/attack/dash) | 1.3–1.6 | ~110–138pt | The most-used controls should be the biggest. |
| Movement / d-pad | 1.1–1.25 | ~95–107pt | Rounded squares read as a d-pad cluster. |
| Secondary (heal, cast, aim) | 1.05–1.2 | ~90–103pt | |
| Utility (map, inventory) | 1.0–1.1 | ~86–95pt | |
| System (pause, menu) | 0.9–1.05 | ~82–90pt | Rarely pressed; can stay modest. |

Floors and spacing:

- Never let any interactive control render under 44pt on its shortest side (`layout validate` warns `small-control`); aim for ≥66pt everywhere and ≥90pt for primary actions.
- Leave breathing room: overlapping hit regions warn as `expanded-hit-overlap`. Space clusters ~20pt apart visually.
- `generate --dry-run` prints every control's rendered pt size and flags anything under 66pt — read that output and fix sizes before installing.
- For an overall bump without touching every control: `thumble customization set --control-scale large` (multiplies the whole layout by 1.14).

When a spec omits `centerX`/`centerY`/`widthScale`/`heightScale`, the CLI places controls in thumb-reach clusters using the sizes above, so omitting sizes still produces a playable, thumb-sized layout.

Common supported key names:

```txt
A-Z, 0-9, LeftArrow, RightArrow, UpArrow, DownArrow,
Escape, Esc, Tab, Space, Spacebar, Return, Enter,
Delete, Backspace, ForwardDelete,
F1-F17, Home, End, Page Up, Page Down
```

### Styled joystick spec example

```json
{
  "gameName": "Twin Stick Example",
  "source": "Agent-provided layout",
  "confidence": "medium",
  "controls": [
    { "label": "Move", "key": "W", "button": "custom1", "kind": "joystick", "up": "up", "down": "down", "left": "left", "right": "right", "fill": "#111827", "thumbFill": "#F8FAFC", "centerX": 0.22, "centerY": 0.64, "widthScale": 1.35, "heightScale": 1.35 },
    { "label": "Aim", "key": "I", "button": "custom2", "kind": "joystick", "up": "custom1", "down": "custom2", "left": "custom3", "right": "custom4", "fill": "#7C3AED", "thumbFill": "#FDE68A", "centerX": 0.78, "centerY": 0.64, "widthScale": 1.35, "heightScale": 1.35 },
    { "label": "Fire", "key": "Space", "button": "jump", "role": "primary", "fill": "#F59E0B", "shape": "circle", "widthScale": 1.5, "heightScale": 1.5 },
    { "label": "Pause", "key": "Escape", "button": "pause", "role": "system" }
  ]
}
```

### Trackpad sensitivity spec example

```json
{
  "gameName": "Remote Desktop Pad",
  "source": "Agent-provided layout",
  "confidence": "medium",
  "controls": [
    { "label": "Trackpad", "key": "Space", "kind": "trackpad", "sensitivity": 1.8, "scrollSensitivity": 1.1, "tapToClick": true, "twoFingerScroll": true, "naturalScrolling": false, "centerX": 0.50, "centerY": 0.58, "widthScale": 1.35 }
  ]
}
```

## Profile management

```bash
"$THUMBLE_CLI" profile list --ids
"$THUMBLE_CLI" profile show active --json
"$THUMBLE_CLI" profile create "My Setup" --blank
"$THUMBLE_CLI" profile create "SNES Setup" --template snes
"$THUMBLE_CLI" profile select "My Setup"
"$THUMBLE_CLI" profile default "My Setup"
"$THUMBLE_CLI" profile rename "My Setup" "Browser Shortcuts"
"$THUMBLE_CLI" profile duplicate "Browser Shortcuts" "Browser Copy"
"$THUMBLE_CLI" profile delete "Browser Copy"
"$THUMBLE_CLI" profile reset active
"$THUMBLE_CLI" profile export --all -o thumble-profiles.json
"$THUMBLE_CLI" profile import thumble-profiles.json
```

## Controller templates

Use these for emulator/controller-style layouts rather than game-specific key generation:

```bash
"$THUMBLE_CLI" template list
"$THUMBLE_CLI" template show snes
"$THUMBLE_CLI" template install snes --name "SNES" --default
```

Templates include NES, Super Nintendo, Nintendo 64, GameCube, Game Boy, Game Boy Advance, Genesis 6-Button, Sega Saturn, Dreamcast, Arcade Stick, PSP, PlayStation, and Xbox.

## Shareable skins

Use `.pocketpad` skins for appearance-only sharing. They preserve profile geometry, labels, keyboard/controller bindings, launch targets, native controls, and accessibility:

```bash
"$THUMBLE_CLI" skin artboard list
"$THUMBLE_CLI" skin scaffold "Indigo Pocket" --identifier com.creator.indigo-pocket --artboard showcase-controller-v1 -o ./IndigoPocket
"$THUMBLE_CLI" skin compile ./IndigoPocket -o ./IndigoPocket/build/indigo-pocket.pocketpad --clean --strict
"$THUMBLE_CLI" skin validate ./IndigoPocket/build/indigo-pocket.pocketpad --strict
"$THUMBLE_CLI" skin quality ./IndigoPocket --artboard showcase-controller-v1 --strict
"$THUMBLE_CLI" skin preview ./IndigoPocket -o ./IndigoPocket/reviews/contact-sheet.png --all-variants --all-states --native-renderer --contact-sheet
"$THUMBLE_CLI" skin list
"$THUMBLE_CLI" skin inspect ./IndigoPocket/build/indigo-pocket.pocketpad
"$THUMBLE_CLI" skin import ./IndigoPocket/build/indigo-pocket.pocketpad
"$THUMBLE_CLI" skin apply com.example.pocketpad.skin.aurora --profile "My Setup"
"$THUMBLE_CLI" skin detach --profile "My Setup"
```

### CSS-authored skins

The same skin workflow can be driven by real CSS (profile `thumble-css-core-1`) instead of material JSON. CSS is a compile-time authoring format — it lowers into the same deterministic native style model, and no stylesheet ever ships inside the package or runs at runtime:

```bash
"$THUMBLE_CLI" skin scaffold "My Skin" --identifier com.creator.my-skin --css -o ./MySkin
"$THUMBLE_CLI" skin css capabilities          # live property/selector/limit list
"$THUMBLE_CLI" skin css lint ./MySkin
"$THUMBLE_CLI" skin css computed ./MySkin --control builtin-jump --scheme dark --state pressed
"$THUMBLE_CLI" skin compile ./MySkin --clean --strict
```

Style controls with semantic selectors (`control[role="primary_action"]`, `#builtin-jump`, `:pressed`, `@media (prefers-color-scheme: dark)`) so one skin covers any profile using the same roles. Unsupported CSS is a strict compile error, never silently ignored. See `docs/skins/css-authoring.md` and the complete example at `docs/skins/examples/css-first-light/`.

Assign reusable semantic roles and independent touch expansion while creating a keypad:

```bash
"$THUMBLE_CLI" element set jump --skin-role primary-action --hit-insets 16
"$THUMBLE_CLI" element set pause --skin-role menu --hit-insets 10,18,14,18
```

For handcrafted skin creation or critique, load the project `thumble-skin-author` skill and use its separate art-director, designer, visual-critic, and QA stages. Human approval of the exact final contact sheet and package hash is required before directory publication. See `docs/skins/README.md` for authoring source, canonical artboards, package schemas, layers, nine-slice assets, quality gates, and security rules.

## Shortcut bindings

```bash
"$THUMBLE_CLI" binding list
"$THUMBLE_CLI" binding set jump Return
"$THUMBLE_CLI" binding set dash --key K --modifiers command
"$THUMBLE_CLI" binding set focus --sequence 'Control+B,H'
"$THUMBLE_CLI" binding reset jump
"$THUMBLE_CLI" binding clear custom1
"$THUMBLE_CLI" binding reset-all
```

Use `--profile PROFILE` on binding commands to target a non-active profile.

## Customization and elements

Setup-level customization:

```bash
"$THUMBLE_CLI" customization show --profile active
"$THUMBLE_CLI" customization set --appearance dark --device iphone-17-pro --background '#101014'
"$THUMBLE_CLI" customization set --background-gradient '#101014,#4338CA' --gradient-angle 45
"$THUMBLE_CLI" customization export -o customization.json
"$THUMBLE_CLI" customization import customization.json
"$THUMBLE_CLI" customization reset
```

Element-level controls:

```bash
"$THUMBLE_CLI" element list
"$THUMBLE_CLI" element add button --label Fire --maps-to custom1 --x 0.50 --y 0.80 --light-fill '#F59E0B' --dark-fill '#78350F'
"$THUMBLE_CLI" element add joystick --label "Right Stick" --fill '#111827' --thumb-fill '#F8FAFC' --up custom1 --down custom2 --left custom3 --right custom4
"$THUMBLE_CLI" element add trackpad --label Trackpad --x 0.50 --y 0.58 --width 1.25 --sensitivity 1.2 --scroll-sensitivity 0.85 --tap-to-click true
"$THUMBLE_CLI" element add text --text A --x 0.72 --y 0.66 --text-color '#FFFFFF'
"$THUMBLE_CLI" element set jump --keyboard Space --hide-integrated-label --light-fill '#7C3AED' --dark-fill '#C4B5FD' --shape circle --width 1.2 --height 1.2 --z-index 10
"$THUMBLE_CLI" element set "Right Stick" --thumb-fill '#22C55E'
"$THUMBLE_CLI" element set focus --icon sf:sparkles --haptic medium --stroke '#38BDF8' --pressed-fill '#0EA5E9' --glow '#0EA5E9' --glow-radius 12
"$THUMBLE_CLI" element set jump --lock
"$THUMBLE_CLI" element set pause --hide
"$THUMBLE_CLI" element reset jump
"$THUMBLE_CLI" element delete custom1
```

Appearance/design flags:

- `customization set --appearance system|light|dark` saves the selected setup's runtime appearance preference.
- `element set BUTTON --light-fill '#RRGGBB' --dark-fill '#RRGGBB'` saves separate button fills for both palettes.
- `--fill '#RRGGBB'` remains the shared/legacy fill for both palettes; `--clear-light-fill`, `--clear-dark-fill`, and `--clear-fill` remove custom colors.
- `style list|create|show|apply|detach|delete|export|import` manages reusable style tokens.
- `element set BUTTON --z-index -100...100` sets explicit stack order; `layer list|move|front|back|bring-forward|send-backward` still manages same-z tie order.
- `group list|create|ungroup|hide|show|lock|unlock` stores editor groups and can apply group visibility/lock to child controls. Use `element add text`, hide a button’s legacy caption with `--hide-integrated-label`, then group both layers for a composed visual label.
- `asset import|list|remove` stores profile-local design assets for future icon/background workflows.

## iPhone control bar

Control-bar items keep their built-in actions, but their order, visibility, icon, size, fill, shape, corners, effects, and haptics can be customized per portrait/landscape variant:

```bash
"$THUMBLE_CLI" control-bar list --json
"$THUMBLE_CLI" control-bar set status,profiles,launch,spacer,edit,settings,home,connection
"$THUMBLE_CLI" control-bar move settings earlier
"$THUMBLE_CLI" control-bar item show settings --json
"$THUMBLE_CLI" control-bar item set settings --icon sf:slider.horizontal.3 --fill '#111827' --corner 12
"$THUMBLE_CLI" control-bar item set connection --width 1.25 --height 1.1 --haptic medium
"$THUMBLE_CLI" control-bar item reset settings
"$THUMBLE_CLI" control-bar reset
```

Use `--variant portrait|landscape` and `--profile PROFILE` as needed. A control-bar item's semantic action is fixed: styling `home`, for example, cannot turn it into a keyboard shortcut.

## Runtime Mac helper commands

Thumble Mac must be running for most runtime commands. `app open` launches it first.

```bash
"$THUMBLE_CLI" app open
"$THUMBLE_CLI" app screenshot -o /tmp/thumble-window.png --json
"$THUMBLE_CLI" status --json
"$THUMBLE_CLI" server start
"$THUMBLE_CLI" server stop
"$THUMBLE_CLI" server restart
"$THUMBLE_CLI" server addresses
"$THUMBLE_CLI" pairing code
"$THUMBLE_CLI" pairing payload
"$THUMBLE_CLI" pairing cancel
"$THUMBLE_CLI" accessibility status
"$THUMBLE_CLI" accessibility prompt
"$THUMBLE_CLI" accessibility open
"$THUMBLE_CLI" latency simulate --pattern hollow-knight --mode compare --log /tmp/thumble-latency.json
"$THUMBLE_CLI" latency verify --max-ms 4 --p95-ms 4 --log /tmp/thumble-latency-verify.json
"$THUMBLE_CLI" test tap jump
"$THUMBLE_CLI" test down left
"$THUMBLE_CLI" test up left
"$THUMBLE_CLI" release-all
```

For visual verification, agents must use `app screenshot` instead of activating Thumble, sending key events, running AppleScript, or taking a full-screen capture. It captures only the largest visible Thumble window and does not move focus or control the user's screen. Use `--window-title TEXT` to choose among multiple app windows. If Thumble is not running, ask the user to open it; do not launch it without permission because launching can change focus. If Screen Recording access is unavailable, stop and ask the user to grant it to the terminal or agent host; do not trigger permission UI or fall back to screen control.

Use `latency simulate` before UI automation when investigating controller lag. It is headless and emits per-edge touch-to-injection timings; supported patterns are `hollow-knight`, `same-button-burst`, `udp-recovery`, and `udp-recovery-burst`, with modes `current`, `legacy-main-actor`, or `compare`. Use `latency verify` as the pass/fail gate for whether the current input path is below the configured lag budget.

## Quality checklist before installing a game spec

- Movement keys are present unless the game does not use movement.
- At least one primary action exists for action games.
- Controls are thumb-sized: primary actions ≥90pt rendered, everything ≥66pt; the dry-run size table flags anything smaller.
- Pause/menu is mapped when the game has one.
- Joystick direction aliases map to Thumble slots, not keyboard keys.
- `confidence` honestly reflects certainty.
- `source` explains where the mapping came from.
- `--dry-run` lists the expected bindings and does not fail.

## User-facing summary

After installing, respond with a short summary:

```txt
Created and selected a Thumble profile for Celeste.
Confidence: low — this is an agent best guess from common/default controls.

Bindings:
- Move: Arrow keys
- Jump: C
- Dash: X
- Climb: Z
- Pause: Esc

If your in-game bindings differ, I can update the profile from the CLI or you can edit it in Thumble Mac's Keypad editor.
```

## Troubleshooting

- **No built-in game template**: create `--spec` JSON. Do not ask the app to invent a generic fallback.
- **Need a controller layout, not a game profile**: use `template install`.
- **Unsupported key**: change `key` to a supported key name, then rerun `--dry-run`.
- **Malformed JSON**: validate the file or rewrite it with strict JSON syntax.
- **Profile does not appear on iPhone**: make sure Thumble Mac is running and the iPhone is paired; rerun the install command or restart Thumble Mac.
- **Runtime status missing**: run `thumble app open`, then `thumble status` again.
- **Controls feel wrong in-game**: update the JSON/spec or use `binding set` / `element set` rather than asking the user to hand-edit everything.
