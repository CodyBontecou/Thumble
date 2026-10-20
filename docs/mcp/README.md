# Thumble MCP parity contracts

This directory is the checked-in contract for making the complete standalone
`thumble` CLI capability set available to Codex, Claude, and compatible MCP
clients without introducing a second configuration source of truth.

## Authority

The standalone Rust host owns configuration state, monotonically increasing
configuration revisions, drafts, atomic commits, input release, and delivery to
the paired iPhone. The Swift model remains the canonical implementation of rich
profile, layout, template, theme, skin, and rendering transformations through a
dedicated typed `thumble-bridge` helper. The bridge transforms an in-memory
configuration document; it never chooses a state file, invokes arbitrary
commands, receives credentials, or persists host state.

The existing Swift defaults backend remains a compatibility backend while the
CLI and macOS editor are converted to host transactions. It must not be
silently synchronized in both directions with host state.

## Files

- `cli-capabilities-v1.json` maps every current canonical CLI operation to its
  executor, permission gate, phone effect, intended MCP tool, and implementation
  status. `planned`, `foundation`, and `partial` entries are not claims that the
  capability is currently available.
- `profile-artifact-v1.md` specifies the bounded hashed profile interchange
  format, portability boundary, current-only rejection rules, Rust authority import
  semantics, framing limits, and real-binary verification flow.
- `generation-spec-v1.md` specifies deterministic typed agent-spec planning,
  safe appearance/semantic-key bounds, generated/profile artifact outputs,
  plan-to-import authority routing, fixtures, and real-binary verification.
- `configuration-operation-v1.schema.json` is the allowlisted operation
  contract for revision-safe native and Swift-bridge draft transforms. It currently covers deterministic built-in generation and template installation, profile rename/select/default/duplicate/delete/move/create/reset, safe scalar customization, deterministic `customization.fix`, catalog-only persisted device selection, orientation preference/copy, typed control-bar collections/resets and rendering-effective non-file item appearance patches, complete non-file reusable-style create/rename/apply/detach/delete, revision-safe layer ordering and deterministic layer-group create/rename/duplicate/ungroup/visibility/locking/catalog-canvas nudging/reordering, theme application, deterministic six-kind non-file element creation, complete safe non-file element edits, semantic element/part outputs, semantic bindings, and output modes/resets. `customization.fix` accepts `{kind:"all"}` or one of seven canonical repairs, targets primary/portrait/landscape, respects locks unless `includeLocked` is true, and uses exactly one stored, checked-in frame, or 240...1800 bounded width/height canvas. Canvas overrides affect repair geometry only and never persist a custom frame ID. All/suggested mode uses priority-sorted issues, the first suggestion, at most one auto-arrange per pass, and at most three passes. Issue-code targeting remains intentionally CLI-only. Element add/set cover independent UUID controls, explicit outputs (including joystick directions authored as `{keyboard:{key:"W",modifiers:[]},gamepadButtons:["dpadUp"]}` or `{}` for an unbound direction; never `mappedButton` or numeric key codes), labels/roles, geometry, visibility/locking, hit regions/corners, solid/gradient/tile fills, joystick thumb colors, bounded inline appearance, existing style references, text/SF-symbol icons, haptics, joystick/trigger/trackpad behavior, and safe output parts. Style creation includes the CLI's three material presets, solid colors, strokes, glow, inner shadow, highlight, bevel, opacity, up to eight shadows, pressed fill/scale, SF-symbol or text icons, and bounded haptics. It intentionally excludes
  arbitrary JSON patches, raw style/profile payloads, persisted custom dimensions, asset/image/file payloads or icons, artwork IDs, shell/process arguments, filesystem paths, numeric
  key codes, modifier masks, and authentication data. `control-bar.item.set` starts from the selected variant's effective item appearance, requires membership and nonempty changes, and permits only retained width/height, visibility, shape/corners/shadow/accent, typed solid/gradient/tile fills and opacities, canonical existing style references, bounded inline material/appearance, text/SF-symbol icons, and haptics; spacer accepts only width and visibility. Hit insets, integrated labels, coordinates, rotation, z-index, locking, joystick fields, images/assets, launch targets, and raw payloads are absent because they are inert or unsafe for control-bar rendering. `preview_configuration_draft` exposes color-scheme/accent/label preferences, sanitized normal-state canvas fills, bounded ordered `controlBarItems` with canonical item/target IDs, order, visibility, and sanitized effective appearance; a bounded ordered `layers` list; bounded `groups`; up to 64 sanitized style definitions; and bounded message-free `layoutQuality` issues containing only canonical code/severity, safe target IDs, finite metrics, counts, and canonical repair suggestions. The embedded read-only and draft MCP Apps render the safe canvas and element appearance fields with native fill precedence, contrast, stroke, corner, shadow, joystick, label, polygon, and star semantics rather than a fixed web palette. Control-bar records remain bounded inspection/edit targets; transient iPhone app chrome is not simulated in the controller canvas. Unsupported asset/image/path-bearing content is omitted and flagged without exposing profile JSON; layout issues are pruned before editor targets to preserve the 48 KiB snapshot cap.
