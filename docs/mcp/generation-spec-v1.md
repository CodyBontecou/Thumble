# Generation spec v1

Generation spec v1 is the typed, deterministic JSON contract behind
`thumble generate --spec`, `install-spec`, and the planned hosted-builder
`generate_from_spec` tool. The canonical implementation is
`Host/crates/thumble-core/src/generation_spec.rs`.

## Input and revisions

Top-level fields:

- optional `schemaVersion`, `catalogRevision`, and `plannerRevision` (all must
  equal `1`; absence means `1`);
- `gameName` (`name` / `game` aliases), optional `source`, `confidence`, and
  `notes`;
- required `controls` array.

Control fields preserve the documented agent-spec aliases for semantic button,
label/key/modifiers/role, geometry, shape/accent/colors, style tokens and rich
visual states, icons/haptics, control kind, joystick mapping/style, trigger,
and trackpad settings. Unknown fields fail closed. Asset/image/tile fills,
asset icons, paths, URLs, commands, embedded data, credentials, authority
identity, non-finite/out-of-range numbers, and control characters are forbidden.

Bounds:

- raw spec: 256 KiB;
- source controls: 128;
- assigned game-button slots: 18;
- generated artifact/output: 8 MiB each;
- labels: normalized to 12 extended grapheme clusters;
- profile names: 256 characters;
- generation warnings: 128 retained plus `omittedWarningCount`.

## Deterministic planning

`plan_generation_spec` canonicalizes the normalized spec, requested-name
override, and the three revisions with RFC 8785, then records a SHA-256
descriptor digest. A fixed generation namespace plus that digest derives UUIDv5
profile/custom-element IDs. Built-in elements keep canonical IDs. All generated
timestamps and artifact `exportedAt` are zero.

The same normalized input therefore produces byte-identical:

- `generatedJSON` (`GeneratedGameKeypadProfile` compatible);
- portable profile artifact v1 JSON and content hash;
- assigned/dropped controls, warnings, and layout quality.

Rust enforces Swift-normalized capacities (two joysticks, two triggers, one
trackpad), slot assignment, role/kind inference, thumb-layout defaults,
12-grapheme labels, joystick circle normalization, trigger defaults, and
trackpad normalization. Slot/capacity loss and reused layout defaults are
reported explicitly rather than silently discarded.

Rich appearance supports safe solid/linear/radial fills, normal and interaction
states, colors/strokes/shadows/glow/inner-shadow/highlight/bevel/opacity/scale,
three soft-white material presets, SF-symbol/text icons, and bounded haptics.
Image/tile/asset-backed content remains outside hosted generation v1.

## Output and installation

Schema-8 `generation.plan-spec` is read-only and returns a bounded generation
projection tagged with the exact configuration revision. It creates no draft,
commit, state, or replay record.

The Swift CLI:

1. reads raw spec bytes with bounded descriptor/stdin I/O;
2. requests the Rust plan;
3. decodes `generatedJSON` only for native layout reporting and PNG preview;
4. writes exact Rust bytes in `--json` mode;
5. for installation, submits `artifactJSON` through the existing
   `profile.import` draft/CAS transaction with the same invocation ID and plan
   revision.

This makes retry identity, replacement-by-name/UUID, selection/default changes,
and atomic persistence identical to ordinary profile artifact import. Repeating
one invocation replays against its original base revision; changing spec or
options under that invocation conflicts.

`generation.install-spec` is marked `host-cli-only` in the CLI-to-MCP ledger.
The separate hosted-builder capability is `partial`: the cloud builder endpoint
executes it locally, but production deployment and visible ChatGPT acceptance
remain pending.

## Fixtures and verification

Fixtures under `Host/fixtures/generation-spec/v1/` cover basic aliases,
joystick/trigger/trackpad/text/decoration, capacities and warnings, rich
appearance/materials, safety/revision/bounds failures, semantic hashes, and
exact Rust `generatedJSON` decoded by Swift tests.

Run:

```bash
python3 scripts/verify-cli-profile-persistence-allowlist.py
./scripts/verify-rust-host.sh
./scripts/verify-generation-spec-flow.sh /path/to/directory-containing-thumble-thumble-cli-bridge-and-thumble-bridge
./scripts/verify-profile-artifact-flow.sh /path/to/directory-containing-thumble-and-thumble-cli-bridge
./scripts/verify-stack-safety.sh
```
