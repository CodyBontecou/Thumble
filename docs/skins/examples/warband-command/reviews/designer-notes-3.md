# Warband Command — bounded revision after critique 1

Reviewed parent-synthesized C1, C2 and C3 from critique-1.md. No bindings, canonical hit geometry, app code or public catalog changes.

- C1: portrait reference panels now label each miniature with a native-size 8px A, X, B or Y SVG character, adjacent to its exact cell. The original 16px miniature dimensions remain unchanged, repositioned within the same panels. Reference panel bounds remain y250–305; View/Menu begins y317 (12px clearance). Original orientation SVG remains editable. Reproducible PNG composition remains sources/compose-ledger.py.
- C2: left-trigger bank's native LT capsule reads LT · HELD; right-trigger bank's RT reads RT · HELD; both-trigger bank marks both HELD. Unheld capsules read HOLD. Capsule geometry, baseline, icon centers and text font remain fixed.
- C3: native icon scale changed from3 to2.55, constant across states. Given native size formula minimum side × .34 × scale, native icons measure36.4px in41.8px portrait tiles and38.8px in44.7px landscape tiles. This exposes the native perimeter continuously. Pressed retains2px high-contrast pressure rim plus native inset shadow; active uses3px continuous bank boundary, with no scaling or opacity reliance. Light pressure is deep brown, dark pressure warm ivory. Artwork and input tag centers do not move.

Before full-sheet generation, rendered normal/pressed/active native landscape comparisons in both appearances. cluster-states-dark-3.png and cluster-states-light-3.png are exact crops from those native screenshots arranged left-to-right normal/pressed/active, with comparison headings outside crops. Close comparisons show unobscured native state edges; all six full screenshots remain available. Full contact-sheet-3.png covers four action sets × two orientations × two appearances × four states.

Removed duplicate external SVG MOVE/CAMERA captions to avoid competing labels in the live app; native Move/Look remain the display identity. Set joystick font-size10px while preserving stick geometry. (Live iOS labels and canonical preview are known to differ; parent owns app evidence.)

Strict validation and quality reports: validation-3.txt and quality-3.txt. Human approval remains pending, independent critique 2 and QA required.
