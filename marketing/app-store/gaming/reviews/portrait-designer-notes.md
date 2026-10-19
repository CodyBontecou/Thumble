# Portrait capture fixture preparation

Prepared the real app's isolated capture preference fixtures using the existing Fury Forge package unchanged. No skin source, ability artwork, compiled package, or human-approval record was edited. This is marketing capture preparation, not a skin redesign or publication approval.

- Reused package: `docs/skins/examples/fury-forge/dist/fury-forge-1.0.0.pocketpad`.
- Verified package SHA-256: `31c400f4bd0468019100e2e7450e9a375ae05c9e51d05353e058f287c1a6850a`.
- Native final skin contact sheet: `docs/skins/examples/fury-forge/reviews/contact-sheet-2.png` (portrait/landscape, light/dark, normal/pressed/active/disabled).
- Original independent critiques: `docs/skins/examples/fury-forge/reviews/critique-1.md` and `critique-2.md`; final verdict `visual-pass`.
- Original strict QA: `docs/skins/examples/fury-forge/reviews/qa-report.md`; verdict `qa-pass`.
- Original native landscape evidence: `docs/skins/examples/fury-forge/reviews/landscape-dark-2.png`.
- Human approval remains pending in the original record.

`source/prepare-profiles.py` clones `Host/fixtures/controller-templates/v1/wowForever.json` into three manually named profiles: Fury Warrior, Fury — Solo, and Fury — Group. All have portrait orientation, dark scheme, and `skinReference` pointing to `com.thumble.fury-forge` version `1.0.0`. No skin baseline is supplied: the native resolver applies the installed referenced appearance normally. The isolated simulator must contain the copied package in its SkinStore before capture.

Regenerated `source/profiles/gaming-preferences.plist`, with Fury Warrior selected and Practice Mode enabled. Deleted obsolete WoW Forever/Frost Mage marketing fixtures to prevent accidental reuse. Profile names are manually saved examples, not a claim of automatic class discovery or spell binding.

Verification: executed the preparation script, decoded the plist, confirmed all three profiles, and compared each JSON object with a canonical clone. Only profile identity/name, orientation preference, customization color scheme, and skin reference differ. Layout geometry, canonical semantic IDs, output mode, executable bindings, and timestamps remain unchanged. No app implementation changes were made. No simulator interaction or composition changes were performed in this designer stage; native captures and export review follow separately.

Existing Bloodthirst, Whirlwind, Execute, and Cleave icons retain the original documented provenance and attribution: © Blizzard Entertainment, all rights reserved. No new icon or game imagery was introduced.
