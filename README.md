# Thumble

Thumble turns an iPhone into a programmable shortcut keypad for your Mac. The iPhone pairs with a macOS SwiftUI helper over WebSocket on a local network or Apple peer-to-peer path, sends realtime button state transitions over an authenticated UDP fast path with WebSocket mirroring as fallback, and the helper injects keyboard shortcuts with Accessibility-approved `CGEvent` key down/up events.

It is no longer game-specific: use it for terminal workflows, tmux prefixes, Cursor shortcuts, window management, or any Mac app that responds to keyboard input.

## Targets

- `ThumbleMac` — macOS 14+ SwiftUI helper, WebSocket pairing/control server plus UDP realtime listener preferring port `8765` with automatic fallback if unavailable, Bonjour Smart Connect advertising with peer-to-peer enabled, CGEvent keyboard shortcut injection.
- `ThumbleiOS` — iOS 17+ SwiftUI programmable keypad with multitouch controls and Smart Connect reconnects.
- `ThumbleCLI` — macOS command-line configuration and control tool for generating, editing, importing/exporting, selecting, and testing keypad profiles for the Mac helper.
- `Host/crates/thumble-host` — standalone Rust macOS receiver MVP with the same current iOS pairing and reliable WebSocket input protocol, native Bonjour discovery, persistent migration, and a local lifecycle CLI.
- `Host/crates/thumble-mcp` — local stdio MCP adapter exposing curated host status, pairing, profiles, installed controls, revision-safe controller drafts, MCP Apps previews/editing, and emergency release tools to Claude, OpenAI Codex, and compatible clients.
- `ThumbleBridge` / `thumble-bridge` — packaged, bounded Swift model transformer for allowlisted rich profile/theme/orientation operations; it receives no state paths, credentials, argv, or persistence authority. See [`docs/rust-host.md`](docs/rust-host.md).

For upgrade compatibility, the existing app bundle identifiers, `_pocketpad._tcp` Bonjour service, pairing payload type, defaults keys, and keypad export schema remain unchanged internally. The CLI build makes `thumble` canonical while continuing to ship `thumbconsole` and `pocketpad` compatibility executables for existing scripts.

## Build

```bash
xcodegen generate
xcodebuild -project Thumble.xcodeproj -scheme ThumbleMac -destination 'platform=macOS' build
xcodebuild -project Thumble.xcodeproj -scheme ThumbleiOS -destination 'generic/platform=iOS Simulator' build
xcodebuild -project Thumble.xcodeproj -scheme ThumbleCLI -destination 'platform=macOS' build
./scripts/verify-rust-host.sh
```

Before merging changes to shared models, codecs, profile synchronization, skins, or app startup, run the repository-wide stack-safety gate on Apple silicon (arm64):

```bash
./scripts/verify-stack-safety.sh
```

See [`docs/stack-safety.md`](docs/stack-safety.md) for the inline-size budgets, constrained-stack testing policy, and design rules for large Swift values.

## Distribution

Thumble has first-pass release automation for both shipping channels:

```bash
# macOS direct download: Developer ID export, notarize, zip, upload to Cloudflare R2.
scripts/release/macos-cloudflare.sh --version 1.0.0 --build-number 1

# iOS beta: archive/export an IPA, upload it, and distribute to a TestFlight group.
scripts/release/ios-testflight.sh --app "$ASC_APP_ID" --group "Internal Testers"

# Standalone Rust host: universal background app, ad-hoc or Developer ID/notarized.
scripts/release/macos-host.sh --version 0.1.0 --build-number 1
```

Cloudflare Pages serves `/api/releases/latest-mac` and `/api/download-mac` from the `RELEASES` R2 binding. Create the bucket with `wrangler r2 bucket create pocketpad-releases`, then deploy the `Website` project after the binding exists. The macOS release script expects Wrangler auth plus either `asc` API-key notarization auth or notarization credentials via `NOTARYTOOL_KEYCHAIN_PROFILE` / `APPLE_ID`, `APP_SPECIFIC_PASSWORD`, and `ASC_TEAM_ID`.

The iOS script uses the `asc` CLI. Set `ASC_APP_ID` (or pass `--app`) and optionally `THUMBLE_TESTFLIGHT_GROUP`; it resolves a remote-safe build number when App Store Connect is reachable.

## Use

