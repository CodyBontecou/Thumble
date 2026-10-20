# Warband Command — final independent QA, revision 2 (declutter 1.0.1)

Verdict: **qa-pass**. Evaluated 2026-10-20 after reading the revised art-direction-2.md, critiques 4–5, and designer notes. Latest independent verdict is `visual-pass` in `critique-5.md`, with no unresolved major findings. No design source or distributable was changed to obtain this result.

Package: `build/warband-command-1.0.1.pocketpad`.

SHA-256: `d36d38ae724063f4cd53e7ccbaa086133a38bdec44d4c2145d226b63ac177fda`.

Frozen human-review evidence: `reviews/contact-sheet-5.png`, 4320×3338, 64 native frames. SHA-256: `8058cd709f2e71f1679152a53efe5685aab6ecf09899f7e8666619d58e498c43`.

## Reproduction commands and outcomes

All commands run from `/Users/codybontecou/dev/Thumble`; each substantive command exited 0. Temporary outputs are under `/tmp/thumble-warband-qa-2`. `CLI` and `SRC` below are convenience variables only.

```sh
CLI=build/ArtifactAdoptionBinaries/thumble
SRC=docs/skins/examples/warband-command
mkdir -p /tmp/thumble-warband-qa-2
$CLI skin compile "$SRC" --build-directory /tmp/thumble-warband-qa-2/a -o /tmp/thumble-warband-qa-2/a.pocketpad --clean --strict --json
$CLI skin compile "$SRC" --build-directory /tmp/thumble-warband-qa-2/b -o /tmp/thumble-warband-qa-2/b.pocketpad --clean --strict --json
cmp /tmp/thumble-warband-qa-2/a.pocketpad /tmp/thumble-warband-qa-2/b.pocketpad
cmp /tmp/thumble-warband-qa-2/a.pocketpad "$SRC/build/warband-command-1.0.1.pocketpad"
$CLI skin validate "$SRC/build/warband-command-1.0.1.pocketpad" --strict --json
$CLI skin quality "$SRC" --artboard wow-forever-v1 --strict --json
$CLI skin quality "$SRC/build/warband-command-1.0.1.pocketpad" --artboard wow-forever-v1 --strict --json
$CLI skin unpack "$SRC/build/warband-command-1.0.1.pocketpad" -o /tmp/thumble-warband-qa-2/unpacked
$CLI skin pack /tmp/thumble-warband-qa-2/unpacked -o /tmp/thumble-warband-qa-2/repacked.pocketpad
cmp /tmp/thumble-warband-qa-2/repacked.pocketpad /tmp/thumble-warband-qa-2/a.pocketpad
python3 "$SRC/reviews/qa-integrity-2.py"
$CLI skin preview "$SRC/build/warband-command-1.0.1.pocketpad" -o /tmp/thumble-warband-qa-2/native-contact-sheet.png --artboard wow-forever-v1 --all-variants --all-states --all-action-sets --native-renderer --contact-sheet --columns 8 --json
cmp /tmp/thumble-warband-qa-2/native-contact-sheet.png "$SRC/reviews/contact-sheet-5.png"
shasum -a 256 /tmp/thumble-warband-qa-2/a.pocketpad /tmp/thumble-warband-qa-2/b.pocketpad /tmp/thumble-warband-qa-2/repacked.pocketpad "$SRC/reviews/contact-sheet-5.png" /tmp/thumble-warband-qa-2/native-contact-sheet.png
```

- Determinism: both independent strict compiles, frozen candidate and unpack/repack output are byte-for-byte identical, all with the package hash above. Compilation reports zero issues.
- Strict package validation: zero errors and warnings (`qa-validation-2.json`).
- Strict source and package quality: score 100, zero errors and warnings, intended `wow-forever-v1` artboard (`qa-quality-2.json`, `qa-package-quality-2.json`).
- Canonical compatibility: the quality evaluator explicitly evaluates each canonical profile orientation, rejects any result other than `compatible`, and checks native control centers against safe areas. Both portrait and landscape pass. Manifest targets canonical `wowforever` revision 1, both orientations, aspect ratios 0.4–2.5, artwork/action-set layer support and joystick role. The artboard public authoring ID is `wow-forever-v1`; preview JSON reports its template ID `wowforever`.
- Native rerender: all four action sets × both appearances × both orientations × normal/pressed/active/disabled = 64 frames (`qa-native-preview-2.json`). The 8-column independent rerender is byte-for-byte identical to the frozen final sheet. QA inspected the independently rerendered matrix; both schemes and orientations retain the simplified open composition.
- Integrity and safety: all 12 declared PNG assets match their SHA-256 and byte counts; all 8 retained original/converted ability pairs match provenance. Exact unpacked file allowlist is manifest, appearance skin JSON and the declared PNGs. No SVG, CSS, source scripts, profiles, binding payloads, symlinks or executable actions ship. Skin JSON contains only base and appearance variants; semantic action names remain appearance selectors. Full reproducible assertions and dimensions are in `qa-integrity-2.py` and `qa-integrity-2.txt`. Total unpacked size is 3,171,294 bytes; strict asset budgets pass.
- Dimensions: eight 56×56 ability icons; two 1748×804 landscape artwork images; two 804×1748 portrait artwork images. Original SVG, CSS, originals and provenance remain editable in the source workspace, outside the distributable.
- Visual/state checks: latest independent critique verifies composition, alignment, native input labels, held-modifier wording, distinct native states and centered stick captions. The independent byte-identical native matrix confirms that QA reviewed the same candidate. Strict quality checks cover representative native state/legend contrast, state completeness, semantic assignments, aspect alignment, asset budgets and safe areas. These checks are not a guarantee of live gameplay or composited-pixel contrast in arbitrary user layouts.
- Preview readiness: native landscape/portrait, light/dark and bank evidence is present and regenerates from the package. The parent owns final clean presentation and `preview/` assets. This is native renderer evidence, not a live app capture. The live preview at port 3200 remains the older version; this QA pass does not claim that live instance was updated or that a website catalog entry was published.
- Stack safety: parent-run `./scripts/verify-stack-safety.sh` evidence at `/tmp/thumble-warband-declutter-stack-safety.log` ends with `Stack-safety verification passed.` QA inspected that result; it did not rerun the full suite. This task changes source skin assets only, not app/CLI Swift. Parent verifies the live app separately.

## Declutter-specific verification

Four ledger PNG declarations are absent from the package manifest, reducing the declared assets from 16 to 12. Active SVG/source JSON contain no ledger, BANK REFERENCE or embedded-image remnants (`rg -n -i 'ledger|bank reference|<image' sources/artwork/*.svg skin-source.json` returns no matches). Native renders retain every functional control, input tag, modifier bank and held label, while the passive bank diagrams are absent across all 64 frames. Editable original SVG, CSS, provenance and prior reviews remain retained. Superseded source scripts are archived as review history rather than shipped. App-owned offline toolbar chrome is outside this appearance package and is excluded from the clean presentation only.

## Remaining warnings and approval boundary

Strict compilation, validation and quality warnings: **none**. Example icons are existing attributed Blizzard artwork; provenance explicitly does not verify them against an installed Forever beta client. This is an appearance package and configured example ability display, not a live spell/cooldown integration or verification of WoW bindings.

`human-approval.json` remains `pending`; reviewer, timestamp, reviewed sheet and approved package hash remain null. Human approval has not been granted. This QA pass authorizes neither publication nor a claim of human approval. Prior QA is preserved as `qa-report-1.md` and all original QA evidence remains unchanged. No public catalog edit, publish, deploy, stage, commit or push was performed.
