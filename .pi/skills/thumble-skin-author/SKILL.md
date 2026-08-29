---
name: thumble-skin-author
description: Authors or revises handcrafted Thumble skins from editable JSON and SVG against canonical artboards, compiles packages, renders native state contact sheets, runs independent visual critique and strict QA, and prepares evidence for human approval. Use whenever creating, redesigning, critiquing, validating, or preparing a community Thumble skin. Never publishes autonomously.
compatibility: Requires macOS, Xcode, the Thumble project, and the thumble CLI.
---

# Thumble Skin Author

Use this workflow for finished community skins. A generated palette or renderer preset is never a finished skin.

Read [workflow.md](references/workflow.md) before execution and [quality-bar.md](references/quality-bar.md) before visual review. Use templates under `assets/` for review evidence.

## Non-negotiable boundaries

- Keep appearance, layout geometry, and executable bindings separate.
- Artwork may decorate native controls but must not replace hit testing, state, labels, or accessibility.
- Retain editable JSON and original SVG source. Ship only validated raster media in `.pocketpad`.
- Target a committed canonical artboard and review portrait plus landscape.
- Render normal, pressed, active, and disabled in light plus dark through the native renderer.
- Create original, legally distinct artwork. Do not trace console hardware, reuse logos, copy skin imagery, or imitate protected trade dress.
- Never publish, deploy, edit the public catalog, stage, commit, or push as part of this skill.
- Agents never grant human approval. Publication requires a human to approve the exact contact sheet and package SHA-256.

## Required staged workflow

1. **Art direction** — run the `thumble-art-director` agent. Require `reviews/art-direction.md` before source changes.
2. **Execution** — run the `thumble-skin-designer` agent to author JSON/SVG or a CSS workspace (`scaffold --css`, profile `thumble-css-core-1`), compile, validate, quality-check, and render `reviews/contact-sheet-1.png`.
3. **Independent critique** — run `thumble-visual-critic` against the exact sheet. The parent must read and synthesize findings; then give the designer exact corrective changes. Never delegate “fix whatever the critic found.”
4. **Repeat** — require at least two independent critic passes and a final `visual-pass`. Preserve every contact sheet and critique report.
5. **QA** — run `thumble-skin-qa`. A passing package must compile byte-for-byte identically twice and pass both strict validators.
6. **Human gate** — stop with `reviews/human-approval.json` pending. Ask the human to inspect the final sheet. Record approval only after an explicit human statement, including reviewer, timestamp, reviewed sheet, and exact package hash.

Dependencies make these stages sequential. Do not run art direction, design, and critique in parallel.

## Core commands

```bash
thumble skin artboard list
thumble skin artboard show ARTBOARD --json
thumble skin scaffold "Skin Name" \
  --identifier com.creator.skin-name \
  --artboard ARTBOARD \
  -o PATH                      # add --css for a CSS-authored workspace
thumble skin css capabilities
thumble skin css lint PATH
thumble skin css computed PATH --control builtin-jump --scheme dark --state pressed

thumble skin compile PATH -o PATH/build/skin.pocketpad --clean
thumble skin validate PATH/build/skin.pocketpad --strict
thumble skin quality PATH --artboard ARTBOARD --strict
thumble skin preview PATH \
  -o PATH/reviews/contact-sheet-N.png \
  --all-variants --all-states --native-renderer --contact-sheet --columns 4
thumble skin preview PACKAGE \
  -o /tmp/controller-view.png --orientation landscape --scheme light --state normal --json
```

To show a package's controller view inside an MCP chat without importing or applying it, call the `preview_skin_workspace` MCP tool with the absolute package path (see `references/workflow.md`).

CSS workspaces follow the same staged workflow, gates, and human approval; `thumble skin quality --strict` understands stylesheets directly. See `docs/skins/css-authoring.md` for the CSS profile and `docs/skins/examples/css-first-light/` for a complete example.

If `thumble` is not on `PATH`, build `ThumbleCLI` with Xcode and use the resulting executable. Guard long builds with a timeout and keep output bounded.

## Completion contract

A skin-authoring task is complete only when all of these exist:

- editable source: `skin-source.json` with SVG, or declared stylesheets for CSS workspaces;
- deterministic `.pocketpad` output;
- canonical compatibility metadata;
- all variant/state native contact sheet;
- at least two versioned critique reports, latest verdict `visual-pass`;
- strict package and quality results with no warnings;
- final QA verdict `qa-pass`;
- pending or explicitly human-approved approval record.

Report paths and hashes. Do not claim “published” or “approved” unless the human actually performed that action.