1. Run `ThumbleMac` on the Mac.
2. Grant Accessibility permission when prompted, then restart/refresh if needed.
3. Run `ThumbleiOS` on the iPhone and tap **Scan Mac QR Code** to connect instantly, or manually enter one of the displayed `ws://<mac-ip>:<port>` addresses and tap **Request Pairing**. QR pairing can also discover the Mac over nearby peer-to-peer when there is no Wi‑Fi router.
4. For manual pairing, enter the six-digit code shown in the Mac helper's secure pairing card.
5. After the first successful pair, **Smart Connect** remembers this Mac, discovers it over Bonjour, and reconnects automatically when the iOS app opens or returns to foreground.
6. The iOS app also keeps the last synced keypads available for viewing and switching even when Thumble Mac is not open.
7. Focus the Mac app you want to control, such as Terminal, Cursor, or a browser.

For airplane/offline use, turn on Airplane Mode if desired, then manually re-enable Wi‑Fi and Bluetooth. Thumble can use Apple peer-to-peer discovery without internet or a router; if both radios are off, wireless control is not possible.

## Use with AI coding agents

The standalone Rust distribution includes `thumble-mcp`, a local MCP `2025-11-25` stdio server for Claude, OpenAI Codex, and compatible clients. It talks only to the running host's user-only control socket and exposes twenty-one curated tools, including a bounded controller-template catalog, revision-aware private draft editing, constrained Swift generation/profile/theme/orientation transforms, deterministic seven-kind `customization.fix`, revision-safe typed non-file `control-bar.item.set`, safe non-file six-kind `element.add` and `element.set`, three-way rebase, safe SVG preview export, and atomic save, without authentication tokens, raw key codes, asset/image payloads, caller paths, arbitrary input text, or shell execution. `render_controller` returns a bounded geometry, sanitized native normal-state appearance, and message-free layout-quality snapshot plus an embedded MCP Apps `2026-01-26` SVG interface for compatible clients, with structured/text fallback elsewhere. Input is disabled unless the MCP process is explicitly launched with `--allow-input`; `release_all` is always available. Configuration examples and the complete tool contract are in [`docs/rust-host.md`](docs/rust-host.md#mcp-adapter).

Thumble also includes a ready-to-use [`SKILL.md`](SKILL.md) that teaches terminal-capable agents how to inspect the current setup, generate or edit profiles, validate layouts, operate the Mac helper safely, and verify their work. Hosted-builder phases 0–3 plus local integrations for phases 4–6 are implemented: independent capability contracts, portable profile artifacts, deterministic Rust generation-spec planning, pure replay-safe builder sessions/templates, resource-isolated OAuth, the nine-tool Streamable HTTP builder, fragment-token artifact sharing, defensive iPhone pickup/quarantine/practice-preview/paired-adoption, and the Mac "Import Shared Keypad…" desktop entry. Cloud skins stay local-only (decision in the hosted-builder plan). These capabilities remain partial and unavailable pending explicit production deployment approval, physical-device acceptance, and visible ChatGPT acceptance. Give the agent the skill's absolute path plus the outcome you want; you do not need to write the CLI commands yourself.

```text
Read /absolute/path/to/Thumble/SKILL.md, then use the thumble CLI to
create a landscape keypad for Celeste. Research the default Mac controls, dry-run
before installing, preserve unrelated profiles, validate the result, and report
the source, confidence, final bindings, and whether sync could be confirmed.
```

See [Using Thumble with an AI agent](docs/agents.md) for reusable agent instructions, skill setup, safe automation boundaries, an inspect, preview, apply, and verify workflow, and copy-paste prompts for games, productivity apps, layout repair, diagnostics, and skins.

## Programmatic keypad generation

Build the CLI target and generate a game-specific profile from just a game name:

```bash
xcodebuild -project Thumble.xcodeproj -scheme ThumbleCLI -destination 'platform=macOS' build
~/Library/Developer/Xcode/DerivedData/Thumble-*/Build/Products/Debug/thumble generate "Hollow Knight"
```

`thumble generate` installs, selects, and marks the generated profile as default. If `ThumbleMac` is running, it reloads the profile store and pushes the selected keypad to the paired iPhone. Use `--dry-run` to preview without installing, `--json` to inspect the generated profile, and `thumble profile list` to view installed profiles. The CLI build also produces `thumbconsole` and `pocketpad` compatibility executables so existing scripts continue to work after the rename.

