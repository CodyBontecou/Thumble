# Warband Command — art direction

## Concept

A warrior's field command board: jewel-like ability tiles sit in small warm-metal sockets, with an always-visible four-bank reference ledger and quiet thumb instruments. The emotional target is immediate command of a character, rather than admiration of a virtual plastic controller.

This is a configured Warrior showcase, not a claim of live WoW spell synchronization. The eight existing, attributed Blizzard icon assets may be reused under the user's explicit request for ability icons; retain their provenance without alteration. All framing, typography, ornament and SVG composition must be newly authored. Do not reuse Fury Forge's shell or its artwork. Do not trace the reference hotbars, reproduce Blizzard HUD borders, copy runes, logos, console silhouettes or proprietary glyph artwork. Generic text A/B/X/Y, LT and RT remains ordinary input identification.

## Geometry contract and hierarchy

Target `wow-forever-v1`, revision 1. Inspected through the CLI: landscape 874×402, safe insets top/bottom 3.5%, leading/trailing 4.5%; portrait 402×874, safe insets top 5.5%, bottom 4.5%, horizontal 2.5%. Skin styling cannot move native touch geometry. Retain all native identities and binding behavior. No application or custom-profile geometry change is required for this first candidate.

**Landscape.** Avoid a continuous hardware shell. Compose three quiet graphic islands: movement at left (native stick center approximately 120,225), a narrow central command ledger, and the main face-button diamond at right (45 px native tiles centered around x730, y255). The D-pad diamond at x285,y275 becomes the second icon-led action cluster, visually subordinate to the face cluster. Keep the camera stick centered near 490,280 independent from both clusters. LT/RT remain in their existing upper positions and gain clear hold labels through native legends. LB/RB and L3/R3 remain utility/target inputs, styled as text-led capsules, with their exact game meanings left configurable.

Place the passive bank ledger entirely in the free rectangle **x365–625, y143–220**: four equal mini-panels, headings BASE / LT / RT / LT+RT, each with a compact two-by-two icon-position diagram or original symbolic slot marks, plus a tiny `BANK REFERENCE` label. Aim for 16–18 px reference icons or marks and 9–10 px headings. Do not crowd View/Menu at y96–129, the camera starting y236, or face Y starting x708,y180. This ledger is orientation-specific SVG decoration, not extra touch buttons. Active native tiles and their legends remain the authoritative actionable bank display. If raster image embedding is unsupported by the safe SVG path, use original colored slot diagrams in the SVG and keep real ability images in native tiles; never fake interactive controls in artwork.

**Portrait.** Recompose as a vertical command instrument: compact title above the existing top trigger controls; a four-panel bank ledger across **x20–382, y248–305**, below LB/RB and above View/Menu. Keep L3/R3 and the thumbsticks as a separate navigation tier. The two action diamonds remain at the bottom, native tiles approximately 42 px, with their sockets and labels composed around those exact frames. Use the large middle negative space to breathe, not for a stretched landscape shell or oversized branding. No ornament should intersect the system toggle centered at x201,y100 or any native frame.

## Palette and material rules

| Token | Dark | Light | Purpose |
|---|---|---|---|
| ground | #11171B | #E8E2D5 | Calm, opaque field |
| panel | #1C252B | #F5F0E5 | Ledger and shallow group backing |
| well | #0C1115 | #C9C5BA | Physical recess beneath actionable tiles |
| ink | #F1E8D8 | #282B29 | Primary readable legends |
| muted-ink | #B8B5A9 | #55594F | Secondary labels |
| brass | #B8975C | #715323 | Warm framing and Base identity |
| LT | #91B7B9 | #365F68 | Cool left-bank accent |
| RT | #D7A16E | #83512B | Warm right-bank accent |
| both | #B6A7D4 | #655279 | Combined-bank accent |
| pressure | #E2C581 | #624415 | Native engaged feedback |

Target at least 4.5:1 for all meaningful legends and at least 3:1 for large boundaries/marks. Verify actual derived colors, rather than assuming this table guarantees contrast. Light appearance must read as matte parchment-metal instrumentation, not dark UI with an inverted ground.

Use five depth tiers only: ground → ledger/group panel → dark sockets → native tile/puck → native legend. Light comes consistently from upper left. Socket upper rims are recessed/shaded; native tile upper rims catch a narrow highlight. Keep borders 1–1.5 px, restrained 2–3 px drop shadows, 5–7 px tile corner radii. A paired short rule or small notched corner can mark each group; avoid repeated rivets, circuit traces, giant concentric rings, chrome gradients and glow. Texture, if any, is sparse authored 1 px hatching below 5% contrast, away from icons. Ability artwork supplies the richness.

## Banks, legends and states

Author real `:root[action-set="base"|"left-trigger"|"right-trigger"|"both-triggers"]` variants. Both triggers is independent, not an overlap of the LT and RT selectors. Change prominent ability icons and native tile borders/legends per bank. The passive four-bank ledger stays visible in every bank. Preserve input glyphs through small native legends wherever the renderer permits; if native tile image treatment precludes readable overlays, put small original input tags immediately adjacent to those exact native frames in the SVG. Do not label a spell as live data.

Define and document an explicit example mapping using bloodthirst, whirlwind, execute, cleave, charge, death-wish, berserker-rage and recklessness. Repeated images across banks are acceptable when openly described as example assignments; do not invent additional sourced assets or claim that the template configures WoW's actual action bars. Target/utility labels must retain native input identity and cannot promise party-target macros.

Normal: readable artwork and a thin socket edge. Pressed: inset shadow plus a 2 px warm pressure edge, no scaling or label displacement. Active: a continuous 3 px bank-colored boundary, clearly distinct from the inset pressed state. Disabled: flatter, muted native tile and dimmer image, with input and grouping still readable. Joystick pressed/active uses puck and ring contrast with the same hierarchy. All feedback is native CSS/material state; SVG remains passive.

## Acceptance criteria

1. All 18 native controls plus the system toggle retain canonical frames and inputs; graphic sockets align within 2 px at 1× in both orientations.
2. All eight action tiles show real attributed Warrior ability art; each remains identifiable at the canonical 42–45 px size and has an unambiguous input identity.
3. BASE, LT, RT and LT+RT reference panels remain fully visible in every bank, with no native control overlap and at least 8 px of separation from neighboring native frames.
4. Four native action-set renders demonstrate at least two distinct icon assignments and distinct bank accents; releasing modifiers conceptually returns to the documented Base mapping, with no binding change.
5. Native normal, pressed, active and disabled states are distinguishable side by side in both light and dark; no state shifts control geometry or text position.
6. Meaningful native legends meet 4.5:1 contrast; no clipped tiles, seams, stretched SVG, raster blurring or decorative tangencies within 4 px of control edges appear in portrait or landscape.
7. Strict compilation and quality validation pass, native contact sheets cover both orientations, appearances, all states and all four action sets, and deterministic recompilation produces the same package hash.
8. Preserve source SVG/JSON/CSS, original icon provenance, versioned critique sheets, and pending human approval. Do not publish, edit the website catalog, or claim approval.

## Principal risks

The canonical landscape layout limits the bank ledger to reference-scale marks; it cannot show four full-size playable hotbars without a separate geometry/profile change. Ability images can obscure native labels unless input tags are deliberately placed. Small miniatures must remain clearly passive. Existing icon provenance identifies shared Blizzard art, not verified Forever beta textures. A highly ornamented frame will immediately recreate the rejected generic-shell problem.
