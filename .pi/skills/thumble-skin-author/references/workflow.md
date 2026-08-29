# Handcrafted skin workflow

## 1. Choose the contract

Inspect canonical artboards before drawing:

```bash
thumble skin artboard list
thumble skin artboard show showcase-controller-v1 --json
thumble skin artboard export showcase-controller-v1 -o /tmp/showcase-profile.json
```

An artboard is a geometry contract: canvas dimensions, safe areas, semantic control roles, and normalized frames. A template-aligned skin may still apply semantic materials to another layout, but aligned canvas artwork is hidden when compatibility is degraded or incompatible.

## 2. Scaffold editable source

```bash
thumble skin scaffold "Name" \
  --identifier com.creator.name \
  --artboard showcase-controller-v1 \
  -o Website/skins/sources/name
```

Add `--css` to author with real CSS instead of materials. CSS workspaces declare stylesheets in `skin-source.json` (`stylesheets: ["styles/controller.css"]`) under profile `thumble-css-core-1`; unsupported CSS is a strict compile error. See `docs/skins/css-authoring.md`.

Expected source tree (materials):

```text
skin-source.json
sources/artwork/*.svg
sources/icons/*.svg
reviews/README.md
reviews/human-approval.json
build/                       # generated, ignored
```

CSS workspaces replace SVG sources with `styles/*.css`; both paths produce the same validated package format.

SVG is authoring input only. The sanitizer rejects scripts, external URLs, entities, event handlers, pathological complexity, traversal, and symlinks. Compilation rasterizes visual media to package-safe PNG.

## 3. Direct before designing

The art director inspects portrait and landscape separately and writes:

- concept and originality boundary;
- silhouette/focal hierarchy;
- light/dark palette and contrast targets;
- material/edge/lighting/texture rules;
- native state behavior;
- measurable acceptance criteria.

Do not accept a brief that is only a list of adjectives.

## 4. Execute as components

Use named palette, material, component, and semantic assignment tokens. Prefer a small coherent system over many unrelated effects.

A complete composition normally includes:

- canvas ground;
- controller shell with consistent edge logic;
- movement and action wells aligned to artboard roles;
- distinct action, movement, shoulder, and utility materials;
- deliberate legends and icon treatment;
- one lighting direction;
- restrained texture at the correct physical scale;
- orientation-aware spacing and negative space.

Artwork remains passive. Native controls render state and preserve accessibility. When derived states are not visually distinct enough, use the source schema's optional pressed/active/disabled fills, boundaries, shadow scales, and light/dark joystick puck colors; never paint state feedback into SVG.

## 5. Compile and inspect

```bash
thumble skin compile SOURCE -o SOURCE/build/name.pocketpad --clean
thumble skin validate SOURCE/build/name.pocketpad --strict
thumble skin quality SOURCE --strict
thumble skin preview SOURCE \
  -o SOURCE/reviews/contact-sheet-1.png \
  --all-variants --all-states --native-renderer --contact-sheet
```

The package compiler is deterministic. Native review snapshots use the real SwiftUI renderer and are review evidence, not inputs to package hashing. For CSS workspaces, `thumble skin css lint` and `thumble skin css computed` diagnose stylesheets before compiling, and `thumble skin quality --strict` evaluates compiled tokens directly.

### Showing the controller view in chat (read-only)

The `render_controller` MCP tool only shows the installed active profile. To show a review package's exact controller view inside an MCP chat (ChatGPT, Codex, Claude) without importing or applying it, call the `preview_skin_workspace` MCP tool — it renders any absolute `.pocketpad` package path (or workspace directory) with the same native renderer and returns the image inline. Example parameters:

```json
{
  "sourcePath": "/absolute/path/to/skin.pocketpad",
  "orientation": "landscape",
  "scheme": "light",
  "state": "normal",
  "scale": 2
}
```

All parameters except `sourcePath` are optional. The equivalent CLI command is `thumble skin preview SOURCE -o OUT.png --orientation landscape --scheme light --state normal --render-scale 2 --json`. These renders are display-only evidence; they never change the active controller, configuration, or paired phone, and they are not a substitute for the immutable contact sheet used for critique and human approval.

## 6. Critique loop

Run the critic on the exact rendered file. The parent reads the report and turns accepted findings into a bounded designer task with paths and measurable outcomes. Preserve evidence:

```text
reviews/contact-sheet-1.png
reviews/critique-1.md
reviews/contact-sheet-2.png
reviews/critique-2.md
...
```

Minimum: two critique passes. Continue until the latest verdict is `visual-pass`; do not average away a blocker.

## 7. Strict QA

QA recompiles twice to separate directories and compares package hashes, then validates, quality-checks, unpacks, and rerenders. Any strict warning fails QA.

Recommended determinism check:

```bash
thumble skin compile SOURCE --build-directory /tmp/skin-a -o /tmp/a.pocketpad --clean
thumble skin compile SOURCE --build-directory /tmp/skin-b -o /tmp/b.pocketpad --clean
cmp /tmp/a.pocketpad /tmp/b.pocketpad
shasum -a 256 /tmp/a.pocketpad
```

## 8. Human approval

The human reviews the final contact sheet and package hash. Agents must leave the approval record pending until the user explicitly approves that exact evidence. Human approval is separate from QA and separate from publication.

After approval, an ordinary repository workflow may update the static directory, but this skill itself never does so.