The first built-in template is Hollow Knight, including aliases like “Hollow Night” from speech recognition. Unknown games intentionally do **not** use a deterministic fallback. Instead, the calling agent should make its own best guess and pass a JSON spec:

```bash
thumble generate --spec /tmp/celeste-keypad.json
# or
thumble generate --stdin < /tmp/celeste-keypad.json
```

Example agent spec:

```json
{
  "gameName": "Celeste",
  "source": "Agent best guess from default keyboard controls",
  "confidence": "low",
  "controls": [
    { "label": "Left", "key": "LeftArrow", "role": "movement" },
    { "label": "Right", "key": "RightArrow", "role": "movement" },
    { "label": "Up", "key": "UpArrow", "role": "movement" },
    { "label": "Down", "key": "DownArrow", "role": "movement" },
    { "label": "Jump", "key": "C", "role": "primary" },
    { "label": "Dash", "key": "X", "role": "primary" },
    { "label": "Climb", "key": "Z", "role": "secondary" },
    { "label": "Pause", "key": "Escape", "role": "system" }
  ]
}
```

## CLI configuration parity

The CLI can perform the same saved-configuration work as the macOS **Keypad** editor:

```bash
thumble profile list --ids
thumble template list
thumble template install snes --name "SNES Browser Controls" --default
thumble profile attach-app "SNES Browser Controls" --path /Applications/OpenEmu.app
thumble profile launch "SNES Browser Controls"
thumble profile export --all -o thumble-profiles.json
thumble profile import thumble-profiles.json
thumble binding set focus --sequence 'Control+B,H'
thumble output mode keyboard   # or controller/custom per setup
thumble customization set --appearance dark --device iphone-17-pro --background '#101014'
thumble customization set --background-gradient '#101014,#4338CA' --gradient-angle 45
thumble orientation get --profile "SNES Browser Controls"
thumble orientation set landscape --profile "SNES Browser Controls"
thumble device set iphone-17-pro --orientation landscape
thumble element add joystick --label "Right Stick" --fill '#111827' --thumb-fill '#F8FAFC' --up custom1 --down custom2 --left custom3 --right custom4
thumble element add joystick --label Nub --thumbstick --target right-stick --no-digital-directions --x 0.5 --y 0.58
thumble element add text --text A --x 0.72 --y 0.66 --text-color '#FFFFFF'
thumble element set jump --keyboard Space --hide-integrated-label --light-fill '#7C3AED' --dark-fill '#C4B5FD' --shape circle --width 1.2 --height 1.2 --z-index 10
thumble element set "Right Stick" --thumb-fill '#22C55E'
thumble style create Soul --fill '#F8FAFC' --stroke '#38BDF8' --pressed-fill '#0EA5E9' --glow '#0EA5E9' --glow-radius 12 --icon sf:sparkles --haptic medium --haptic-pattern double --haptic-intensity 75%
thumble style apply soul focus
thumble layer front focus
thumble group create Actions jump attack dash focus
thumble asset import ./orb.png --role icon --name SoulOrb
thumble skin list
thumble skin pack docs/skins/starter -o Aurora.pocketpad
thumble skin apply Aurora.pocketpad --profile "SNES Browser Controls"
```

Controller-shaped templates now install with a complete starter keyboard map instead of inheriting unrelated shortcuts from the active setup: WASD movement, Space/J/Shift/E actions, Tab/Esc menus, arrow-key right-stick directions, and Q/R/Z/X for the remaining shoulder and trigger slots. These are intentionally generic game defaults; customize them for a game's own controls. Select one control and press **Command-B** to Quick Bind its key press without hunting for the shortcut field. **Reset All** in the Mac editor and `thumble binding reset-all` restore the defaults for that setup's source template.

