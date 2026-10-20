# Everyday Play — designer pass1

Executed reviewed art-direction.md against classic-16-bit-v1 revision2. Uses its exact native input identities, including its own shoulder UUIDs. No showcase identities, spell imagery, action sets, Warband artwork or styles were reused. Native geometry, labels, bindings, hit testing and accessibility remain canonical.

Original SVG composition: four independent rounded diagonal planes form each interrupted movement/action backing. The center remains open, with no inactive controls, fake cross or hardware shell. Individual socket floors and their restrained lower lips fit the native keys. Landscape shows the left/right split with a quiet central signature. Portrait is newly composed around its rotated canonical action/direction arrangement, with horizontal typography in the center-left band. Native primary arrows and ABXY retain their actual canonical identity.

Source is CSS plus four editable original orientation/scheme SVGs. Palette is mineral gray with sea-glass B/Y and coral X/A borders, neutral cap surfaces and one native sans. Shoulder/utility caps are quieter and use13px legends; action/directional caps use16px. Native controls provide all state feedback: normal shallow outward shadow and fine edge; pressed2px pressure rim with inset shadow and darker cap; active3px accent rim with lifted cap and outward shadow; disabled opaque flattened cap with no shadow and a subdued native edge. No scale transform or label shift occurs. No global opacity is used for disabled presentation.

## Measurements and pre-critique corrections

contrast-1.json records WCAG relative-luminance measurements for every state/scheme's opaque legend and meaningful native boundary, against both cap and adjacent socket. Minimum functional legend6.897:1; minimum boundary3.071:1. Signature text also exceeds4.5:1. Small demonstrated edge corrections: dark cap-edge #718A88→#809A96 (normal cap boundary originally2.684:1); light cap-edge #5D716A→#5B6F68 (adjacent socket originally2.982:1). No other source palette departure.

Portrait's R and adjacent X touch frames have only12.1px horizontal separation. Two6px socket expansions would touch. Shortened only the passive R socket's right expansion to2px, preserving approximately4.1px clear space to X's socket; its remaining expansions remain6px. Native R/X centers and geometry are unchanged. The artwork anchor reserves a0.1% canvas inset to avoid floating-point full-canvas overshoot; socket centers remain within0.5px of native centers at1×.

Inspected the full native state draft and individual landscape/portrait renders before freezing this first review sheet. Native groups, legends and states are visible; portrait is not stretched landscape artwork. No secondary binding glyphs are baked into SVG, so the clean hero contains native primary labels and the system toggle without app navigation/sidebar/guides.

## Frozen evidence

contact-sheet-1.png contains exactly16 Base native frames: both orientations × both schemes × four states, four columns. Individual clean native2× normal renders: landscape-dark-base-1.png, landscape-light-base-1.png, portrait-dark-base-1.png and portrait-light-base-1.png. Strict validation and quality results are in validation-1.txt and quality-1.txt. Human approval is pending; independent critiques and deterministic QA remain required.
