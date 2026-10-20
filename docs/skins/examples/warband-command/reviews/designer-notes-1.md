# Warband Command — designer pass 1

Original Warrior field command board, authored as CSS and four editable orientation/scheme SVGs. No source app changes, geometry, executable bindings, live game synchronization or public catalog edits. Passive decorative sockets and reference diagrams sit around the canonical native controls. All eight actionable tiles use the eight existing attributed Blizzard PNGs, copied byte-for-byte alongside original JPEGs and provenance.

The safe SVG sanitizer rejects external and data hrefs. Accordingly, the four reference banks use original colored diamond slot diagrams, not raster miniatures. The diagrams deliberately do not imply additional playable buttons. The active tile border accent changes with the bank; the bank-specific native icon assignments remain authoritative. Adjacent SVG input tags are passive and do not replace native input identity/accessibility. Native normal, pressed, active, disabled feedback remains in CSS. Every bank has independent native variants.

Example mappings, appearance only (configure the game's bars to agree):

| Input | Base | LT | RT | LT+RT |
|---|---|---|---|---|
| Up | charge | death-wish | recklessness | berserker-rage |
| Down | berserker-rage | recklessness | charge | death-wish |
| Left | death-wish | charge | berserker-rage | recklessness |
| Right | recklessness | berserker-rage | death-wish | charge |
| A | cleave | execute | bloodthirst | whirlwind |
| X | bloodthirst | whirlwind | cleave | execute |
| B | execute | bloodthirst | whirlwind | cleave |
| Y | whirlwind | cleave | execute | bloodthirst |

Pressing/releasing native triggers selects the appropriate appearance bank in the existing app. Both is its own permutation, not the result of combining two rules. LB/RB/L3/R3 retain their ordinary input labels; no party macro claims are made.

Validation: package strict valid/no warnings. Strict source quality 100/100, zero errors/warnings. Frozen contact-sheet-1.png is a full 64 panel native matrix (four action sets × two orientations × two schemes × four states), eight columns. Individual dark landscape images accompany the matrix. Independent visual critique and QA are pending; human approval remains pending.