Standalone CLI built-in Hollow Knight generation, all built-in template installs (including `profile create --template`), profile, orientation, binding, output, safe scalar/solid-background customization updates and deterministic canonical layout repairs, sanitized reusable-style list/show and all non-file style mutations, sanitized variant-scoped element/layer/group listing and all layer/group edits, checked-in device-frame, control-bar collection, and rich non-file control-bar item commands use the exact-sibling schema-v8 Rust authority bridge for identical online/offline revision-safe transactions; successful live-host saves queue the complete state for the paired iPhone. Binding/output reads return only bounded revision-tagged semantic keys, modifiers, gamepad buttons, and element-input IDs. Control-bar reads return ordered canonical item IDs or sanitized rendering-effective appearance—never raw key codes or profile documents. Older profiles without keyed maps use an independently reconstructed fixed fallback until their first transaction materializes those maps. Rust derives template/profile/custom-element IDs, exact catalog revisions, and replay outcomes without accepting unvalidated profile JSON. Spec-based generation is deterministic Rust planning followed by the same portable-artifact import transaction; profile export/import is likewise Rust-authoritative and bounded. Custom-size frames, rich customization background fills, image fills, asset icons, remaining customization reads/resets and issue-code-specific repair aliases, theme/element writes, style import/export, and skin/package artifact families still use the legacy path only when no Rust authority artifacts exist, and otherwise fail closed. Runtime commands are also available:

```bash
thumble app open
thumble app screenshot -o /tmp/thumble-window.png --json
thumble status --json
thumble server restart
thumble pairing payload
thumble accessibility status
thumble latency simulate --pattern hollow-knight --mode compare --log /tmp/thumble-latency.json
thumble latency verify --max-ms 4 --p95-ms 4 --log /tmp/thumble-latency-verify.json
thumble test tap jump
thumble release-all
```

`thumble app screenshot` captures only the largest visible Thumble Mac window without activating the app, moving focus, or sending keyboard/mouse events. Use `--window-title TEXT` when the app has multiple windows; Screen Recording access must already be granted to the terminal or agent host.

`thumble latency simulate` is a synthetic replay model for agent debugging, not an end-to-end device benchmark. It runs Hollow-Knight-style bursts, same-button mash bursts, and UDP recovery cases through the wire codec and sequence-buffer assumptions, then writes modeled per-edge timing. `thumble latency verify` validates those model assumptions. For production measurements, use `thumble monitor`: `input_pipeline` events report same-clock Mac decode, reorder wait, input processing, binding lookup, output injection, post-injection, deferred-output, and receive-to-processed timing. `thumble status` reports rolling pipeline and output-stage percentiles plus round-trip latency.

See [Input Latency and Reliability Optimization](docs/development-logs/2026-07-10-input-latency-and-reliability-optimization.md) for the protocol, queueing, recovery, and physical-device test work behind these measurements.

## Shareable Thumble skins

Thumble’s **Skins** library separates portable appearance from keypad layout and executable Mac/controller bindings. A validated `.pocketpad` ZIP can include base styling, semantic control-role rules, light/dark and portrait/landscape variants, external assets, preview images, creator metadata, and a license. Applying one preserves native SwiftUI controls, accessibility, dynamic labels, geometry, bindings, and user overrides. Installed packages and assets sync between the Mac and paired iPhone and remain available offline.

Browse reviewed packages in the static [website skin directory](Website/skins.html), or import from the Mac Skins page, iPhone Files/Share Sheet, or CLI. Handcrafted authors can scaffold editable JSON/SVG against canonical artboards, compile deterministic packages, render all native states, and run strict quality gates with `thumble skin artboard|scaffold|compile|preview|quality`. Skins can also be authored entirely in CSS against a semantic controller document with `thumble skin scaffold --css` and `thumble skin css capabilities|lint|computed`; CSS compiles into the same deterministic native packages and never ships at runtime. The project `thumble-skin-author` skill adds separate art-direction, design, visual-critique, QA, and human-approval stages. See the [skin format, source schema, CSS authoring guide, Indigo Pocket reference, security rules, and command workflow](docs/skins/README.md). The directory catalog, immutable packages, previews, submission guide, and reproducible build/verification scripts live under `Website/skins/` and `scripts/build-skin-directory.sh`.

```bash
thumble skin validate docs/skins/starter
thumble skin pack docs/skins/starter -o Aurora.pocketpad
thumble skin inspect Aurora.pocketpad
thumble skin render Aurora.pocketpad --clean -o Aurora-preview.png
thumble skin import Aurora.pocketpad
thumble skin apply com.example.pocketpad.skin.aurora --profile "My Keypad"
```

Full keypad JSON export remains the backup/interchange format for layouts and bindings. Use `.pocketpad` skin packages for community appearance sharing.

## Virtual gamepad output

