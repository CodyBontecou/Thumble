# Warband Command — independent QA, revision 3 (1.0.2)

Verdict: **qa-pass for the skin package**. Evaluated 2026-10-20 after reading `art-direction-3.md` and independent critiques 6 and 7, both `visual-pass`. No design source or package was changed to obtain this result. The separately implemented clean app mode is outside this skin-package QA verdict.

Package: `build/warband-command-1.0.2.pocketpad`.

SHA-256: `1f53393e57dc7f93741b0067d6b36fdcdb7773f7170712aee8242642f1591782`.

Frozen review sheet: `reviews/contact-sheet-6.png`, 4320×3338, 64 native frames. SHA-256: `e485e8421632b3eb54c5248325f7cc76c5eb3fa4cfa2a20a584561203aded9f2`.

## Exact reproduction commands

Run from `/Users/codybontecou/dev/Thumble`. All substantive commands exited 0. Temporary outputs use `/tmp/thumble-warband-qa-3`; the integrity reproduction requires Pillow, available in the current Python environment. Use a fresh temporary output directory when repeating unpack commands.

```sh
CLI=build/ArtifactAdoptionBinaries/thumble
SRC=docs/skins/examples/warband-command
mkdir -p /tmp/thumble-warband-qa-3
$CLI skin compile "$SRC" --build-directory /tmp/thumble-warband-qa-3/a -o /tmp/thumble-warband-qa-3/a.pocketpad --clean --strict --json
$CLI skin compile "$SRC" --build-directory /tmp/thumble-warband-qa-3/b -o /tmp/thumble-warband-qa-3/b.pocketpad --clean --strict --json
cmp /tmp/thumble-warband-qa-3/a.pocketpad /tmp/thumble-warband-qa-3/b.pocketpad
cmp /tmp/thumble-warband-qa-3/a.pocketpad "$SRC/build/warband-command-1.0.2.pocketpad"
$CLI skin validate "$SRC/build/warband-command-1.0.2.pocketpad" --strict --json
$CLI skin quality "$SRC" --artboard wow-forever-v1 --strict --json
$CLI skin quality "$SRC/build/warband-command-1.0.2.pocketpad" --artboard wow-forever-v1 --strict --json
$CLI skin unpack "$SRC/build/warband-command-1.0.2.pocketpad" -o /tmp/thumble-warband-qa-3/unpacked
$CLI skin unpack "$SRC/reviews/archive-icons-1.0.1/warband-command-1.0.1.pocketpad" -o /tmp/thumble-warband-qa-3/previous
$CLI skin pack /tmp/thumble-warband-qa-3/unpacked -o /tmp/thumble-warband-qa-3/repacked.pocketpad
cmp /tmp/thumble-warband-qa-3/repacked.pocketpad /tmp/thumble-warband-qa-3/a.pocketpad
python3 "$SRC/reviews/qa-integrity-3.py"
$CLI skin preview "$SRC/build/warband-command-1.0.2.pocketpad" -o /tmp/thumble-warband-qa-3/native-contact-sheet.png --artboard wow-forever-v1 --all-variants --all-states --all-action-sets --native-renderer --contact-sheet --columns 8 --json
cmp /tmp/thumble-warband-qa-3/native-contact-sheet.png "$SRC/reviews/contact-sheet-6.png"
shasum -a 256 /tmp/thumble-warband-qa-3/a.pocketpad /tmp/thumble-warband-qa-3/b.pocketpad /tmp/thumble-warband-qa-3/repacked.pocketpad "$SRC/reviews/contact-sheet-6.png" /tmp/thumble-warband-qa-3/native-contact-sheet.png
```

## Results

