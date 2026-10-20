# Everyday Play — art direction

## Concept and emotional target

A quiet, well-made play instrument: soft mineral keycaps settle into individually machined sockets, with an asymmetric pair of muted accent colors giving the action cluster a friendly identity. It should feel ready to pick up every day: precise, tactile and relaxed.

This is a generic controller, with no spell imagery, action banks, reference charts or fantasy materials. Match Warband Command's level of finish rather than its vocabulary. Originality lives in the interrupted group contours, inset socket construction, restrained sea-glass/coral accents and sparse typography. Do not reuse Warband SVGs, gold edges, runes or faction-like identity. Do not trace hardware, use manufacturer marks, copy vent patterns or shell outlines, or restore the familiar four-color console palette. ABXY and arrows remain ordinary native input labels, in the canonical arrangement.

## Canonical contract and source boundary

Choose **`classic-16-bit-v1`, revision 2**, identifier `com.thumble.everyday-play`, workspace `docs/skins/examples/everyday-play`. Inspected both it and `showcase-controller-v1`: both share the SNES template geometry and roles, but generated shoulder input UUIDs differ. The classic artboard names the actual generic controller contract, while showcase is a deterministic preview fixture. Use the classic artboard and preserve its own exact input identities and bindings; do not mix the two exports.

Landscape canvas is 874×402; portrait is 402×874. The contract contains twelve playable native buttons (D-pad four, face four, L/R, Select/Start) and the system toggle. Native frames, primary labels, hit targets and accessibility remain untouched. Direction is appearance only. No application code, new controls, bank layers, executable bindings or public-catalog changes are part of skin design.

Landscape safe insets: 3.5% vertical, 4.5% horizontal. Portrait safe insets: top 5.5%, bottom 4.5%, horizontal 2.5%. Canonical frames close to those boundaries are authoritative; do not move them to satisfy decoration. Clip no native control. Keep optional decoration inside the canvas, and omit a flourish where space is insufficient.

## Composition in each orientation

**Landscape:** retain the clear left movement / right action split. The D-pad native centers are approximately (149,149), (149,285), (68,217), (229,217); face centers are X (734,145), A (813,221), B (734,297), Y (655,221). Make those two clusters readable at thumbnail size using a shallow, irregular rounded-diamond backing, interrupted between directional axes, and small native-key sockets. The backing should visually connect the controls without implying a larger hit target. Do not draw a faux physical cross or add inactive control-like dots in the middle. No continuous gamepad shell or full-width pill.

The shoulder buttons occupy approximately (127–223,48–81) and (651–747,48–81): give them restrained 6–8 px rounded rail-like sockets, visually lighter than the primary groups. Select/Start sit low in the center near y316–343: treat them as an intentional pair with generous surrounding ground and compact native labels. Preserve the system toggle at x407–467,y24–68. The central negative space is deliberate. One quiet `EVERYDAY / PLAY` signature, preferably x350–524,y171–219, may anchor it; use two short lines or one tiny original offset-rectangle mark, never a status panel or verbose subhead. Keep all identity clearly subordinate to control legends.

**Portrait:** this canonical layout is recomposed/rotated, not the landscape layout squeezed: face controls occupy the upper cluster (center around x221,y140), D-pad the lower cluster (around x217,y725); R is upper-left around (64,175), L lower-left around (64,699); Start/Select form a right-hand vertical pair around x330,y376 and y498. The system toggle sits near (201,280). Author new portrait SVGs around these exact frames. Group backing must follow these two rotated clusters, preserving axis identities and their labels. Place the quiet signature in the open center-left band around x40–210,y392–450, clear of the utility pair. Do not rotate lettering with the layout or stretch landscape artwork. Existing arrows remain their actual canonical input labels; do not silently exchange them to make a conventional-looking D-pad.

## Palette: mineral, sea glass and soft coral

| Token | Dark | Light | Purpose |
|---|---|---|---|
| ground | #141C20 | #ECEEE8 | Opaque resting field |
| backing | #1C282C | #DDE3DC | Shallow group plane |
| socket | #0C1418 | #BBC7BF | Recessed socket floor |
| cap | #34464A | #F7F8F2 | Neutral native button face |
| cap-edge | #718A88 | #5D716A | Readable key boundary |
| ink | #F0F4E9 | #233831 | Functional legends |
| muted-ink | #B7C8BE | #4D6258 | Signature and secondary typography |
| sea-glass | #A8CEBF | #355F50 | Primary accent |
| coral | #D7AA96 | #80513F | Secondary accent |
| pressure | #D5E5C5 | #365E4B | Engaged edge |

These are the intended source tokens, subject only to small contrast corrections demonstrated by measurement. Do not use electric cyan, console purple/red/yellow/green or fantasy brass. Keep all face-button surfaces neutral; differentiate two action pairs with modest accent rim details or readable legend color, never four unrelated saturated fills. Proposed grouping: B/Y sea-glass, X/A coral. Native letters provide identification, so users need not rely on color.

