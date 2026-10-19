# Fury Forge — final QA report

Revision: 1. Package: `com.thumble.fury-forge` 1.0.0. Date: 2026-10-09.

**Verdict: qa-pass.** Strict validators returned no errors or warnings. Latest independent critique is `visual-pass`; both critique 1 and critique 2 and the art-direction brief were read. This is technical readiness only, not human approval or publication authorization.

## Immutable candidate

- Package: `build/fury-forge.pocketpad` — SHA-256 `31c400f4bd0468019100e2e7450e9a375ae05c9e51d05353e058f287c1a6850a`.
- Final human-review sheet: `reviews/contact-sheet-2.png` — SHA-256 `7c1104934782e157b79e533c9e33598bd6ac1b42e0724755718aeab7f3163dad` (2176 × 1714).
- Landscape hero: `reviews/landscape-dark-2.png` — SHA-256 `e51ecd2479def94ea283ee25c4921aa932dbd602ce13b60cf4579147aca20efb`.

All commands ran from the repository root using `build/WoWForever/bin/thumble`. QA wrote separate temporary outputs under `/private/tmp/fury-final-qa`; it did not overwrite either reviewed sheet, source, live configuration, preferences, or installed profiles.

## Commands and results

```sh
build/WoWForever/bin/thumble skin compile docs/skins/examples/fury-forge --build-directory /private/tmp/fury-final-qa/a -o /private/tmp/fury-final-qa/a.pocketpad --clean --strict --json
build/WoWForever/bin/thumble skin compile docs/skins/examples/fury-forge --build-directory /private/tmp/fury-final-qa/b -o /private/tmp/fury-final-qa/b.pocketpad --clean --strict --json
cmp /private/tmp/fury-final-qa/a.pocketpad /private/tmp/fury-final-qa/b.pocketpad
cmp /private/tmp/fury-final-qa/a.pocketpad docs/skins/examples/fury-forge/build/fury-forge.pocketpad
build/WoWForever/bin/thumble skin validate docs/skins/examples/fury-forge/build/fury-forge.pocketpad --strict --json
build/WoWForever/bin/thumble skin quality docs/skins/examples/fury-forge --artboard wow-forever-v1 --strict --json
build/WoWForever/bin/thumble skin unpack /private/tmp/fury-final-qa/a.pocketpad -o /private/tmp/fury-final-qa/unpacked
build/WoWForever/bin/thumble skin pack /private/tmp/fury-final-qa/unpacked -o /private/tmp/fury-final-qa/repacked.pocketpad
cmp /private/tmp/fury-final-qa/a.pocketpad /private/tmp/fury-final-qa/repacked.pocketpad
build/WoWForever/bin/thumble skin validate /private/tmp/fury-final-qa/repacked.pocketpad --strict --json
build/WoWForever/bin/thumble skin quality /private/tmp/fury-final-qa/repacked.pocketpad --artboard wow-forever-v1 --strict --json
build/WoWForever/bin/thumble skin preview docs/skins/examples/fury-forge -o /private/tmp/fury-final-qa/contact-sheet.png --all-variants --all-states --native-renderer --contact-sheet --columns 4 --json
build/WoWForever/bin/thumble skin preview docs/skins/examples/fury-forge/build/fury-forge.pocketpad -o /private/tmp/fury-final-qa/package-contact-sheet.png --all-variants --all-states --native-renderer --contact-sheet --columns 4 --json
cmp /private/tmp/fury-final-qa/contact-sheet.png docs/skins/examples/fury-forge/reviews/contact-sheet-2.png
cmp /private/tmp/fury-final-qa/package-contact-sheet.png docs/skins/examples/fury-forge/reviews/contact-sheet-2.png
```

All listed commands passed. Both compiles returned `issues: []`. Both quality commands returned **100** and `issues: []`. Original and repacked strict validation returned `issues: []`. Both rerenders returned **16 frames**, covering portrait/landscape × light/dark × normal/pressed/active/disabled; both were byte-identical to the final reviewed contact sheet. The package render resolved normalized template ID `wowforever` to the same canonical geometry. Canonical preview succeeded with the current saved-config environment without reading an active profile or connecting to a private/live host, exercising the CLI canonical-preview regression fix.

## Integrity, boundaries and compatibility