- Determinism: both independent strict compilations, frozen candidate and unpack/repack output are byte-for-byte identical, with the package hash above. Compilation reports zero issues.
- Strict package validation: zero errors and warnings (`qa-validation-3.json`). Strict source and package quality: score 100, zero issues (`qa-quality-3.json`, `qa-package-quality-3.json`).
- Canonical compatibility: quality explicitly evaluates both canonical profile orientations and fails any compatibility result other than `compatible`; both pass, including control-center safe-area checks. Manifest retains template `wowforever` revision 1, portrait/landscape, aspect ratios 0.4–2.5, artwork/action-set support and joystick role. The public artboard authoring ID is `wow-forever-v1`; preview JSON reports template ID `wowforever`.
- Native reproduction: all four banks × both orientations × both schemes × normal/pressed/active/disabled = 64 frames (`qa-native-preview-3.json`). Independent native sheet is byte-for-byte identical to frozen sheet 6. QA inspected the rerendered matrix; original framing, open ground, fixed controls and native state perimeters remain present. The two independent visual critiques separately inspect detailed crops and icon comparisons.
- Integrity and safety: all 12 declared PNG hashes, byte counts and dimensions match. Eight ability PNGs remain 56×56; two landscape canvas PNGs are 1748×804; two portrait canvas PNGs are 804×1748. Unpacked bytes total 3,145,643; strict asset budgets pass. Exact archive-file allowlist is `manifest.json`, appearance-only `skin.json`, and declared PNG assets. No source SVG, CSS, scripts, binding/profile payload or symlink ships. Semantic action names are appearance selectors. Assertions and results are retained in `qa-integrity-3.py` and `qa-integrity-3.txt`.
- Original asset verification: all eight retained JPEG originals match their historical SHA-256; all eight new Warcraft Wiki original PNG files match recorded SHA-256, size and API/delivered SHA1. Each decoded original is 64×64. The output is the exact [4,4,60,60] 56×56 interior crop, verified both pixel-for-pixel and byte-for-byte after independent PNG re-encoding. This reproduces the operation in `sources/restore-lossless-icons.py` without running its source-writing loop. No resize, sharpening, recoloring or generative enhancement is involved. API correspondence is checked against the retained provenance, not a fresh network fetch.
- Appearance freeze: QA independently unpacked the archived 1.0.1 package. Entire compiled `skin.json` and all four SVG-derived canvas PNGs are byte-identical to 1.0.2, confirming `sources/research/appearance-invariants.json`. Thus compiled native materials, bank mapping and appearance configuration are preserved. Editable SVG/CSS and original/provenance evidence remain in source, outside the distributable.
- Quality scope: strict evaluator checks representative native legend/state contrast, state completeness, semantic assignments, native alignment, asset budgets and safe areas. Detailed visual findings and input-label clearance pass critiques 6 and 7. These do not certify live gameplay bindings or composited-pixel contrast in arbitrary user layouts.
- Preview readiness: native portrait/landscape, light/dark and all-bank evidence regenerates from the package. This is native skin renderer evidence, not proof of app navigation/sidebar/guide hiding, editing restoration, accessibility behavior or CLI parity. Parent separately owns actual app captures and app/CLI verification; this QA makes no claim of completed app UI review.
- Stack safety: inspected parent-run `/tmp/thumble-warband-polish-stack-safety.log`, ending `Stack-safety verification passed.` Parent ran `./scripts/verify-stack-safety.sh`; QA did not rerun it or review the separate app changes under this package-only verdict.

## Warnings and approval

Strict compile/validation/quality warnings: **none**. Cleaner lossless source assets retain the same 56×56 interior resolution; do not describe these as HD or higher-resolution textures. Provenance does not verify the assets against a locally installed Forever beta client. This package supplies example ability artwork and appearance, not live spell/cooldown synchronization or verified game bindings.

Human approval remains `pending`, with reviewer, timestamp, sheet and approved hash null. QA does not authorize publication or human approval. Previous reports and supporting evidence are preserved; this pass writes only `-3` evidence plus the current report. No design/package mutation, public catalog edit, publish, deploy, stage, commit or push was performed.
