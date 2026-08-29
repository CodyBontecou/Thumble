# Thumble skins

Thumble skins are shareable, appearance-only packages. They use the established `.pocketpad` compatibility format and follow Delta’s convenient “one file you can AirDrop or open from Files” model while keeping Thumble controls native and accessible.

A skin **cannot** change keyboard shortcuts, controller mappings, launch targets, labels, control geometry, or accessibility behavior. Those stay in the user’s keypad profile.

## Package layout

A `.pocketpad` file is a validated ZIP archive:

```text
MySkin.pocketpad
├── manifest.json
├── skin.json
├── assets/                 # optional images and textures
│   └── button-texture.png
└── previews/               # optional discovery artwork
    ├── landscape-dark.png
    └── portrait-light.png
```

`manifest.json` owns identity, semantic version, creator/license metadata, canonical template compatibility, declared resources, byte counts, and SHA-256 hashes. `skin.json` contains appearance rules, passive artwork layers, and light/dark/orientation variants. Resources that are not declared in the manifest are rejected. Manifest schema version 2 adds compatibility declarations; version-1 packages still decode.

Schemas:

- [`pocketpad-manifest.schema.json`](pocketpad-manifest.schema.json)
- [`pocketpad-skin.schema.json`](pocketpad-skin.schema.json)
- [`pocketpad-skin-source.schema.json`](pocketpad-skin-source.schema.json)

A minimal package source is in [`starter/`](starter/). Published handcrafted examples cover distinct structures: [`Indigo Pocket`](examples/indigo-pocket/) for a showcase controller, [`Solar Sumi`](examples/solar-sumi/) for arcade stick, [`Tideglass Field`](examples/tideglass-field/) for compact handheld, [`Foldline Relay`](examples/foldline-relay/) for a one-handed productivity surface, and [`CSS First Light`](examples/css-first-light/) for the CSS authoring profile.

## Appearance cascade

At render time, Thumble resolves:

1. Thumble defaults
2. skin base appearance
3. matching orientation variant
4. matching light/dark variant
5. semantic role rule (`movement`, `primary_action`, `utility`, and so on)
6. built-in button rule
7. user appearance overrides recorded after the skin was applied
8. runtime pressed/active/disabled state

Geometry, bindings, labels, and independent touch insets never come from a skin. A profile stores its exact skin identifier/version and a baseline so a skin update can change inherited values without erasing user overrides.

## Handcrafted authoring workflow

Use editable `skin-source.json` plus SVG rather than hand-editing generated package JSON:

```bash
thumble skin artboard list
thumble skin artboard show showcase-controller-v1 --json
thumble skin scaffold "Indigo Pocket" \
  --identifier com.creator.indigo-pocket \
  --artboard showcase-controller-v1 \
  -o ./IndigoPocket

# Sanitizes/rasterizes SVG and emits a deterministic package.
thumble skin compile ./IndigoPocket \
  -o ./IndigoPocket/build/indigo-pocket-1.0.0.pocketpad \
  --clean --strict

thumble skin validate ./IndigoPocket/build/indigo-pocket-1.0.0.pocketpad --strict
thumble skin quality ./IndigoPocket --artboard showcase-controller-v1 --strict
thumble skin preview ./IndigoPocket \
  -o ./IndigoPocket/reviews/contact-sheet.png \
  --all-variants --all-states --native-renderer --contact-sheet
```

### CSS authoring

Schema-2 workspaces can style the entire controller with real CSS instead of materials:

```bash
thumble skin scaffold "My Skin" --identifier com.me.my-skin --css
thumble skin css capabilities
thumble skin css lint .
thumble skin css computed . --control builtin-jump --scheme dark --state pressed
thumble skin compile . --strict
```

CSS compiles into the same deterministic native style model; no stylesheet ships at runtime. See [css-authoring.md](css-authoring.md) and [`examples/css-first-light/`](examples/css-first-light/).

`skin preview` uses the same SwiftUI control faces, fills, effects, labels, artwork layers, and state resolver as the app. Without `--contact-sheet`, a single request writes one PNG and a multi-request render writes a frame directory.

Material tokens may opt into exact native state output while older schema-v1 sources retain their existing derived behavior. Optional fields include light/dark joystick puck colors; pressed, active, and disabled fills; active/disabled stroke widths; short non-enclosing active registration indices; disabled foreground and boundary colors; and compact shadow scales. Use these controls to make states materially distinct without drawing fake controls in SVG. Omitted fields preserve legacy deterministic package bytes; see the source schema for the complete contract.