The archive has exactly ten entries: manifest, compiled appearance JSON, and eight declared PNGs. It is 356,854 bytes compressed (1,278,652 bytes uncompressed). No SVG, stylesheet, JPEG originals, executable content, profile payload or input bindings are shipped. Recursive compiled-JSON inspection found no `keyBindings`, `outputBindings`, `profiles`, `activeProfileID`, `defaultProfileID`, `joystickMapping`, `outputSettings`, or `partOutputs`. The input UUID selectors in appearance rules identify controls; they do not change gamepad routing. The package is appearance-only and contains no fields capable of replacing the canonical profile’s two analog axes, sixteen physical gamepad buttons, held modifiers, or layout geometry. QA did not apply the package to a stored profile or measure a live profile before/after, so output preservation is supported by package boundaries and canonical preview, not a live gameplay test. No gameplay input was sent.

Strict quality evaluates template compatibility and safe-area centers separately for **both orientations**; each is compatible with `wow-forever-v1` revision 1. Package metadata retains template-aligned mode, portrait/landscape orientations, 0.4–2.5 aspect range, artwork-layer feature and joystick role. Full state matrices, supported dimensions and byte budgets passed strict quality. The original artwork and ability/icon roles are declared and used; optional ability assets remain outside the distributable archive.

Native legend palette contrast was independently calculated with WCAG relative luminance: light normal/active 10.37:1, pressed 6.81:1, disabled 8.14:1; dark normal/active 9.51:1, pressed 14.43:1, disabled 11.33:1 before state opacity compositing. These calculations are palette checks; strict quality additionally covers compiled styles, and visual critique covers final native composites. Image-only ability faces have no text overlay. Source images remain square and the independent critic confirmed uncropped, legible icons and usable state edges. The optional minor face-state perimeter refinement in critique 2 remains nonblocking.

Manifest byte counts and SHA-256 values were compared directly against every unpacked asset. All eight provenance entries’ original JPEG and PNG hashes match preserved files, and dimensions match declared 56 × 56. All source URLs use Blizzard’s official `render.worldofwarcraft.com/icons/56/` CDN. Attribution remains © Blizzard Entertainment, all rights reserved. The user’s explicit real-icon request is the narrow exception to the skill’s game-art restriction; original SVG framing and CSS remain separate. Exact pixel identity against an installed Forever beta client remains unverified and is accurately disclosed in README/provenance. No Raging Blows action is present.

| Packaged asset | Dimensions | Bytes | SHA-256 |
|---|---:|---:|---|
| `forge-landscape-light` | 1748 × 804 | 104754 | `c1ad1ba20448089842eb1e478dbff41a1b7b302690a0e53120e4b4f6db51baf2` |
| `forge-landscape-dark` | 1748 × 804 | 105529 | `903041d7d484c023fa2bd1477c4ddb62c7abfbe78b91d57cadd9e5a879839b37` |
| `forge-portrait-light` | 804 × 1748 | 75233 | `6f7c8e2d3ec48b535f3bbf56fc1f59ff90b2efa885ae2744a926ca6be81974b0` |
| `forge-portrait-dark` | 804 × 1748 | 74377 | `c1f4c6c6ce8a715373c63118ca7644263bb3929292b160af865be0be2ecde0c5` |
| `bloodthirst` | 56 × 56 | 7688 | `1b5e2e478760678f3889a5d104ecc8a0dbade0975e09cf8c20c87e80b95c92e8` |
| `cleave` | 56 × 56 | 7347 | `812930b564dbd7f52bc152556a53a448757dac27c4a856f152aa33646e4e3efc` |
| `execute` | 56 × 56 | 8146 | `7a89efebd73e1ba13869d0c3be4472e3ba1e310d7c1e3b4e29ae05b863954f46` |
| `whirlwind` | 56 × 56 | 8249 | `77146dd1f180bcdf493ccb38cfb2086bc9833a4a5cc0ae158fa1c2bf8ae209df` |

## Readiness and human gate

Editable JSON, CSS, four original SVGs, original icon JPEGs, provenance, four declared normal preview configurations, and native hero/contact-sheet evidence are preserved. The hero is suitable for a website preview; a public catalog/website entry has not been created, and the package intentionally contains no review PNGs. README accurately describes suggested physical-button artwork, manual in-game ability assignment, customizable assets, no macros and no automatic class/talent detection.

`reviews/human-approval.json` was absent at QA time. No agent approval was created. The parent must create a **pending** record for the exact final sheet and package hash above before presenting them for human review. The final workflow’s approval-record step therefore remains pending; technical QA is passed. No publish, import, apply, staging, commit or push was performed.
