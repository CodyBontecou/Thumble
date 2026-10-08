# Game controller manifest v1

Build a game-specific Thumble controller from a small, portable contract. The
planner compiles touch controls and their keyboard/gamepad bindings into an
importable profile artifact. Artwork associations travel alongside the artifact
as a separate, typed sidecar. After import, the
[native asset attachment API](asset-attachment-v1.md) resolves those IDs to
local PNGs and applies them to the installed controller.

**Implemented here:** a strict JSON Schema, the pure Rust
`thumble_core::plan_game_controller` API, and the local MCP
`plan_game_controller` tool, plus bounded PNG attachment through Rust, the CLI,
and local MCP. Planning creates no configuration draft, installs no profile,
and sends no input. The generated portable profile contains usable labels and
native controls; artwork is attached separately through a revision-safe host
transaction. Live game-state updates, portable asset packages, and
remote/hosted exposure remain follow-up work.

## Model

| Object | Purpose | Example |
| --- | --- | --- |
| `game` | Identifies the game independently of its presentation | `league-of-legends` |
| Action | Names a gameplay intent and its executable binding | `cast-q` → key `Q` |
| Control | Names a touch target, references an action, and chooses geometry | `cast-q-button` → `cast-q` |
| Visual | Associates a control with optional artwork IDs and state IDs | `iconAssetID: "cast-q-icon"` |
| Asset | Declares an opaque ID and descriptive fallback text | `cast-q-icon`, `alt: "Placeholder for Q artwork"` |

Action IDs, control IDs, and asset IDs have separate namespaces. Keep them stable
when changing labels or artwork. A control's `actionID` must resolve to exactly
one declared action, and each action must have exactly one control. Every
visual reference must resolve to a declared asset; every declared asset must be
used. IDs are lowercase slugs, never URLs or filesystem locations.

An asset declaration contains only `id` and `alt`. It carries no image bytes,
path, download URL, or native asset-library ID. `visual` allows `iconAssetID`,
`backgroundAssetID`, and `stateAssetIDs` for `pressed`, `active`, and `disabled`.
These associations are returned in `visualAttachments`; planning does not
create image appearances or live game-state subscriptions. The separate
attachment operation applies native icon/fill appearances for those IDs.
Control labels come from the action label and remain available without artwork;
`alt` supplies descriptive asset metadata.

## Input contract

See [the schema](game-controller-manifest-v1.schema.json) and the runnable
[League of Legends](examples/league-of-legends.json) and
[World of Warcraft](examples/world-of-warcraft.json) examples. The local MCP
server also exposes the schema as
`thumble://schemas/game-controller-manifest-v1`.
The examples provide starter mappings and illustrative geometry. Review
`layoutQuality` and preview the imported controller on the target iPhone before play.

Required top-level fields are `schemaVersion: 1`, `id`, `name`, `game`,
`outputMode`, `actions`, and `controls`. `assets` is optional. Unknown fields
fail validation at every level.
Optional scalar and object fields accept `null`, which normalizes to omission;
optional arrays still require arrays. An empty modifier list is equivalent to omission.

- Manifest JSON is bounded to 256 KiB.
- Actions and controls each contain 1–18 entries. IDs must be unique within
  each collection; a manifest has at most one trackpad.
- Assets contain at most 90 entries. IDs are 1–64 characters matching
  `^[a-z0-9]+(?:-[a-z0-9]+)*$`.
- Names, action labels, and asset `alt` text must be nonblank, free of control
  characters, and at most 256 Unicode characters. Native generated control
  labels are normalized to 12 extended grapheme clusters.
- Controls require `id`, `actionID`, `kind`, and `role`. Supported kinds are
  `button` and `trackpad`; roles are `primary`, `secondary`, `utility`,
  `system`, and `movement`.
- Optional `x` and `y` are normalized native **center coordinates**, from
  0 to 1. `widthScale` and `heightScale` are native size multipliers,
  from 0.001 to 12, applied to native per-kind/per-slot base sizes.
  They are not fractions of the canvas dimensions. Omitted geometry uses
  native generation defaults; inspect the returned `layoutQuality`.
- Empty `visual` and `stateAssetIDs` objects are rejected.

The JSON Schema checks shapes, enums, and capacities. The Rust planner also
checks referential integrity, duplicate IDs, one-to-one action/control
relationships, asset usage, and output compatibility. Always submit a
schema-valid document to the planner before using its result.

## Output modes and native pointer input

`output` supports one case-sensitive semantic `key`, an optional array of
unique `modifiers` (`ctrl`, `shift`, `option`, `command`), and/or one
`gamepadButton` from the schema's digital gamepad vocabulary. Nonempty modifiers
require a key. Numeric key codes, key sequences, mouse-button bindings, timed macros,
and analog joystick/trigger mappings are outside this contract.

| Manifest `outputMode` | Button action declaration | Generated native profile mode |
| --- | --- | --- |
| `keyboard` | Key required; gamepad button excluded | `keyboard` |
| `controller` | Gamepad button required; key/modifiers excluded | `custom` |
| `custom` | Key, gamepad button, or both required | `custom` |

The planner stores a gamepad-only `controller` manifest as native `custom`
mode and returns a `controller-output-uses-custom-mode` warning. Thumble's
native `controller` mode uses the canonical controller-slot map; native
`custom` mode preserves the exact `gamepadButton` declared for each action.
This distinction keeps a named action mapped to its requested output.
Controller-only or mixed bindings still require the receiver's virtual-gamepad
readiness and the game's compatibility; see
[virtual controller support](../virtual-controller-support.md).

