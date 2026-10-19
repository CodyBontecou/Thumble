# Fury Forge — art direction

## Contract and concept

**Concept:** an original paired forge instrument, with brushed steel plates and restrained crimson heat seams framing authentic WoW ability artwork; the emotional target is weight, readiness, and controlled aggression.

Use canonical `wow-forever-v1`, revision 1, template `wowForever`, inspected through `build/WoWForever/bin/thumble skin artboard show wow-forever-v1 --json`. It already exists in the catalog; no canonical artboard addition is required. Its landscape canvas is 874 × 402 and portrait canvas is 402 × 874. There are 18 gameplay controls (two analog sticks and sixteen physical gamepad buttons), plus the system control-bar reveal. Native controls retain exact geometry, output bindings, holds, accessibility, labels or icon semantics, and hit testing. The catalog presently marks most buttons `custom`, so use exact control identities or declared visual groups rather than assuming `primaryAction` roles exist.

The earlier Lux workspace demonstrates supported raster ability `icon` source assets beside original editable SVG canvas artwork. Fury should use the committed canonical contract rather than inherit Lux's unrelated captured layout, mouse bindings, or optical materials.

## Originality and asset boundary

Author the forge shell, panel cuts, seams, brush texture, and framing as original editable SVG. Do not copy Xbox or PlayStation shells, Blizzard UI borders, faction crests, Warcraft wordmarks, character portraits, or a reference skin's composition. Avoid horns, skulls, chains, fantasy armor silhouettes, and ornamental axe emblems: the actual spell images carry the game identity.

The user's explicit request authorizes real in-game icons and overrides the skill's game-art prohibition **only for those icons**. Preserve icon artwork without repainting or replacing it with generated symbols. Record each source URL, filename, spell association, SHA-256, and Blizzard attribution. Official shared WoW CDN assets may be used; do not describe them as independently verified Forever-client pixels. Exact Forever export/screenshot comparison remains unavailable. Spell names and examples are customization guidance, not a promise that physical buttons cast those spells.

## Orientation-specific hierarchy

**Landscape:** use a low continuous backing plate with two intentionally unequal inset stations. The left station gathers movement at (120,225) and the directional group at (285,275). The right station pairs camera at (490,280) with the ability group at (730,255). Bridge the gap with a narrow steel spine; leave the center visually quiet. Shoulder capsules at x≈201/673 and y≈68/125 sit in shallow horizontal mounting rails. Keep View/Menu near y≈113 and system reveal near y≈46 clear of decoration. L3/R3 near (120,354)/(603,354) read as small mechanical auxiliary plates. The ability cluster is the strongest focal point; the movement well is second.

**Portrait:** recompose as two vertical steel rails with a deliberately quiet center, not a stretched landscape shell. Shoulder rows occupy y≈149/219, utilities y≈332, and stick-click controls y≈420. Paired movement/camera wells center at (95,570)/(305,570); directional/ability groups center at (95,750)/(305,750). Use a restrained original central seam to connect the upper rails and lower stations, with no decorative mascot filling the middle. Portrait's smaller native sticks and controls require less texture and simpler borders. Keep top system reveal and bottom safe area readable.

Safe areas: landscape top/bottom 3.5%, leading/trailing 4.5%; portrait top 5.5%, bottom 4.5%, leading/trailing 2.5%. Background may bleed; focal decoration and legends may not. Derive artwork frame dimensions from the emitted contract rather than the template's unscaled parameter comments.

## Palette and light/dark intent

| Token | Dark | Light | Purpose |
|---|---|---|---|
| ground | `#111316` | `#E3DFD8` | Quiet charcoal / warm workshop ground |
| forged-shell | `#252A30` | `#C4C7C9` | Main neutral steel body |
| well | `#171B20` | `#9CA2A8` | Recessed grouping surface |
| machined-edge | `#65717D` | `#59636E` | Thin cool bevel boundary |
| polished-edge | `#BFC7CD` | `#F4F5F5` | Sparing top-left highlight |
| rage | `#DC4349` | `#A72532` | Crimson seams and activation |
| legend | `#F0ECE6` | `#20252B` | Native non-spell labels |
| muted-legend | `#A9ADB3` | `#4A5058` | Disabled/secondary legend |

These are starting tokens; verify rendered contrast. Target ≥4.5:1 for native legends and ≥3:1 for large state edges. Full-color authentic icons need a neutral near-black recessed matte and enough surrounding contrast to distinguish the image boundary. Light appearance gets brighter plate faces and dark machining lines, not a white opacity wash over dark artwork.

