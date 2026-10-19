# Fury Forge — independent visual critique 1

Verdict: **revise**. No blockers; one major geometry/craft finding requires a bounded artwork correction before a visual pass. This is not approval or a publication decision.

## Evidence and scope

Reviewed the exact native `contact-sheet-1.png` (2176 × 1714, all sixteen orientation/appearance/state panels) and `landscape-dark-1.png` (1748 × 804). Also inspected an enlarged, read-only crop of the pressed/active dark landscape panels. Read art direction, designer notes, and the quality bar. Source inspection was limited to explaining visible artwork/state behavior. No geometry, binding, package, or core source was edited.

All eighteen gameplay controls and the separate system reveal are visible. Face controls show four image-only spell assets; utility controls retain physical legends. The review evaluates authentic shared WoW imagery with the documented Forever-client verification caveat, not a claimed client-exact extraction.

## Pass 1 — composition

The ability group establishes the strongest color focus in both appearances; movement/camera remain the second tier. Landscape groups movement and direction on the left, camera and abilities on the right. Portrait is separately authored as upper modifier rails and lower paired stations, rather than stretched. The quiet portrait middle is intentional and consistent with the acceptance criteria. Control-center placement, orientation adaptation, visible native controls, and outer safe-area treatment are satisfactory.

### Finding 1 — major: near-tangent at the top of the landscape ability well

- **Affected panels:** all four light landscape and all four dark landscape states; especially visible in the 2× dark hero.
- **Visible evidence:** the top of the circular ability grouping almost touches the horizontal inner steel-plate edge immediately above Whirlwind. These are separate machining contours, but at their closest point they form a cramped double seam rather than a clear material gap. This violates the explicit 4 px decoration-clearance criterion.
- **Likely cause:** the artwork circle is centered at (730,255), radius 91, giving a top at y=164; the inner plate's horizontal top runs at y=163 across that position. That is only 1 native pixel of separation. This is artwork, not a required native control center.
- **Concrete correction:** reroute the horizontal inset contour locally above the ability grouping, or remove its portion behind that grouping. Keep every native control center/frame unchanged. Require at least 4 native pixels between distinct exposed machining contours, and ensure the crimson tick remains deliberately attached to its circular well rather than almost touching another line. Re-render both landscape appearances and all states; the top of the ability circle should read as one clean well edge at 1×.

## Pass 2 — material and craft

Neutral steel, dark recessed stations, sparse brush marks, and crimson seams form a coherent authored instrument. The continuous asymmetric plate is not a console-shell replica. Native top-left highlights and compact lower shadows support the raised control tier; light mode uses brighter plate faces and dark cuts, rather than washing out dark artwork. Source pixel scale is suitable for these small buttons. No obvious compression artifacts, text overlays on spell icons, missing icon pixels, or shell clipping are visible.

### Finding 2 — minor: portrait light spine has slightly disproportionate weight

- **Affected panels:** four portrait light panels.
- **Visible evidence:** the long center separator between lower rails is a relatively solid gray bar, while neighboring inset details are fine outlines. It becomes a competing straight vertical accent in the otherwise quiet middle.
- **Likely cause:** a filled spine with more visual mass than the portrait machining grammar.
- **Concrete correction:** optional refinement after the major fix: reduce the spine's visual width or contrast by approximately one third, without moving any control. At contact-sheet size, it should register as a connector only after the icon group and sticks. This is a minor balance refinement, not a request to fill the center with ornament.

## Pass 3 — interaction

Normal, pressed, active, and disabled are meaningfully distinct in both schemes: dark pressed utility faces recess and darken; active faces retain their brighter raised material and thicker crimson perimeter; disabled removes crimson emphasis and suppresses icons while keeping groups recognizable. Sticks distinguish depressed center feedback from sustained red-ring feedback. No authored positional drift is visible; the small native pressed-size response is a renderer behavior, not a skin transform defect. Held modifiers remain explicitly identified and receive consistent state feedback. The image-only faces retain physical routing/accessibility semantics according to the supplied notes.

### Finding 3 — minor: image-face pressed/active distinction depends mainly on edge weight

- **Affected panels:** pressed versus active face buttons in all four orientation/appearance combinations, most apparent in portrait thumbnails.
- **Visible evidence:** the bright image fills dominate, leaving less exposed background than utility buttons. The different crimson widths/shadows remain discernible but subtler than the dark/light face change on utilities.
- **Likely cause:** intentionally unchanged full-color imagery covers most of the semantic face material.
- **Concrete correction:** optional: strengthen the pressed inner-edge/active outer-edge distinction within existing frames, while preserving the entire icon and at least its current clear margin. Verify that each image button can be recognized as pressed versus active in a side-by-side 1× crop without relying on the panel caption. Existing states are usable; this is not a major finding.

## Originality and authenticity check

Original steel framing, asymmetry, plate cuts, neutral/crimson material grammar, and portrait rails are visually distinct. No manufacturer badge, Warcraft wordmark, faction crest, hardware trade dress, character portrait, or borrowed game-UI border is visible. The four supplied spell images are deliberately reused under the user's explicit real-icon request. That narrow exception does not authorize unrelated borrowed artwork. The documented shared-Blizzard-asset versus exact-Forever-client distinction is sufficient for this visual review and is not a visual blocker.

## Acceptance disposition

Criteria 1, 2, 4, 5 (visual legibility; numerical contrast remains QA), 6, and 7 are visually satisfied. Criterion 3 requires Finding 1's contour-clearance repair. Criterion 8 remains the subsequent second critique and deterministic/strict QA stages. No agent or report grants human approval.

Highest priorities: (1) eliminate the 1 px landscape ability-well tangent; (2) optionally lighten the portrait light center spine; (3) optionally strengthen face-image pressed/active perimeter distinction. Only priority 1 is required for the next visual pass.
