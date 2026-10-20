# Warband Command — final independent QA, revision 1

Verdict: **qa-pass**. Evaluated 2026-10-20 after reading the art-direction brief, critiques 1–3, and designer notes. Latest independent verdict is `visual-pass` in `critique-3.md`, with no unresolved major findings. No design source or distributable was changed to obtain this result.

Package: `build/warband-command-1.0.0.pocketpad`.

SHA-256: `494f1af8f1bff172e754fb35a5dd3981f0a514b1c6114d6ca1f3b0af14d674af`.

Frozen human-review evidence: `reviews/contact-sheet-4.png`, 4320×3338, 64 native frames. SHA-256: `7f29617bae9121252d4ce56b5d4e7444793f7c9f7247ad64f02860b5997b68f5`.

## Reproduction commands and outcomes

All commands run from `/Users/codybontecou/dev/Thumble`; each substantive command exited 0. Temporary outputs are under `/tmp/thumble-warband-qa`. `CLI` and `SRC` below are convenience variables only.

```sh
CLI=build/ArtifactAdoptionBinaries/thumble
SRC=docs/skins/examples/warband-command
mkdir -p /tmp/thumble-warband-qa
$CLI skin compile "$SRC" --build-directory /tmp/thumble-warband-qa/a -o /tmp/thumble-warband-qa/a.pocketpad --clean --strict --json
$CLI skin compile "$SRC" --build-directory /tmp/thumble-warband-qa/b -o /tmp/thumble-warband-qa/b.pocketpad --clean --strict --json
cmp /tmp/thumble-warband-qa/a.pocketpad /tmp/thumble-warband-qa/b.pocketpad
cmp /tmp/thumble-warband-qa/a.pocketpad "$SRC/build/warband-command-1.0.0.pocketpad"
$CLI skin validate "$SRC/build/warband-command-1.0.0.pocketpad" --strict --json
$CLI skin quality "$SRC" --artboard wow-forever-v1 --strict --json
$CLI skin quality "$SRC/build/warband-command-1.0.0.pocketpad" --artboard wow-forever-v1 --strict --json
$CLI skin unpack "$SRC/build/warband-command-1.0.0.pocketpad" -o /tmp/thumble-warband-qa/unpacked
$CLI skin pack /tmp/thumble-warband-qa/unpacked -o /tmp/thumble-warband-qa/repacked.pocketpad
cmp /tmp/thumble-warband-qa/repacked.pocketpad /tmp/thumble-warband-qa/a.pocketpad
python3 "$SRC/reviews/qa-integrity.py"
$CLI skin preview "$SRC/build/warband-command-1.0.0.pocketpad" -o /tmp/thumble-warband-qa/native-contact-sheet.png --artboard wow-forever-v1 --all-variants --all-states --all-action-sets --native-renderer --contact-sheet --columns 4 --json
$CLI skin preview "$SRC/build/warband-command-1.0.0.pocketpad" -o /tmp/thumble-warband-qa/native-contact-sheet-8.png --artboard wow-forever-v1 --all-variants --all-states --all-action-sets --native-renderer --contact-sheet --columns 8 --json
cmp /tmp/thumble-warband-qa/native-contact-sheet-8.png "$SRC/reviews/contact-sheet-4.png"
shasum -a 256 /tmp/thumble-warband-qa/a.pocketpad /tmp/thumble-warband-qa/b.pocketpad /tmp/thumble-warband-qa/repacked.pocketpad "$SRC/reviews/contact-sheet-4.png" /tmp/thumble-warband-qa/native-contact-sheet-8.png
```

- Determinism: both independent strict compiles, frozen candidate and unpack/repack output are byte-for-byte identical, all with the package hash above. Compilation reports zero issues.
- Strict package validation: zero errors and warnings (`qa-validation.json`).
- Strict source and package quality: score 100, zero errors and warnings, intended `wow-forever-v1` artboard (`qa-quality.json`, `qa-package-quality.json`).
- Canonical compatibility: the quality evaluator explicitly evaluates each canonical profile orientation, rejects any result other than `compatible`, and checks native control centers against safe areas. Both portrait and landscape pass. Manifest targets canonical `wowforever` revision 1, both orientations, aspect ratios 0.4–2.5, artwork/action-set layer support and joystick role. The artboard public authoring ID is `wow-forever-v1`; preview JSON reports its template ID `wowforever`.
- Native rerender: all four action sets × both appearances × both orientations × normal/pressed/active/disabled = 64 frames (`qa-native-preview.json`). The 8-column independent rerender is byte-for-byte identical to the frozen final sheet. The initial 4-column rerender was independently inspected and has the same 64-frame matrix, arranged vertically.
- Integrity and safety: all 16 declared PNG assets match their SHA-256 and byte counts; all 8 retained original/converted ability pairs match provenance. Exact unpacked file allowlist is manifest, appearance skin JSON and the declared PNGs. No SVG, CSS, source scripts, profiles, binding payloads, symlinks or executable actions ship. Skin JSON contains only base and appearance variants; semantic action names remain appearance selectors. Full reproducible assertions and dimensions are in `qa-integrity.py` and `qa-integrity.txt`. Total unpacked size is 3,363,555 bytes; strict asset budgets pass.
- Dimensions: eight 56×56 ability icons; four 1748×804 landscape artwork/ledger images; four 804×1748 portrait artwork/ledger images. Original SVG, CSS, originals and provenance remain editable in the source workspace, outside the distributable.
- Visual/state checks: latest independent critique verifies composition, alignment, native input labels, held-modifier wording, distinct native states and centered stick captions. The independent byte-identical native matrix confirms that QA reviewed the same candidate. Strict quality checks cover representative native state/legend contrast, state completeness, semantic assignments, aspect alignment, asset budgets and safe areas. These checks are not a guarantee of live gameplay or composited-pixel contrast in arbitrary user layouts.
- Preview readiness: native landscape/portrait, light/dark and bank evidence is present and regenerates from the package. The parent owns final app captures and `preview/` assets; this QA pass does not claim publication or a website catalog entry.
- Stack safety: parent-run `./scripts/verify-stack-safety.sh` evidence at `/tmp/thumble-warband-stack-safety.log` ends with `Stack-safety verification passed.` QA inspected that result; it did not rerun the full suite. This task changes source skin assets only, not app/CLI Swift. Parent verifies the live app separately.

## Remaining warnings and approval boundary

Strict compilation, validation and quality warnings: **none**. Example icons are existing attributed Blizzard artwork; provenance explicitly does not verify them against an installed Forever beta client. This is an appearance package and configured example ability display, not a live spell/cooldown integration or verification of WoW bindings.

`human-approval.json` remains `pending`; reviewer, timestamp, reviewed sheet and approved package hash remain null. Human approval has not been granted. This QA pass authorizes neither publication nor a claim of human approval. No public catalog edit, publish, deploy, stage, commit or push was performed.