Thumble can map keypad controls to system-visible virtual gamepad buttons, analog sticks, and triggers while keeping keyboard and pointer output available. Each keypad setup has an output mode: `keyboard` keeps the virtual controller off, `controller` applies the default Xbox-style virtual controller map, and `custom` uses per-button mixed bindings. Configure the mode and mappings in the macOS Keypad editor or with the CLI:

```bash
thumble output mode controller
thumble output mode keyboard --profile "SNES Browser Controls"
thumble output set jump --keyboard Space --gamepad south
thumble output set attack --gamepad west
thumble element add joystick --target left-stick --no-digital-directions
thumble element add trigger --target left --orientation horizontal --sensitivity 1.2
```

On macOS, the virtual controller is created with `IOHIDUserDevice` and requires the Apple-granted `com.apple.developer.hid.virtual.device` signing entitlement. If the Mac app is not signed with that entitlement, keyboard/pointer output continues to work, but macOS Game Controller settings and games will show no controller. `thumble status` reports the virtual gamepad availability and the entitlement error when creation is denied.

## Keypad customization

Customize keypad setups from the macOS helper's **Keypad** section or with the CLI. The iOS app receives the Mac's saved setups during pairing, can switch between them from the in-controller **Keypad setup** menu, and can mark the current setup as the default. The macOS helper can also mark any setup as default from the Keypad editor. To create a JSON backup on Mac, use the **Export** menu above the setup list and choose **Export Current Setup…** or **Export All Setups…**. Restore a full backup, individual profile, generated profile, or raw customization from the adjacent **Import** menu; imports can replace matching setups or create new copies. On iPhone, open the in-controller **Keypad setup** menu and choose **Export Keypads as JSON** to save the synced setups locally with Files.

Thumble uses its own versioned JSON envelope because there is no broadly adopted interchange format for these multitouch keypad layouts. The current schema is `com.codybontecou.pocketpad.keypad-configuration` version `4`; it stores `profiles`, `activeProfileID`, and `defaultProfileID`. Mac app and CLI exports use the same envelope and may include macOS-only `profileKeyBindings` and `profileOutputBindings` so backups preserve shortcut and controller mappings too.

Each setup stores its own keypad-level preferences. Select a setup in the Keypad editor to show the right-side keypad inspector, where you can choose the device canvas, set **iPhone Rotation** to Follow Device, Lock Portrait, or Lock Landscape, attach a Mac application with the native file browser, set custom device dimensions, change the iPhone background fill, and toggle System/Light/Dark view modes while editing. Attached applications sync with the setup, including the selected app icon; when the iPhone is connected, the top bar shows that app icon as a button that asks the Mac helper to launch or refocus the pre-approved app. Use **Saved Mode** to choose whether that setup follows the device, always uses light mode, or always uses dark mode; per-button light and dark fills and keypad background fills are saved separately with the setup. The same settings are scriptable with `thumble orientation get|set`, `thumble customization set --appearance light|dark|system --device iphone-17-pro --background '#101014'`, `thumble customization set --background-gradient '#101014,#4338CA'`, `thumble element set BUTTON --light-fill '#RRGGBB' --dark-fill '#RRGGBB'`, and `thumble profile attach-app PROFILE --path /Applications/App.app`.

Layouts can include up to two virtual joysticks via **Add Control → Add Joystick**. New joysticks default to **Digital directions**, so the first joystick's up/down/left/right directions use the normal arrow-key shortcut slots in keyboard mode. Each joystick maps its directions to normal Thumble shortcut slots, so you can also build shooter-style dual-stick layouts while still using the existing keyboard-binding recorder. In the joystick inspector, **Look → Thumbstick** turns the control into a compact center nub: touches must start on the small ball, then can drag through the larger invisible range without stealing taps from neighboring face buttons. The CLI equivalent is `thumble element add joystick --thumbstick --target right-stick --no-digital-directions`. Select a joystick and edit **Fill → Thumbstick** to recolor the moving thumb separately from the joystick base; the CLI equivalent is `thumble element set "Right Stick" --thumb-fill '#22C55E'` (or light/dark variants such as `--light-thumb-fill`).

