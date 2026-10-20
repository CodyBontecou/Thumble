# Warband Command — art direction, revision 3

## Concept

A warrior's field command board: jewel-like ability tiles sit in small warm-metal sockets, with quiet thumb instruments and open space between the playable clusters. The emotional target is immediate command of a character, rather than admiration of a virtual plastic controller.

This is a configured Warrior showcase, not a claim of live WoW spell synchronization. The eight existing, attributed Blizzard icon assets may be reused under the user's explicit request for ability icons; retain their provenance without alteration. All framing, typography, ornament and SVG composition must be newly authored. Do not reuse Fury Forge's shell or its artwork. Do not trace the reference hotbars, reproduce Blizzard HUD borders, copy runes, logos, console silhouettes or proprietary glyph artwork. Generic text A/B/X/Y, LT and RT remains ordinary input identification.

## Revision 3 scope — fixed appearance, cleaner preview, truthful icon fidelity

This revision freezes the current candidate's colors, materials, spacing, geometry, input bindings, native action-set mapping, icon subjects, WARBAND/WARRIOR identity and passive-ledger removal. Do not reinterpret the original palette table or geometry descriptions as permission to change the actual current source. Preserve revision 2 in `art-direction-2.md`.

The user approved three specific changes only:

1. A clean app preview that hides navigation, sidebar and guide overlays. The parent owns the app/CLI implementation and parity. Editing retains the controls and guides it needs. This is presentation behavior, not a controller-layout change.
2. Suppression of secondary binding glyphs in the clean preview, while retaining them during editing and retaining accessibility/input metadata. Primary functional held labels and ability artwork remain. Do not remove native controls, alter their binding, or bake preview-only suppression into the editable source artwork.
3. Sharper assets for the **same eight existing ability textures**. Only replace an asset when a trusted original has genuinely more source detail, or correct an identified rendering/sampling defect. Do not enlarge a 56×56 image and call it higher resolution. Do not apply generative enhancement, sharpening filters, new crops, repainted details, or a different modern icon subject. Keep existing tile scale, frame, fit, corner radius and image placement fixed.

The top bar means app-owned preview chrome. Existing skin branding remains. No bank-reference ledger is reinstated.

### Asset-source evidence and fallback

The existing official Blizzard CDN `icons/56/spell_nature_bloodlust.jpg` resolves successfully. On this investigation, the equivalent official `/112/` and `/256/` URLs returned HTTP 403; their availability must not be assumed. Larger numeric paths are hypotheses, not verified high-resolution assets. Record a successful response, decoded dimensions, URL, SHA-256 and an actual detail comparison before replacement. A larger canvas alone proves nothing: compare against interpolation of the old pixels and inspect the candidate at 1× and 2×, especially tiny contour/texture detail. If it matches an upscale, reject the claim.

The eight texture identities are `spell_nature_bloodlust`, `ability_whirlwind`, `inv_sword_48`, `ability_warrior_cleave`, `ability_warrior_charge`, `spell_shadow_deathpact`, `spell_nature_ancestralguardian`, and `ability_criticalstrike`. A trusted official game texture export is acceptable only if its provenance, original dimensions, texture identity and extra source detail can be verified. Do not require the user to supply installed game assets before completing the independent preview work. If no genuine higher-detail original is available, retain the honest 56×56 source and report that limit; fix any demonstrated native decode/rasterization downsampling instead, with before/after evidence. Better preview pixel density is a rendering improvement, not new asset resolution.

Parent owns clean preview source changes. The skin designer owns only verified icon-source replacements, provenance updates and native evidence. No replacement is required merely to produce a changed file.

## Geometry contract and hierarchy

Target `wow-forever-v1`, revision 1. Inspected through the CLI: landscape 874×402, safe insets top/bottom 3.5%, leading/trailing 4.5%; portrait 402×874, safe insets top 5.5%, bottom 4.5%, horizontal 2.5%. Skin styling cannot move native touch geometry. Retain all native identities and binding behavior. No application or custom-profile geometry change is required for this first candidate.

**Landscape.** Avoid a continuous hardware shell. Compose three quiet graphic islands: movement at left (native stick center approximately 120,225), the central camera instrument, and the main face-button diamond at right (45 px native tiles centered around x730, y255). The D-pad diamond at x285,y275 becomes the second icon-led action cluster, visually subordinate to the face cluster. Keep the camera stick centered near 490,280 independent from both clusters. LT/RT remain in their existing upper positions and gain clear hold labels through native legends. LB/RB and L3/R3 remain utility/target inputs, styled as text-led capsules, with their exact game meanings left configurable.

Keep the former ledger rectangle **x365–625, y143–220** as open ground, with no mini-panels, BASE/LT/RT/LT+RT reference headings, icon miniatures or substitute ornament. Retain the existing WARBAND/WARRIOR identity. The parent’s clean native-renderer presentation omits app-owned chrome. View/Menu and the system toggle remain native controls with clear functional legends.

**Portrait.** Recompose as a vertical command instrument using the existing native trigger controls, separate utility tier, thumbsticks and bottom action diamonds. Keep the former ledger rectangle **x20–382, y248–305** as open ground; remove its panels, symbols and heading. Retain the existing WARBAND/WARRIOR identity and decorative header artwork; app-owned chrome is excluded only from the clean presentation. The two action diamonds remain at the bottom, native tiles approximately 42 px, with their sockets and labels composed around those exact frames. Preserve the large middle negative space; do not stretch the landscape artwork or add replacement branding. The system toggle centered at x201,y100 and all native frames remain intact.

