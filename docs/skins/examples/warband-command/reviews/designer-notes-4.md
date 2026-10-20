# Warband Command — bounded C4 legend correction

Critique 2 resolved C1–C3 and identified one remaining issue: Move/Look native captions crossed the joystick inner ring in the canonical renderer.

Changed only joystick content presentation:

- Explicit `-thumble-label-placement:center` puts the one native Move/Look caption inside each opaque puck. The first native render confirmed this placement works in the canonical path, so the native ring can remain.
- Increased the visual knob ratio from .48 to .58 to reserve clear space around the text in the smaller portrait sticks. The canonical portrait stick is69.47px wide; the new puck is40.29px wide, with approximately37.3px interior even under the3px pressed stroke. The10px Move/Look captions fit with more than4px clear horizontal space from the puck boundary. Landscape provides additional clearance. Touch frames and centers remain canonical.
- No SVG captions were added. Each stick has exactly one native identity label. Bank permutations, held status, reference input keys, main icon scale, ability frame states, original artwork, utility controls, provenance and bindings are unchanged.

Frozen review evidence: contact-sheet-4.png (all64 native panels), landscape-dark-base-4.png plus LT/RT/both singles, portrait-dark-base-4.png. Strict package validation and quality results are recorded in validation-4.txt and quality-4.txt. The parent's isolated live-app evidence separately checks this exact package. Human approval remains pending.