- `controller-templates-v1.json` is the bounded read-only template catalog used by `query_catalog`; Swift tests keep its IDs, descriptions, revisions, and deterministic UUID counts golden against `GamepadControllerTemplate.allCases`.
- `device-frames-v1.json` is the bounded read-only catalog of the 68 exact built-in portrait/landscape frame IDs accepted by `device.set`. Custom dimensions and model aliases are deliberately absent from the write contract.
- `scripts/verify-mcp-cli-parity.py` checks CLI-ledger integrity and compares it
  with the canonical root/subcommand dispatch surface in `ThumbleCLI.swift`.

## Non-negotiable transaction rules

1. Begin records an exact authoritative configuration revision.
2. Every edit compares an expected draft revision and carries an idempotency ID.
3. Save compares both the expected draft and authoritative revisions and carries
   a durable commit ID.
4. Conflicts never use last-writer-wins and never auto-rebase during save.
5. A candidate is semantically validated before persistence.
6. Persistence succeeds before the already-validated candidate becomes live.
7. Executable mapping changes release held input before activation.
8. A successful commit sends the complete authoritative state to the paired
   phone; a delivery failure is retried on reconnect rather than rolling back a
   durable commit.
9. Raw evolving profile fields remain owned by Rust and survive Swift canonical
   transformations through a lossless three-way merge.
10. Configuration writes, input, host lifecycle, artifacts, system actions, and
    app actions use independent explicit opt-ins.

## Constrained Swift bridge v1

`Sources/Bridge/ThumbleBridgeMain.swift` accepts exactly one newline-terminated,
8 MiB-bounded JSON request on stdin and emits exactly one JSON response. It
accepts no argv, path, command, credential, persistence, or process fields.
`Sources/Shared/ThumbleConfigurationBridge.swift` performs only typed in-memory
operations and applies canonical Swift model deltas back onto the raw document,
preserving fields unknown to the current Swift model. The Rust host discovers
only a same-directory `thumble-bridge` regular executable owned by the current
user and not writable by group or others, clears its environment, bounds both
output streams, enforces a five-second timeout, validates the returned document,
and remains the sole owner of draft revisions and commits.

Run the ledger gate with:

```bash
python3 scripts/verify-mcp-cli-parity.py
```

## Local MCP transport

The MCP adapter uses local stdio and the user's private host control socket. Hosted OAuth endpoints, cloud builder sessions, and remote relays are retired. Local controller authoring, preview, generation, profile interchange, and revision-safe host transactions remain supported.

Controller authoring also exposes `inspect_controller_design` and
`critique_controller_design`: inspect exact CSS aliases and semantic tags, then preserve
structured issues against the current native render hashes. See
[controller design workspaces](controller-design-v1.md) for the shared CLI contract.
