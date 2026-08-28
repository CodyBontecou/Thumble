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
- `configuration-operation-v1.schema.json` is the allowlisted operation
  contract for revision-safe native and Swift-bridge draft transforms. It currently covers deterministic built-in generation and template installation, profile rename/select/default/duplicate/delete/move/create/reset, safe scalar customization, deterministic `customization.fix`, catalog-only persisted device selection, orientation preference/copy, typed control-bar collections/resets and rendering-effective non-file item appearance patches, complete non-file reusable-style create/rename/apply/detach/delete, revision-safe layer ordering and deterministic layer-group create/rename/duplicate/ungroup/visibility/locking/catalog-canvas nudging/reordering, theme application, deterministic six-kind non-file element creation, complete safe non-file element edits, semantic element/part outputs, semantic bindings, and output modes/resets. `customization.fix` accepts `{kind:"all"}` or one of seven canonical repairs, targets primary/portrait/landscape, respects locks unless `includeLocked` is true, and uses exactly one stored, checked-in frame, or 240...1800 bounded width/height canvas. Canvas overrides affect repair geometry only and never persist a custom frame ID. All/suggested mode uses priority-sorted issues, the first suggestion, at most one auto-arrange per pass, and at most three passes. Issue-code targeting remains intentionally CLI-only. Element add/set cover mapped buttons, labels/roles, geometry, visibility/locking, hit regions/corners, solid/gradient/tile fills, joystick thumb colors, bounded inline appearance, existing style references, text/SF-symbol icons, haptics, joystick/trigger/trackpad behavior, and safe output parts. Style creation includes the CLI's three material presets, solid colors, strokes, glow, inner shadow, highlight, bevel, opacity, up to eight shadows, pressed fill/scale, SF-symbol or text icons, and bounded haptics. It intentionally excludes
  arbitrary JSON patches, raw style/profile payloads, persisted custom dimensions, asset/image/file payloads or icons, artwork IDs, shell/process arguments, filesystem paths, numeric
  key codes, modifier masks, and authentication data. `control-bar.item.set` starts from the selected variant's effective item appearance, requires membership and nonempty changes, and permits only retained width/height, visibility, shape/corners/shadow/accent, typed solid/gradient/tile fills and opacities, canonical existing style references, bounded inline material/appearance, text/SF-symbol icons, and haptics; spacer accepts only width and visibility. Hit insets, integrated labels, coordinates, rotation, z-index, locking, joystick fields, images/assets, launch targets, and raw payloads are absent because they are inert or unsafe for control-bar rendering. `preview_configuration_draft` exposes color-scheme/accent/label preferences, sanitized normal-state canvas fills, bounded ordered `controlBarItems` with canonical item/target IDs, order, visibility, and sanitized effective appearance; a bounded ordered `layers` list; bounded `groups`; up to 64 sanitized style definitions; and bounded message-free `layoutQuality` issues containing only canonical code/severity, safe target IDs, finite metrics, counts, and canonical repair suggestions. The embedded read-only and draft MCP Apps render the safe canvas and element appearance fields with native fill precedence, contrast, stroke, corner, shadow, joystick, label, polygon, and star semantics rather than a fixed web palette. Control-bar records remain bounded inspection/edit targets; transient iPhone app chrome is not simulated in the controller canvas. Unsupported asset/image/path-bearing content is omitted and flagged without exposing profile JSON; layout issues are pruned before editor targets to preserve the 48 KiB snapshot cap.
- `controller-templates-v1.json` is the bounded read-only template catalog used by `query_catalog`; Swift tests keep its IDs, descriptions, revisions, and deterministic UUID counts golden against `GamepadControllerTemplate.allCases`.
- `device-frames-v1.json` is the bounded read-only catalog of the 68 exact built-in portrait/landscape frame IDs accepted by `device.set`. Custom dimensions and model aliases are deliberately absent from the write contract.
- `scripts/verify-mcp-cli-parity.py` checks ledger integrity and compares it with
  the canonical root/subcommand dispatch surface in `ThumbleCLI.swift`.

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

## Remote connector deployments

`docs/mcp/remote-deployment-plan.md` documents the hosted relay for remote
MCP connectors (ChatGPT): an OAuth 2.1-authenticated `thumble-gateway`
routing Streamable HTTP sessions to the user's own `thumble-mcp --relay`
over an outbound WebSocket tunnel. The gateway is a router, never an
authority: this directory's transaction rules, the Rust host's ownership of
configuration state, and every sanitization contract above continue to apply
unchanged to remote sessions, which exercise the exact same MCP tool surface
through the same local adapter. Per-tool remote scopes (`thumble.read`,
`thumble.draft`, `thumble.config`) are an additional outer gate enforced
before forwarding; the local `--allow-input` / `--allow-config-write`
fail-closed flags remain the inner gate, and `pairing_code`, `press_control`,
and `release_all` are never remotely reachable. Onboarding is one managed
command (`thumble relay connect`): clicking **Connect** in ChatGPT pushes a
native approval prompt to the Mac, and clicking **Allow** completes OAuth
without entering a code. Native push is enabled only for verified ChatGPT
callback hosts, then limited to relay connections from the same
gateway-observed network source as the authorization page and one active
prompt per exact connection; the dialog defaults to Deny. OAuth completion
waits for the relay's durable-token acknowledgment, and rotation closes the
previous authenticated control socket. The one-time six-digit code remains a clipboard
fallback for headless/SSH use. Re-authorization through an already-running
relay uses the same approval path without rotating its device token;
`thumble relay rotate` remains the explicit credential-rotation command,
`thumble relay doctor` reports merged local + gateway readiness with fixes,
and `thumble relay install` keeps the relay alive as a background launch
agent. The click-to-connect gateway and release relay were rolled out on
2026-08-27. Connect → Mac Allow → automatic OAuth return completed in
production; v16 isolates independent OAuth token families, and the release
relay independently detects silent half-open control sockets. If ChatGPT shows
the app as connected but exposes no tools after a server/action change, use
**Refresh actions** on the Thumble developer-mode app before reconnecting—the
OAuth link can be active while OpenAI's cached action catalog is still empty.
The hosted plugin now exposes all 17 remote actions and has completed a real
`host_status` call; a fresh visible ChatGPT conversation remains the final
human UI receipt. The production Streamable HTTP endpoint is
`https://thumble-mcp-gateway.fly.dev/mcp`; refresh tokens are issued only with
`offline_access`. Production acceptance with the OpenAI-hosted Codex runtime
bundled in ChatGPT.app is recorded in
`docs/mcp/openai-client-acceptance.md`.
