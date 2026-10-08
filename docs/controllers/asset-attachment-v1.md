# Game controller asset attachment v1

Attach local PNG artwork to a manifest-generated, installed Thumble controller.
The original [manifest](README.md) still defines actions, bindings, geometry,
and opaque artwork IDs. This separate operation resolves those IDs into native
asset-library records and element appearances, then saves through the existing
host authority. It creates no game graphics and sends no keyboard, pointer, or
gamepad input.

The pure Rust attachment API, `thumble asset attach-controller` CLI command,
and local `attach_game_controller_assets` MCP tool share this contract.
The MCP schema resource is
`thumble://schemas/game-controller-asset-attachment-v1`.

## Attachment contract

The [JSON Schema](asset-attachment-v1.schema.json) describes exactly three
required fields:

| Field | Meaning |
| --- | --- |
| `manifestJSON` | Original game-controller manifest v1 encoded as a JSON string |
| `profileID` | UUID of the authoritative installed destination profile |
| `images` | Array of `{assetID, pngBase64}` records |

Unknown fields fail validation. Supply exactly one image for every declared
manifest asset, with no duplicate or extra IDs. Image records contain canonical
standard Base64 PNG bytes, including required padding; paths, URLs, data-URL
prefixes, credentials, and caller-selected native asset IDs are absent.
This is a bounded image attachment operation, not a general profile JSON edit.

Replanning the supplied manifest derives the original control mappings. The
destination must retain the planned element IDs/kinds, output mode, direct
outputs, and keyboard/gamepad bindings. Profile renaming and geometry edits are
allowed and preserved. The operation validates the target and every image
before applying any appearance changes. Always use the installed destination
UUID from import/list output.
`--append` can change the planner's source profile UUID while retaining its
element mappings.

## Native appearances

| Manifest association | Native attachment |
| --- | --- |
| `visual.iconAssetID` | Normal-state image icon |
| `visual.backgroundAssetID` | Normal-state image fill |
| `visual.stateAssetIDs.pressed` | Pressed-state image fill |
| `visual.stateAssetIDs.active` | Active-state image fill |
| `visual.stateAssetIDs.disabled` | Disabled-state image fill |

Attachment updates every existing customization variant for the target profile.
The operation preserves layouts, executable bindings, and the active/default
profile selections. Omitted visual references preserve existing appearance
fields. Its state associations populate native interaction-state
appearances; there is no subscription to game cooldowns, health, champion
selection, or other live game data.

The response reports native asset mappings and hashes without returning image
bytes or the complete authoritative configuration. Its `descriptorDigest`
identifies the normalized manifest, including artwork associations. It does not
hash the supplied image content; use each asset mapping's `sha256` for that.
Native asset IDs are deterministic for the manifest ID and asset ID. Attaching
new image bytes under the same IDs updates the corresponding validated native
record; conflicting unrelated native records fail validation.

## Pure Rust API

```rust
use thumble_core::{
    attach_game_controller_assets, GameControllerAssetAttachment,
};

let attachment: GameControllerAssetAttachment =
    serde_json::from_slice(attachment_json)?;
let plan = attach_game_controller_assets(&document, &attachment)?;
// plan.document contains the updated in-memory configuration.
// plan.summary contains safe attachment metadata.
```

This API neither persists configuration nor sends input. A caller that installs
the result must use the host transaction below, which validates the installed
target at an exact authoritative revision.

The summary contains `profileID`, `manifestID`, `descriptorDigest`,
`assetMappings`, `attachedControlCount`, and `updatedVariantCount`.
Each mapping contains `assetID`, `nativeAssetID`, `sha256`, and `byteCount`.
`attachedControlCount` counts distinct manifest controls with artwork, and
`updatedVariantCount` counts the primary customization plus any existing
portrait/landscape variants. It does not multiply the control count by variants.

## CLI workflow