## Material stack and icon treatment

Five depth tiers: ground → shell → recessed group wells → native control bevels → native icon/legend. A single upper-left light produces 1–2 px highlight edges, a slightly darker lower-right cut, and a compact downward shadow. Use native state materials for control edges, never baked pressed feedback in SVG. Landscape seams may be 2 px; portrait seams 1–1.5 px. Brush strokes are sparse, 1 px or thinner, with 12–20 px spacing; they may not cross icon faces. No bloom, glossy gradients over spell icons, oversized rivets, or repeated noisy bitmap grain.

Place authentic square icons as native icon assets inside action controls. Keep 2–4 px clear interior margin at native 1×; preserve their aspect ratio and full image content. Do not enlarge source pixels beyond what native resolution can support or manufacture high-resolution details. Buttons should show ability images without overlaying spell names or gamepad letters; retain descriptive accessibility names and document physical identity in setup metadata. Movement, camera, modifiers, menus, and directional inputs may use clear native utility marks where imagery would misrepresent behavior.

## Suggested Fury icon set and binding semantics

Primary four-image face group: **Bloodthirst, Whirlwind, Execute, Cleave**. Optional secondary kit images, where explicitly configured by the user: **Death Wish, Charge, Berserker Rage, Recklessness**. Do not add Raging Blows as an attack; it is a passive talent in the researched Forever Warrior changes. The exact available abilities and talent choices must be checked against the character's build.

A suggested visual arrangement is X=Bloodthirst, Y=Whirlwind, B=Execute, A=Cleave, but these are presentation labels for a user-arranged game action bar. Preserve native A/X/B/Y output routing; do not invent spell-cast macros. Keep LT/RT/LB/RB held modifier identities explicit by default. Optional secondary ability icons should not silently replace targeting, menus, or modifier legends; ship them as easily replaceable source assets or use them only in a profile whose game configuration is documented. No automatic class/spec synchronization is implied.

## State behavior

- **Normal:** steel edge and neutral well remain stable; icons stay full color and unfiltered.
- **Pressed:** native darker face and reduced raised-edge shadow, with a crisp crimson inner edge; no frame shift or icon displacement. Held shoulders remain visibly pressed while held.
- **Active:** sustained crimson outer boundary with slightly brighter steel edge, clearly distinct from the depressed inner-edge pressed state. Treat this as UI control state, not live rage/cooldown telemetry.
- **Disabled:** flatter neutral face, subdued border, reduced icon opacity where the native renderer supports it, and readable grouping; avoid generic global opacity that makes the whole design disappear.

Analog pucks stay neutral machined steel with a small crimson center. Their native motion and press state remain unobscured. The control-bar reveal and menus use native utility/system surfaces and retain independent feedback.

## Acceptance criteria for critique and QA

1. Both orientations match `wow-forever-v1` revision 1 with every gameplay and system control rendered; decoration never covers native hit surfaces or moves any center, size, axis, or held binding.
2. At 1× and contact-sheet thumbnail size, the ability group is the first focal point, movement/camera the second, and no seam, texture, or header is brighter than the ability perimeter.
3. Portrait is separately composed around its upper shoulders and lower paired stations; neither orientation shows shell clipping, safe-area intrusion by focal elements, or accidental decoration tangencies within 4 px of native control borders.
4. Every supplied spell image is a real traced-source WoW raster asset with URL, hash, attribution, and shared-asset authenticity caveat; no generated spell icon or Raging Blows action button is present.
5. Icons remain square, uncropped, legible at native 1×, without letter/name overlay; non-spell legends meet ≥4.5:1 preferred contrast and large state boundaries ≥3:1 in both appearances.
6. Normal, pressed, active, and disabled remain visibly distinct on every material in both appearances, with no icon jump or control geometry drift; held modifiers retain their physical identities and usable hold feedback.
7. Original SVG framing, named palette/material/semantic controls, and replaceable icon assets remain editable; package mappings emit only the existing native gamepad inputs, never direct spell-cast assumptions.
8. Final evidence includes all 16 orientation/scheme/state native panels, two independent critique passes ending `visual-pass`, byte-identical compilation twice, both strict validators with no warnings, QA `qa-pass`, and pending human approval tied to exact contact sheet and package hash.
