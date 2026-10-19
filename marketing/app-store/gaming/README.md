# Thumble portrait gaming screenshot drafts

The current three App Store images use the existing **Fury Forge** WoW-themed skin, including its Bloodthirst, Whirlwind, Execute and Cleave images. Every export is vertical: **1206 × 2622**, opaque sRGB PNG.

1. `exports/en-US/screenshots/01-iphone-gamepad.png` — Your iPhone. Your controller.
2. `exports/en-US/screenshots/02-move-look-control.png` — Fury at your fingertips.
3. `exports/en-US/screenshots/03-character-setups.png` — Your Warrior. Your setup.

Preview: `reviews/gaming-contact-sheet.png`. Editable embedded-capture compositions: `source/*.svg`. Original portrait native screenshots: `source/captures/fury-forge-*.png`. Exact source and export hashes: `reviews/manifest.json`. The previous landscape drafts are preserved in `archive/landscape/` and superseded.

## Capture and package provenance

Captured October 19, 2026 using the native Thumble iPhone app in the isolated Thumble App Store Capture iPhone 17 Pro simulator on iOS 26.5. The current working-tree build is the same build recorded by the parent capture notes. The real View Saved Keypad and native profile picker were used. The full-resolution source screenshots are genuinely portrait, not landscape images rotated or stretched into vertical exports. The skin, ability images and visible UI all render inside Thumble; no ability icons were pasted onto the app screenshot afterward.

The exact existing package is `docs/skins/examples/fury-forge/dist/fury-forge-1.0.0.pocketpad`, SHA-256 `31c400f4bd0468019100e2e7450e9a375ae05c9e51d05353e058f287c1a6850a`. Its editable SVG/CSS sources, original native all-variant/all-state review sheet and package bytes remain unchanged. Existing skin review evidence is in that skin's `reviews/` directory. Portrait marketing reuse direction, designer notes, independent critique and QA are retained here.

`source/prepare-profiles.py` clones the canonical WoW Forever template without changing its geometry or physical controller outputs, gives the copies manual Fury names, selects portrait/dark appearance, and references Fury Forge 1.0.0. The package was copied only into the disposable simulator's private SkinStore. Personal Mac/phone configurations were not changed.

## Review status

These are visual review drafts captured in **Practice Mode**, visibly labeled in the UI. No signed-receiver recognition or live WoW gameplay is certified by the screenshots. The ability pictures represent the skin's suggested X/Y/B/A action-bar arrangement; WoW still owns the actual ability assignments. No automatic class/talent detection, talent switching or spell synchronization is implied. Solo and Group are manually named copies for the profile-picker demonstration.

The existing skin human-approval record remains **pending**. This capture task neither grants approval nor publishes a skin or App Store artwork. The package's Blizzard ability-image provenance and attribution remain in `docs/skins/examples/fury-forge/sources/provenance.json` and the skin README; the icon rights remain with Blizzard Entertainment.

## Rebuild

```sh
THUMBLE_SHARP_MODULE=/absolute/path/to/node_modules/sharp node marketing/app-store/gaming/source/compose.mjs
```

This recreates editable SVGs with embedded native portrait captures, renders three PNGs, verifies dimensions and alpha, rebuilds the contact sheet, and records SHA-256 hashes. `python3 marketing/app-store/gaming/source/prepare-profiles.py` recreates disposable preference fixtures without installing them or changing personal app data.