The Keypad editor has a persistent command bar for Edit/Test mode, named control creation, undo/redo, orientation workflows, layout health, live save/delivery status, and explicit zoom controls; setup switching moves into the command bar whenever the Setups list is hidden. The left sidebar provides searchable **Setups** and **Layers** views with rename, duplicate, lock, visibility, grouping, and stack actions, and automatically follows the active setup. Use **Focus Canvas** (`⌥⌘0`) to temporarily hide both sidebars. The task-first inspector gives a button one **Action** field: the key press it sends. Visible letters and captions are separate passive **Text** layers from **Add Control → Text**; adding one from a selected button overlays it, hides the legacy integrated label, and groups both layers so they transform together. Switch to **Advanced** for reusable styles, haptics, corners, and effects. Pressing a control in Test mode sends its real configured output, while presses received from the paired iPhone are mirrored on the Mac canvas.

The layout-health menu surfaces the same overlap, touch-target, edge, displacement, and canvas-usage checks available through `thumble layout validate`. Selecting an issue zooms to the affected controls and opens an on-canvas repair banner for minimum touch targets, safe-area placement, overlap separation, or automatic arrangement; the same repairs are available through `thumble layout fix`. Portrait and landscape variants can be copied, automatically arranged, or compared side by side. Keyboard editing includes marquee selection, `⌘A`, `⌘D`, grouping, nudging, explicit Fit and Zoom to Selection controls, zoom shortcuts, and a `⌘/` reference sheet. Equivalent saved-layout operations are available from the CLI, including `thumble element duplicate`, `thumble element align`, `thumble element distribute`, `thumble group rename`, `thumble group duplicate`, and `thumble orientation copy|arrange`.

The design layer also supports grid/snap preferences, reusable style tokens, per-control icons/haptics, copy/paste style, alignment/distribution, and style-aware preview rendering. Open **Keypad Resources** from the advanced appearance inspector to create, rename, update, import, export, and delete named styles or manage embedded assets. Per-control z-index values run from -100 to 100. Per-control haptics include style, pattern/rhythm, intensity, sharpness, and duration; iPhone haptics are device-wide, so these distinguish controls by feel rather than screen location. The same data is scriptable with `thumble style`, `thumble layer`, `thumble group`, `thumble asset`, and richer `thumble element set` options such as `--z-index`, `--style`, `--icon`, `--haptic`, `--haptic-pattern`, `--haptic-intensity`, `--stroke`, `--glow`, and `--pressed-fill`.

On iPhone, the scrollable **Keypad settings** sheet includes a device-wide haptic intensity and test, optional secondary binding glyphs, immersive mode, the profile rotation preference, and thumb-placement calibration, including at accessibility Dynamic Type sizes. Calibration records left/right reach traces for the current profile, display, and orientation, scores reach and touch-target quality, and offers explicit, undoable layout suggestions. **Practice Mode** keeps controls, pressed visuals, and haptics active while centrally suppressing every keyboard, controller, trigger, and pointer output path. Saved keypads remain clearly offline until Practice Mode or reconnection is chosen. Home opens connection details and iPhone settings without dropping a live Mac session; the connection page then offers explicit Return to Keypad and Disconnect actions. A connected keypad starts without the full connection bar: a compact pull-down handle remains briefly, fades away, and can always be recovered with a downward swipe from the top activation area. On-device layout edits support Undo/Cancel and accessible move, resize, rotate, and delete actions; offline final edits are retained against the trusted Mac identity and uploaded after reconnect instead of being overwritten by the first server snapshot.

Layouts can also include a trackpad component via **Add Control → Add Trackpad** or `thumble element add trackpad`. The trackpad sends relative cursor movement to the Mac, supports tap-to-click, two-finger right click, two-finger scroll, natural-scroll inversion, and per-component cursor/scroll sensitivity. Pointer events use the paired realtime channel and the macOS helper injects them with Accessibility-approved `CGEvent` mouse and scroll events.

### iPhone device frames

The Keypad editor can preview layouts inside every iPhone display class Thumble supports on iOS 17+, from iPhone XS/XR and SE 2/3 through the iPhone 17 family. The editor uses a vector device frame plus the real logical screen size for each model, so keypad placement matches the phone display instead of relying on a single bundled PNG.

When an iPhone connects, it sends its device metrics to the Mac helper. If you have not manually chosen a frame, the editor auto-selects the connected phone's matching canvas. Each setup can now save separate portrait and landscape designs; changing the canvas orientation in the editor edits that orientation's variant, and the iPhone swaps variants automatically as it rotates. You can switch frames manually from the keypad inspector, the canvas device menu, or the CLI:

