# Everyday Play — independent final QA, revision 1

Verdict: **qa-pass for the skin package**. Evaluated 2026-10-20 after reading art direction, designer notes, contrast evidence and independent critiques 1 and 2. Both critiques return `visual-pass` with no outstanding findings. No design source, fixtures, website or app state was changed during QA.

Package: `build/everyday-play-1.0.0.pocketpad`.

SHA-256: `68ce25aac1e2cf56bae6673857d6e7027d134a09136922683f2713f3a2784f9a`.

Frozen review sheet: `reviews/contact-sheet-1.png`, 2176×1714, 16 native Base frames. SHA-256: `a98cf528ac7fa8397fe8cc85dc2b168e16219f736983a60a06a0728dd32afcf7`.

## Reproduction commands

Run from `/Users/codybontecou/dev/Thumble`. All final gate commands exited 0. Unpack requires a fresh destination for repeated runs. QA writes supporting evidence only under `reviews/` and `/tmp/thumble-everyday-qa`.

```sh
CLI=build/ArtifactAdoptionBinaries/thumble
SRC=docs/skins/examples/everyday-play
mkdir -p /tmp/thumble-everyday-qa
$CLI skin compile "$SRC" --build-directory /tmp/thumble-everyday-qa/a -o /tmp/thumble-everyday-qa/a.pocketpad --clean --strict --json
$CLI skin compile "$SRC" --build-directory /tmp/thumble-everyday-qa/b -o /tmp/thumble-everyday-qa/b.pocketpad --clean --strict --json
cmp /tmp/thumble-everyday-qa/a.pocketpad /tmp/thumble-everyday-qa/b.pocketpad
cmp /tmp/thumble-everyday-qa/a.pocketpad "$SRC/build/everyday-play-1.0.0.pocketpad"
$CLI skin validate "$SRC/build/everyday-play-1.0.0.pocketpad" --strict --json
$CLI skin quality "$SRC" --artboard classic-16-bit-v1 --strict --json
$CLI skin quality "$SRC/build/everyday-play-1.0.0.pocketpad" --artboard classic-16-bit-v1 --strict --json
$CLI skin unpack "$SRC/build/everyday-play-1.0.0.pocketpad" -o /tmp/thumble-everyday-qa/unpacked
$CLI skin pack /tmp/thumble-everyday-qa/unpacked -o /tmp/thumble-everyday-qa/repacked.pocketpad
cmp /tmp/thumble-everyday-qa/repacked.pocketpad /tmp/thumble-everyday-qa/a.pocketpad
python3 "$SRC/reviews/qa-integrity.py"
$CLI skin preview "$SRC/build/everyday-play-1.0.0.pocketpad" -o /tmp/thumble-everyday-qa/native-contact-sheet-base.png --artboard classic-16-bit-v1 --all-variants --all-states --action-set base --native-renderer --contact-sheet --columns 4 --json
cmp /tmp/thumble-everyday-qa/native-contact-sheet-base.png "$SRC/reviews/contact-sheet-1.png"
shasum -a 256 /tmp/thumble-everyday-qa/a.pocketpad /tmp/thumble-everyday-qa/b.pocketpad /tmp/thumble-everyday-qa/repacked.pocketpad /tmp/thumble-everyday-qa/native-contact-sheet-base.png
```

## Findings

- Determinism: both independent strict compilations, frozen candidate and unpack/repack output are byte-for-byte identical, with the package hash above. Strict compile outputs have zero issues.
- Strict package validation: zero errors and warnings (`qa-validation.json`). Strict source and package quality: score 100, zero errors and warnings (`qa-quality.json`, `qa-package-quality.json`).
- Canonical compatibility: intended `classic-16-bit-v1` artboard, SNES template revision 2. Quality evaluates its canonical portrait and landscape profiles, rejects any result other than `compatible`, and checks native centers against safe areas. Both orientations pass. Manifest retains required menu, movement, primary-action, secondary-action and utility roles, artwork support, both orientations and aspect range 0.4–2.5. Canonical input identities remain the classic contract, rather than the showcase fixture.
- Native matrix: independent native rerender covers Base × portrait/landscape × light/dark × normal/pressed/active/disabled = 16 frames (`qa-native-preview.json`). Its bytes exactly match the frozen sheet. QA inspected the rerendered matrix: independent portrait composition, all functional labels, neutral caps, paired muted accents, separated sockets and distinct native states remain visible. Detailed socket/craft review is recorded in both independent critiques. Frozen sheet 1 was never overwritten.
- Reproduction detail: an initial native run omitted the explicit `--action-set base` option, so contact-sheet headings omitted the Base suffix and file bytes differed. Repeating with the exact Base flag yields the byte-identical frozen sheet. No source/package change was made to obtain that result.
- Integrity and budgets: all four declared PNG hashes, byte counts and dimensions match; `skin.json` matches its manifest SHA-256. Landscape assets are two 1748×804 PNGs; portrait assets are two 804×1748 PNGs. Total unpacked bytes: 1,130,016. Strict dimension/asset budgets pass. Full reproducible assertions and values are in `qa-integrity.py` and `qa-integrity.txt`.
- Distribution safety: exact archive-file allowlist is `manifest.json`, appearance-only `skin.json` and four declared PNGs. No CSS, SVG, source script, symlink, executable action, profile or binding payload ships. Semantic selectors remain appearance metadata. All four original orientation/scheme SVGs, source JSON and declared CSS remain editable outside the distributable.
- Contrast and state evidence: strict quality checks representative native legend/state contrast, state completeness, semantic assignments, alignment, safe areas and budgets. Recorded opaque derived-state contrast evidence passes every listed threshold: minimum functional legend 6.897:1, important boundary 3.071:1, signature over 4.5:1. Both critiques verify distinct inset pressed, broader outlined active and flattened disabled treatments without geometry or label displacement. QA checks the recorded contrast thresholds; it does not certify every composited pixel or arbitrary user layout.
- Preview readiness: four clean native normal singles and frozen native matrix are present; package can regenerate both orientations and schemes. Native clean imagery is separate from actual app state/accessibility verification. This verdict does not claim app runtime inspection or public website/catalog readiness beyond the available preview assets.
- Stack safety: inspected parent-run `/tmp/thumble-everyday-stack-safety.log`, ending `Stack-safety verification passed.` Parent ran the required script; QA did not rerun the suite. This task alters skin review evidence only.

## Warnings and approval boundary

Strict compile/validation/quality warnings: **none**. This is an appearance package; it does not add or verify executable gameplay mappings. Human approval remains `pending`; reviewer, timestamp, approved contact sheet and approved package hash remain null. QA does not grant human approval or publication permission. No public catalog edit, publish, deploy, stage, commit, push or app-state mutation was performed.