A button's action must have nonnull `output`. A trackpad's action must omit
`output` or set it to `null`.
The trackpad uses native relative pointer handling with tap-to-click enabled:
a short, stationary one-finger tap sends left click, a two-finger tap sends
right click, and two-finger movement scrolls. This contract does not replace
those gestures with gamepad axes or programmable mouse-button actions.

For League of Legends, keyboard output plus a native trackpad matches the
game's keyboard and mouse controls. The example maps Q/W/E/R, D/F, recall,
camera centering, stop, attack move, scoreboard, trinket, and one item slot.
Match these bindings to your in-game settings, including quick-cast behavior.
All image references are placeholders.

The World of Warcraft example uses all 18 button slots: the twelve primary
action-bar keys, W/A/S/D, Tab, and Space. A/D use the game's default keyboard
turn bindings. It is a starter action bar; it includes no pointer pad, extra
bars, layers, or complete class-specific rotation. To add a trackpad in v1,
replace a button/action pair so the total remains at most 18.

## Plan through Rust or local MCP

The platform-neutral core API accepts manifest UTF-8 bytes:

```rust
use thumble_core::{plan_game_controller, GameControllerError, GameControllerPlan};

fn plan(bytes: &[u8]) -> Result<GameControllerPlan, GameControllerError> {
    plan_game_controller(bytes)
}
```

The local MCP tool accepts one JSON-string argument:

```javascript
const result = await client.callTool({
  name: "plan_game_controller",
  arguments: { manifestJSON: JSON.stringify(manifest) },
});
const plan = result.structuredContent;
```

It returns the complete plan, including `artifactJSON`, as structured content.
That validated artifact contains native numeric key codes generated from semantic
keys; callers cannot supply numeric key codes to the manifest.
It needs no configuration-write or input opt-in and never contacts the host
authority. Existing MCP configuration and permission gates are documented
in [the MCP contracts](../mcp/README.md).

The plan includes the normalized `manifest`, the asset-free `generationSpec`,
`schemaVersion`, `plannerRevision`, `descriptorDigest`,
`generationDescriptorDigest`, `effectiveOutputMode`, source `profileID`,
the hashed portable `artifactJSON`, `artifactContentHash`, `controlMappings`, `assets`,
`visualAttachments`, `warnings`, and `layoutQuality`. Each control mapping
records its stable source `controlID`/`actionID`, generated native `elementID`,
and assigned semantic `gameButton`. Each visual attachment includes the
source `controlID`/`actionID`, corresponding `elementID`, and its `visual` declaration.

`descriptorDigest` identifies the full normalized manifest, including artwork
metadata. `generationDescriptorDigest` identifies its executable generation
input; `artifactContentHash` is the artifact's native content-hash descriptor.
`generationSpec` is a diagnostic intermediate; import `artifactJSON`, which also
contains the planner's exact output-mode and direct-binding transforms.
Equal normalized executable input produces equal compiled profile bytes and
IDs. Changes confined to assets and visual associations preserve the profile
artifact and control mappings. Changes to names, bindings, geometry, control
identity, or other executable/profile fields may change the artifact or IDs.
Keep the original manifest and complete plan when preparing an
[image attachment operation](asset-attachment-v1.md).

## Import through the existing authority

From the repository root, plan without a receiver or configuration write:

```bash
cargo run --locked --manifest-path Host/Cargo.toml -p thumble-core \
  --example plan_game_controller -- \
  < docs/controllers/examples/league-of-legends.json > /tmp/league-plan.json

python3 -c 'import json, sys; sys.stdout.write(json.load(sys.stdin)["artifactJSON"] + "\n")' \
  < /tmp/league-plan.json > /tmp/league-profile.json
```

To install that artifact using a packaged/development `thumble` CLI with its
matching trusted helper siblings:

```bash
thumble profile import /tmp/league-profile.json --append --no-select
```

This is an explicit configuration write through the existing profile import
transaction, with revision checks and atomic persistence. `--append` creates
a copy and `--no-select` preserves the active profile. The planner supplies
no alternative configuration store, offline install path, or input owner.
See [profile artifact import semantics](../mcp/profile-artifact-v1.md).

Import may change the source `profileID`, especially with `--append`.
`visualAttachments` refers to source element UUIDs, not proof of installation.
The native attachment API accepts the installed destination UUID and original
manifest, verifies the retained control mappings and executable configuration,
then attaches local PNGs through the same authority's transactions. Geometry
edits are preserved. See the
[attachment guide](asset-attachment-v1.md#cli-workflow) for the asset map,
dry-run, revision check, and commit commands.

Profiles with attached PNG bytes live in native configuration and synchronize
to the phone through the existing full-state path. They cannot be exported as
portable ProfileArtifact v1 because that contract rejects embedded binary data.
Replan the original manifest to produce an asset-free portable artifact for a
new destination, then attach the images after import there.

## Extension boundary

New games only need new manifests. PNG ingestion and native image attachment
use the separate [attachment v1 contract](asset-attachment-v1.md), with opaque
asset IDs, validated native asset records, and an authoritative destination
profile. Native pressed/active/disabled appearances are populated from the
manifest's state associations. Live cooldown or game-state updates need a
separate runtime feed. Skin packages retain their existing
[native package workflow](../skins/README.md). The manifest provides the
interface between these capabilities without embedding a second renderer or
configuration authority.