```bash
thumble device list
thumble device show
thumble device set iphone-17-pro --orientation landscape
thumble device set iphone-17-pro --orientation portrait --variant portrait
# Custom dimensions remain available in the app; CLI selection is limited to the checked-in catalog.
thumble customization set --light-background '#FFFFFF' --dark-background '#050505'
thumble customization set --background-tile dots --tile-foreground '#FFFFFF' --tile-background '#111111'
thumble element nudge jump right --step 10 --canvas iphone-17-pro-landscape
```

## Shortcut bindings

The Mac helper shows a shortcut field in the Keypad editor's **Action & Label** inspector. Click the field for the selected button/shape, press one or more Mac keystrokes, then pause; the shortcut saves automatically. Thumble records held modifiers, so pressing `Control+B` saves `⌃B`; pressing `Control+B`, releasing it, then pressing `H` saves `⌃B H` for Herdr/tmux-style prefix bindings. Modifier-only shortcuts save when you press and release the modifier key. Friendly control labels remain independent from these bindings: Mac publishes compact and VoiceOver-friendly presentation metadata per profile/orientation, while iPhone can render the compact binding as a smaller optional subtitle. Inspect the same resolved metadata with `thumble binding display [--profile PROFILE] [--json]`, or remove only a friendly override with `thumble element set CONTROL --clear-label`.

Starter defaults are defined in `Sources/Mac/KeyMap.swift`:

- Navigation pad: arrow keys
- Action 1: Return
- Action 2: Tab
- Action 3: `⌘K`
- Action 4: `⌃B` (tmux prefix)
- Utility 1: `⇧⌘P`
- Utility 2: Esc

Use **Default** for a single button or **Reset All** to restore the starter keypad profile.

## Safety behavior

- Only sends key events on state transitions.
- Protocol v2 button frames use a fixed 32-byte binary payload with an input generation, full sequence number, and physical press identifier; legacy 14-byte v1 frames remain decodable. After pairing, iOS sends input over authenticated UDP and mirrors it over WebSocket for packet-loss recovery.
- The Mac advertises the `gamepad_profile_orientation_preference_mutation` capability before iOS enables rotation changes. A capable iPhone sends the dedicated profile-scoped mutation message only after that advertisement, and the Mac broadcasts the complete authoritative profile state afterward. Older peers ignore the optional capability/profile field; a new iPhone connected to an old Mac leaves the setting disabled and does not send the new message type.
- iOS and macOS WebSocket connections set TCP `noDelay` to avoid Nagle delays on small input packets.
- iOS uses a keypad-area UIKit touch router with stable expanded non-overlapping hit targets, hands moving touches between adjacent buttons and joysticks, sends every per-touch edge immediately before SwiftUI visual-state checks, stamps compact button frames with sequence diagnostics and per-press identifiers, supports optional per-control Core Haptics/impact feedback, and skips per-input send callbacks and live status publishes during use.
- macOS handles received input on a user-interactive realtime queue, accepts the first authenticated UDP stream for the paired iPhone, drops stale mirrored frames, recovers transport-proven missing edges, and safely applies a late up only when its physical press identifier still matches the active hold.
- macOS throttles input debug/status publishing so UI work does not compete with key injection.
- During physical tap testing, the Mac debug panel shows missing transport frames, recovered duplicate-down edges, and ignored duplicate/orphan input edges separately.
- iOS schedules heartbeat and active-press refreshes every 250 ms on its network queue; the Mac validates each refreshed physical press independently.
- Smart Connect stores a trusted reconnect token after successful pairing, advertises the Mac as `_pocketpad._tcp` on the local network with peer-to-peer discovery enabled, and avoids reusing stale six-digit pairing codes.
- The Mac keeps one authoritative iPhone session: a reconnect from the same trusted installation may replace its stale socket, while a different iPhone is rejected without evicting the active keypad or starting a reconnect loop.
- macOS releases all held keys after 1500 ms without any client activity, keeps the socket open so brief stalls can recover, and expires an individually unrefreshed physical hold after 1750 ms.
- macOS keeps a latency-critical activity while the helper is running to avoid App Nap when the target app is focused.
- macOS releases all held keys on client disconnect, server stop, or manual Release All.
- iOS sends best-effort `release_all` when disconnecting, becoming inactive, or backgrounding.