The strict quality gate checks source depth, role coverage, contrast, canonical alignment, safe areas, variant/state completeness, actual image dimensions, compatibility, and package budgets. It complements—rather than replaces—independent visual critique.

The project `thumble-skin-author` skill defines the required art-director → designer → critic → QA sequence. Agents retain versioned contact sheets and may never grant human approval or publish autonomously.

For low-level package maintenance, `skin pack`, `unpack`, `inspect`, and `validate` remain available. Installation and application still preserve bindings and geometry:

```bash
thumble skin import IndigoPocket/build/indigo-pocket-1.0.0.pocketpad
thumble skin apply com.creator.indigo-pocket --profile "My Keypad"
thumble skin export com.creator.indigo-pocket -o IndigoPocket.pocketpad
```

## Semantic roles

Prefer role rules over profile UUIDs or labels:

| Role | Intended use |
|---|---|
| `movement` | D-pad and directional buttons |
| `primary_action` | Main face/action controls |
| `secondary_action` | Secondary face/action controls |
| `utility` | Maps, palettes, and tools |
| `menu` | Pause/menu controls |
| `custom` | Unclassified custom actions |
| `joystick` | Analog or digital sticks |
| `trigger` | Shoulder/trigger controls |
| `trackpad` | Pointer surfaces |
| `decoration` | Non-interactive artwork |
| `system` | Thumble chrome |

Users and creators can assign explicit roles in the Mac inspector or CLI:

```bash
thumble element set jump --skin-role primary-action
thumble element set "Pause" --skin-role menu
```

## Compatibility and passive layers

A universal skin styles semantic roles on any keypad. A `template_aligned` skin declares canonical template IDs/revisions, orientations, aspect range, roles, and required renderer features. Exact matches receive canvas artwork; unknown or mismatched layouts receive safe semantic materials while aligned art is hidden. Mac and iPhone import review show this degraded/incompatible state.

Underlay and overlay artwork layers are normalized, z-ordered, non-interactive, accessibility-hidden decorations. They support bounded frames, opacity, rotation, and normal/multiply/screen/overlay/soft-light blending. Layers never carry bindings, labels, or geometry.

Profile-level text elements are also passive native layers, but they remain editable keypad geometry rather than packaged artwork. Their control kind is `text`, they inherit the `decoration` semantic role for skin styling, and they never carry keyboard, pointer, or gamepad output.

## Assets and nine-slice media

Each asset has a normalized ID and a path under `assets/`. Reference the ID from an image fill, artwork layer, or asset icon—never an absolute path. Thumble materializes package resources into its native asset library when rendering or customizing a skin.

Image fills support scale, tile, nine-slice stretch, and nine-slice tile modes. Nine-slice cap insets are normalized fractions from 0–0.49 and must leave a non-empty center. Keep editable SVG outside the archive; compilation sanitizes and rasterizes it to PNG.

Keep individual files under 10 MB and the compressed archive under 40 MB. Publication quality budgets are stricter: 24 MB assets, 8 MB previews, and 30 MB encoded archive. Packages cannot contain executables, symlinks, undeclared files, absolute paths, or `..` traversal.

## Touch targets

Touch expansion belongs to the keypad profile, not the skin. It can be edited independently of artwork:

```bash
# all edges
thumble element set jump --hit-insets 16

# top, leading, bottom, trailing
thumble element set jump --hit-insets 10,18,14,18
```

The Mac editor and iPhone skin preview can display dashed touch-target overlays.

## Distribution and safety

A package can be shared directly through Finder, AirDrop, Files, or the iOS Share Sheet. Installation always shows creator, version, license, preview, compatibility warnings, validation warnings, and an appearance-only safety explanation.

Directory publication is a separate human gate. The scaffold creates `reviews/human-approval.json` with `pending` status. Agents must not change it to approved. A human approves the exact final contact sheet and package SHA-256 before catalog or deployment work begins.

The decoder rejects path traversal, symlinks, duplicate entries/IDs, unsupported schema versions, oversized files, excessive compression ratios, hash/size mismatches, undeclared content, and missing style/asset references. Direct file installation does not depend on a central catalog.

Existing keypad JSON export remains the full backup format and may include executable Mac bindings or launch-target data. Do not use it as a community skin format.