## Palette and material rules

| Token | Dark | Light | Purpose |
|---|---|---|---|
| ground | #11171B | #E8E2D5 | Calm, opaque field |
| panel | #1C252B | #F5F0E5 | Shallow group backing |
| well | #0C1115 | #C9C5BA | Physical recess beneath actionable tiles |
| ink | #F1E8D8 | #282B29 | Primary readable legends |
| muted-ink | #B8B5A9 | #55594F | Secondary labels |
| brass | #B8975C | #715323 | Warm framing and Base identity |
| LT | #91B7B9 | #365F68 | Cool left-bank accent |
| RT | #D7A16E | #83512B | Warm right-bank accent |
| both | #B6A7D4 | #655279 | Combined-bank accent |
| pressure | #E2C581 | #624415 | Native engaged feedback |

Target at least 4.5:1 for all meaningful legends and at least 3:1 for large boundaries/marks. Verify actual derived colors, rather than assuming this table guarantees contrast. Light appearance must read as matte parchment-metal instrumentation, not dark UI with an inverted ground.

Use five depth tiers only: ground → shallow group panel → dark sockets → native tile/puck → native legend. Light comes consistently from upper left. Socket upper rims are recessed/shaded; native tile upper rims catch a narrow highlight. Keep borders 1–1.5 px, restrained 2–3 px drop shadows, 5–7 px tile corner radii. A paired short rule or small notched corner can mark each group; avoid repeated rivets, circuit traces, giant concentric rings, chrome gradients and glow. Texture, if any, is sparse authored 1 px hatching below 5% contrast, away from icons. Ability artwork supplies the richness.

## Banks, legends and states

Author real `:root[action-set="base"|"left-trigger"|"right-trigger"|"both-triggers"]` variants. Both triggers is independent, not an overlap of the LT and RT selectors. Change prominent ability icons and native tile borders/legends per bank. No passive bank ledger or bank-reference miniatures appear in any bank. Native held-modifier labels and changing actionable tiles provide the bank context. Retain existing input identities in editing. The clean preview suppresses secondary binding glyphs through presentation policy while retaining primary functional held labels and native accessibility metadata; do not add substitute SVG tags. Do not label a spell as live data.

Define and document an explicit example mapping using bloodthirst, whirlwind, execute, cleave, charge, death-wish, berserker-rage and recklessness. Repeated images across banks are acceptable when openly described as example assignments; do not invent additional sourced assets or claim that the template configures WoW's actual action bars. Target/utility labels must retain native input identity and cannot promise party-target macros.

Normal: readable artwork and a thin socket edge. Pressed: inset shadow plus a 2 px warm pressure edge, no scaling or label displacement. Active: a continuous 3 px bank-colored boundary, clearly distinct from the inset pressed state. Disabled: flatter, muted native tile and dimmer image, with input and grouping still readable. Joystick pressed/active uses puck and ring contrast with the same hierarchy. All feedback is native CSS/material state; SVG remains passive.

## Acceptance criteria

1. All 18 native controls plus the system toggle retain canonical frames and inputs; graphic sockets align within 2 px at 1× in both orientations.
2. All eight action tiles show real attributed Warrior ability art; each remains identifiable at the existing canonical size, with input identity retained in editing and accessibility metadata. Clean-preview secondary binding glyphs are suppressed.
3. No bank-reference panel, miniature, slot map or `BANK REFERENCE` label appears in any orientation, appearance or action set. Former ledger areas show uninterrupted ground. Existing WARBAND/WARRIOR identity, native held-modifier labels, View/Menu and system-toggle functionality remain intact. The clean presentation excludes app-owned offline toolbar chrome.
4. Four native action-set renders demonstrate at least two distinct icon assignments and distinct bank accents; releasing modifiers conceptually returns to the documented Base mapping, with no binding change.
5. Native normal, pressed, active and disabled states are distinguishable side by side in both light and dark; no state shifts control geometry or text position.
6. Meaningful native legends meet 4.5:1 contrast; no clipped tiles, seams, stretched SVG, raster blurring or decorative tangencies within 4 px of control edges appear in portrait or landscape.
7. Strict compilation and quality validation pass, native contact sheets cover both orientations, appearances, all states and all four action sets, and deterministic recompilation produces the same package hash.
8. Preserve source SVG/JSON/CSS, original icon provenance, versioned critique sheets, and pending human approval. Freeze geometry, spacing, colors, materials, bindings and bank mapping. Every purported higher-resolution replacement must include decoded dimensions and proof of genuine added source detail; an upscale is not accepted. Do not publish, edit the website catalog, or claim approval.

## Principal risks

A high-resolution URL may fail or serve an interpolated image. Do not claim sharper source assets from file dimensions alone. Preview-only glyph suppression must not remove editing affordances or accessibility descriptions, and chrome hiding must not change the controller layout.


Do not accidentally remove native triggers or functional labels while removing ledger elements. The app-owned toolbar is separate from skin artwork and is omitted only in the clean presentation; no app runtime change is required. Ability images can obscure native labels unless input tags are deliberately placed. Existing icon provenance identifies shared Blizzard art, not verified Forever beta textures. A highly ornamented frame will immediately recreate the rejected generic-shell problem.
