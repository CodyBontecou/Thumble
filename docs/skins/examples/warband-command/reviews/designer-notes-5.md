# Warband Command — declutter revision 1.0.1

Followed the parent's bounded art-direction-2.md: removed the passive bank reference from all four editable orientation/scheme SVGs. Removed ledger panel rectangles, heading accents, BASE/LT/RT/LT+RT reference headings, miniature input keys and BANK REFERENCE text. The former reference areas now show plain uninterrupted ground; no replacement decoration was added.

Removed all four miniature PNG canvas-artwork declarations from skin-source.json. Archived the obsolete composition script as `reviews/archive-ledger-v1/compose-ledger.py.txt`, together with its generated source PNGs, so no active authoring script can accidentally reinstate the ledger. Original SVG/CSS remain editable; source ability PNGs and complete original attribution/provenance are preserved.

Kept the four native action-set variants, eight native tile icons, configured example mapping, LT/RT HOLD/HELD status, WARBAND/WARRIOR identity, functional View/Menu/system toggle, input tags, movement/camera legends, all native geometry, and previously reviewed normal/pressed/active/disabled materials. CSS is unchanged in this revision. No app source changes.

Bumped source and preview fixture skin reference to1.0.1. Exact previous1.0.0 final package preserved in reviews/archive-ledger-v1/warband-command-1.0.0.pocketpad (SHA256 494f1af8f1bff172e754fb35a5dd3981f0a514b1c6114d6ca1f3b0af14d674af, matching previous QA evidence).

Strict validation and quality: validation-5.txt and quality-5.txt. Native review evidence: contact-sheet-5.png, full64 panel matrix with8 columns, and landscape-dark-base-5.png, a clean2× native controller render without runtime app chrome. Human approval remains pending; await independent critique and final QA for1.0.1.