Use ink on neutral cap for primary legends. Meaningful legends target 4.5:1 minimum across all states; large marks and interaction boundaries target at least 3:1 against adjacent surfaces. Muted signature text is optional and must remain legible rather than hairline gray. Light appearance has its own readable inset edge: do not simply invert the dark render.

## Materials, edge logic and type

Use exactly four physical depth tiers: ground → shallow group backing → individual recessed sockets → native keycaps/legends. Lighting is upper-left in both orientations. Native cap top/left edges catch a narrow highlight; bottom/right edges shade. Sockets reverse that logic. Canvas SVG can provide the static socket rim and restrained directional shadow; native CSS/material states must supply actual pressed/active feedback. Avoid duplicated halos when the native border sits above its socket.

Backing corners 14–22 px, native directional/button caps 10–12 px or genuinely round for face buttons, shoulder/utility radii following the native frame dimensions. Keep inset socket expansion about 5–7 px from a native key edge, with at least 4 px clear air before any unrelated decorative line. Key borders 1–1.5 px normal, shadows approximately 2 px down and 0–1 px lateral; shadow darkness must stay subordinate to the legend. Keep shadows within the canvas. Use no glass blur, broad glow, large vignette or generic noise overlay. One or two short parallel recessed strokes on group backing are permissible only if they clarify its material edge; prefer omission over fill.

Legends use a consistent native sans, semibold, approximately 15–17 px for face labels/arrows, 12–14 px shoulders and utilities. No tiny repeated labels under every button. Artwork contains identity and sockets only; native primary legends remain native. Do not add tiny binding glyphs, diagnostic guides, coordinate marks or fake status indicators to SVG.

## Native behavior in all four states

**Normal:** quiet neutral cap, fine rim highlight, stable edge and shallow outward shadow. **Pressed:** a clear inset shadow plus a 2 px pressure edge; flatten the cap highlight and slightly darken/recess the fill, keeping glyph contrast. **Active:** a continuous 3 px sea-glass/coral boundary plus a subtly lifted cap value; retain an outward shadow, so it differs from pressed. **Disabled:** remove shadow, flatten and desaturate the face, retain readable primary legend and an explicit subdued edge. Do not rely on global opacity alone. No scale transforms, geometry movement, glyph baseline shifts or decorative state baked into SVG.

Apply the same logic to D-pad, shoulders, utilities and system-toggle material. No action-set variants are required. Render the complete 16-frame matrix: portrait/landscape × light/dark × normal/pressed/active/disabled. Base is the only action set. Also save one clean landscape-dark normal hero image through the native renderer, with app navigation/sidebar/guides and secondary binding glyphs absent from presentation; primary native control labels remain readable. This hero is additional evidence, not a replacement for the sixteen review frames.

## Measurable acceptance criteria

1. Exact classic canonical frames, input identities, bindings and primary labels survive; all thirteen rendered native elements are present, with artwork socket alignment within 2 px at 1×.
2. Both orientations feel individually composed: no stretched group backing, rotated typography, clipped cap or accidental socket collision. No unrelated ornament comes within 4 px of native edges; optional socket expansion is 5–7 px and stays within canvas bounds.
3. At thumbnail size, movement and action groups read first, shoulder/utility controls second, signature last. No continuous console-shaped shell, four-color console palette, fantasy imagery or familiar hardware motif appears.
4. Meaningful legends achieve at least 4.5:1 contrast in every state; important boundaries/large marks achieve 3:1. Save measured token/derived-state evidence rather than judging contrast by eye.
5. Normal, pressed, active and disabled remain distinguishable side by side in both schemes, with inset pressed versus outlined/outward active; geometry and legend position do not shift, and disabled is more than an opacity change.
6. Crisp native labels and editable original SVG artwork appear without seams, blur, doubled edge shadows or subpixel-alignment artifacts at 1× and 2×. No decorative bank miniatures, diagnostic overlays or nonfunctional mock controls appear.
7. Strict quality and package validators pass without warnings; two independent compilations produce identical package bytes/hash. Native contact sheets preserve all 16 frames and each critique revision, with at least two independent critic passes and latest `visual-pass`, followed by `qa-pass`.
8. Preserve source JSON/CSS/SVG, canonical metadata and pending human approval; report final contact sheet and package SHA-256. Do not publish, edit the website catalog, mark human approval, stage, commit or push. Parent owns later approved hero/preview presentation work.

## Principal design risks

The historical template's portrait geometry is unusual: respect it instead of “fixing” controls in a skin. Large well backings can become hardware imitation or consume the intended negative space; individually fitted sockets and interrupted group contours are safer. Neutral caps need enough native state contrast to avoid a merely recolored preset. The tiny system toggle must remain accessible and visually coherent even when the parent presents a clean preview without app chrome.
