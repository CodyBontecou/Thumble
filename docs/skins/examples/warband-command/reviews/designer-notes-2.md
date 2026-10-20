# Warband Command — designer pass 2

Parent requested concrete craft corrections before independent critique: make the ledger convey actual ability information and clear duplicate stick labels from the puck rims.

The four passive reference banks now contain actual 16pt ability miniatures in row order A, X / B, Y, matching the face assignments in `sources/example-ability-mapping.json`. Editable SVG owns the panel, headings, and frame. `sources/compose-ledger.py` reproducibly composes byte-preserved attributed icons into transparent full-canvas PNG underlays. Each composition source PNG is declared as canvas_artwork with the same canonical anchor as its SVG. Eight anchors total remain within the compiler budget. PNGs decorate only; all native touch targets, states, labels, bindings, and accessibility identities remain unchanged. The ledger is reference scale and not a set of extra hit targets.

Suppressed duplicate native stick display legends, retaining original external SVG MOVE/CAMERA labels. Camera label moved below its native stick so it no longer crowds the bank reference. Shortened landscape subheading to WARRIOR for spacing beside LT.

No app source changes. Eight-icon provenance and example mappings remain in designer-notes-1 and sources/example-ability-mapping.json. Changes affect appearance only, not game bar configuration or live spell data.

Strict package validation: valid with no warnings. Strict quality: 100/100, zero errors, zero warnings. Final independent visual review for this candidate should use contact-sheet-2.png, the full 64-panel native bank/orientation/scheme/state matrix. Individual landscape-dark bank renders carry suffix -2. Sheet 1 preserves the first candidate's symbolic ledger and is superseded for review; it has not been overwritten. Human approval remains pending.
