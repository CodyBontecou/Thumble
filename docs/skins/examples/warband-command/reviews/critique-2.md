# Warband Command — independent visual critique 2

**Verdict: revise.** Exact evidence: frozen `contact-sheet-3.png` (64 panels), `cluster-states-dark-3.png`, `cluster-states-light-3.png`, `portrait-dark-base-3.png`, and `landscape-dark-both-triggers-3.png`. I inspected the full matrix in eight regional crops rather than relying on the reduced full-sheet thumbnail. Source was read solely to identify the cause of the remaining visible defect; no package or design source was edited.

## Pass 1 — composition

All four banks remain fully visible without overlap in landscape and portrait. The action clusters remain the focal points, with utility capsules and thumb instruments separate. Portrait remains independently composed. Input tags around the playable diamonds stay fixed and unambiguous through all action sets and states.

**C1 from critique 1 is resolved.** Portrait's individual A, X, B and Y letters now sit beside their corresponding 16 px reference icons in all four panels. The Base green axe is explicitly A; the same correspondence survives every bank and both appearances. Neither the reference artwork nor the input key overlaps neighboring controls.

**C2 from critique 1 is resolved.** LT-only displays `LT · HELD`, RT-only displays `RT · HELD`, and both-modifier renders display both held legends. Base has both `HOLD` instructions. Capsule text remains centered without clipping. A bank can now be identified without relying on its accent color.

## Pass 2 — material and craft

The reduced icon scale exposes a deliberate, continuous native perimeter. Original ability detail remains recognizable, and the sparse frame system remains consistent between the pale and dark treatments. No new raster seams, tile clipping, shifted reference panels, or stretched composition appeared in the 64-panel matrix.

### C4 — major: native stick legends collide with the inner ring

- **Affected panels:** both sticks throughout all 64 panels. Clearest in dark landscape normal/active and full-size `landscape-dark-both-triggers-3.png`; the same collision occurs in `portrait-dark-base-3.png`.
- **Visible evidence:** `Move` and `Look` now sit on the lower arc of the inner stick ring. The gold line crosses the lower portion of the letters rather than clearing them. For example, the full-size landscape both-trigger image shows the Look word intersecting the ring near image y620; portrait shows the same line crossing beneath/through the two stick words near image y1180. The wording is decipherable, but these repeated line/text tangencies visibly disrupt the otherwise clean instruments. Sheet 2's external captions did not have this collision.
- **Likely cause:** the external SVG captions were removed and native legends restored. Native legend positioning is fixed near the lower part of the joystick while the configured native ring continues through that position. Reducing font size to 10 px did not produce separation.
- **Concrete correction:** separate visible text from the ring while preserving native identities and canonical hit frames. Either suppress only the displayed native legend and restore one external caption per stick with at least 4 px clear space from all rings, or eliminate the intersecting inner ring and retain distinct native knob/outer-edge state feedback. Do not simply shrink the text again. Both canonical native previews and the live app must show one readable movement/camera label each, with no line crossing any glyph, no duplicated captions, and at least 4 px of visual clearance. The designer notes that live-app label placement differs; that requires checking both render paths rather than waiving the frozen-sheet defect.

## Pass 3 — interaction and state

**C3 from critique 1 is resolved.** In the dark close comparison, pressed uses the thin high-contrast ivory perimeter and inset treatment; active has a broad continuous brass frame. In the pale comparison, pressed has a dark inset rim, while active exposes the broader warm frame. Both remain distinct from the thin normal edge. The exposed border is also visible in the contact-sheet regional crops, unlike sheet 2. Artwork and input tag centers do not move. All four bank colors follow the same state treatment. Disabled remains recognizably dimmer while grouping and input letters remain readable.

Utility buttons retain darkened pressed faces, stronger active outlines and reduced disabled emphasis. Sticks retain a distinct puck/ring progression. C4 is a craft/legibility collision, not an objection to their state distinction.

## Originality / trade-dress check

No change to the first review's originality assessment: the sparse authored framing, ledger, input-letter system and palette remain distinct from console hardware or Blizzard HUD framing. The existing eight Blizzard ability assets remain the explicitly authorized attributed exception. No new sourced artwork or proprietary glyph drawing was introduced.

## Disposition

There are no remaining issues from critique 1. C4 is the single unresolved major and blocks `visual-pass` on the exact frozen native evidence. Resolve the stick line/text collision, retain sheet 3 and this report, and submit the next immutable full matrix for a focused verification. Strict QA and exact-sheet human approval remain separate requirements.

**Highest priorities:** (1) clear both stick legends from the inner ring in canonical previews; (2) verify the correction also yields one readable label in the live app; (3) retain the now-distinct ability states and labeled bank references unchanged.