First [plan and import the manifest](README.md#import-through-the-existing-authority).
Keep the original manifest and record the installed profile UUID. Read the
current configuration revision with `thumble profile list --json` immediately
before attaching artwork.

Create a JSON dictionary mapping every manifest asset ID to a PNG file. For the
League starter manifest, a complete `league-artwork.json` map looks like:

```json
{
  "pointer-surface": "images/pointer-surface.png",
  "cast-q-icon": "images/q.png",
  "cast-w-icon": "images/w.png",
  "cast-e-icon": "images/e.png",
  "cast-r-icon": "images/r.png",
  "summoner-d-icon": "images/d.png",
  "summoner-f-icon": "images/f.png",
  "trinket-icon": "images/trinket.png",
  "item-one-icon": "images/item-one.png",
  "cast-q-pressed": "images/q-pressed.png"
}
```

Relative PNG paths resolve against the asset-map file's directory. The CLI
loads and encodes those files locally; filesystem paths never reach the
authority. Supply your own images; the starter manifests include no game
artwork.

Use the actual installed UUID and the revision returned by your read in both
commands. These example values are placeholders:

```bash
thumble asset attach-controller docs/controllers/examples/league-of-legends.json \
  --profile 11111111-2222-4333-8444-555555555555 \
  --asset-map league-artwork.json --expected-revision 12 --dry-run --json

thumble asset attach-controller docs/controllers/examples/league-of-legends.json \
  --profile 11111111-2222-4333-8444-555555555555 \
  --asset-map league-artwork.json --expected-revision 12 \
  --invocation-id 66666666-7777-4888-8999-aaaaaaaaaaaa --json
```

`--dry-run` validates the installed target and all artwork and reports whether
the candidate would change configuration. It performs no persistence or
phone synchronization. The CLI can generate an invocation UUID when omitted;
supply a stable `--invocation-id` for a write you may need to retry.

## Local MCP workflow

The local-only tool accepts attachment fields directly, plus required
`expectedConfigurationRevision` and `invocationID`. `dryRun` is optional and
defaults to `false`. Load/encode local images in your client before calling:

```javascript
const args = {
  manifestJSON: JSON.stringify(manifest),
  profileID: installedProfileID,
  images: encodedImages, // [{assetID, pngBase64}], one per manifest asset
  expectedConfigurationRevision: currentRevision,
  invocationID: crypto.randomUUID(),
};

const preview = await client.callTool({
  name: "attach_game_controller_assets",
  arguments: {...args, dryRun: true},
});

const saved = await client.callTool({
  name: "attach_game_controller_assets",
  arguments: args,
});
```

Writes require independent configuration-write opt-in on both `thumble-mcp`
and `thumble-host`, using their existing `--allow-config-write` gate. Dry runs
can validate without write opt-in. The tool is annotated as a write capability
even when called in dry-run mode. It is excluded from relay/remote sessions and
hosted-builder tools. Input opt-in is unnecessary because the operation sends
no input.

## Authority transaction and retries

The CLI and MCP adapter send the typed schema-8 command
`controller.assets.attach` with `{attachment, dryRun}`. The existing request
wrapper carries `expectedConfigurationRevision` and the invocation UUID.
The response's `controllerAssetAttachment` contains the flattened core summary
plus `configurationRevision`, `dryRun`, and `changed`.

Both dry runs and new writes require the exact current authoritative revision.
A stale revision fails without applying the candidate. A successful write
uses the existing revision check and atomic configuration save, then sends
complete authoritative state through normal paired-phone synchronization.
It does not select the target profile.

For a write retry, reuse the original invocation UUID, expected base revision,
normalized manifest, destination, and image content. A retained exact commit
replays its original result even after later configuration edits. Reusing the
UUID with a different destination, manifest, image content, or expected base
revision fails with `commit_id_conflict`.
Write replay sets `outcome.idempotentReplay: true` and returns the original
commit revision and `changed` flag; `updatedVariantCount` is `0` because no
destination variants are transformed again during replay.
Dry runs do not create commit records and always inspect the current revision.
If a stale revision requires a fresh operation, reread configuration and use a
new invocation UUID.

## Validation and portability

| Limit | Bound |
| --- | --- |
| Manifest JSON | 256 KiB UTF-8 |
| Images | 1–90, exact manifest asset coverage |
| Each decoded PNG file | 2,500,000 bytes |
| Combined decoded PNG files | 4 MiB |
| Each image dimension | 1–2048 pixels on both axes |
| Combined decoded image pixels | 16,777,216 |
| Local MCP attachment request frame | 8 MiB UTF-8; ordinary requests retain 256 KiB |
| Complete candidate configuration document | Existing 8 MiB cap, including embedded images |

PNG validation includes CRC checks and full pixel decoding. Truncated,
malformed, oversized, and animated PNGs fail before mutation. Other image
formats are outside v1. JSON Schema checks shapes and scalar bounds; Rust
enforces byte/pixel budgets, image validity, cross-field integrity, and native
target compatibility.

Attached PNG bytes live in native configuration asset libraries and synchronize
through the existing full-state path. They do not become portable profile
artifacts: [ProfileArtifact v1](../mcp/profile-artifact-v1.md) continues to reject
embedded binary data recursively. Replan the original manifest to obtain a
fresh asset-free portable artifact, then attach artwork after importing it at
the next destination. Keep artwork separately when sharing that workflow.

Skin packages retain the existing [skin workflow](../skins/README.md).
Portable asset packages, JPEG ingestion, game telemetry, and automatic artwork
lookup remain separate future contracts.
