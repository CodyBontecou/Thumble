# Thumble App Store screenshot drafts

**Current direction:** [iPhone gaming controller for WoW Forever fans](gaming/README.md). The productivity drafts below are superseded and retained as earlier work.

Three review drafts built from actual native Thumble UI captures on October 19, 2026. The PNG exports are opaque sRGB at 1206 × 2622. No app UI was generated or redrawn.

| Export | UI shown |
| --- | --- |
| `exports/en-US/screenshots/01-your-mac-keypad.png` | Everyday keypad: Search, Switch app, Copy, Paste, Undo, Escape |
| `exports/en-US/screenshots/02-shortcuts-within-reach.png` | Developer keypad: Palette, Quick open, Find, Save, New tab, Escape |
| `exports/en-US/screenshots/03-make-the-layout-yours.png` | Matching Everyday profile in the native Mac editor and iPhone app |

`reviews/first-three-contact-sheet.png` shows the set together. `source/*.svg` are editable compositions with the original captures embedded. Text, backgrounds, frames, and screenshot image elements remain separate SVG objects. `source/captures/` preserves the uncomposited native captures. `copy/en-US.csv` contains the proposed listing copy.

## Capture provenance

The iPhone app was built from the current working tree using the ThumbleiOS scheme and `build/MarketingCaptureDerivedData`. Captures came from an isolated simulator named Thumble App Store Capture, iPhone 17 Pro, iOS 26.5, device ID `D02C94AB-0646-4005-91A3-2CA56AE77E3B`. The simulator status bar was standardized to 9:41 and full battery. Demo profiles were loaded into that simulator's private app data. Its real View Saved Keypad, Practice Mode, and profile menu were used.

The Mac app was built from the current working tree using the ThumbleMac scheme, Debug, with signing disabled. A temporary, ad-hoc-signed copy had the unique bundle identifier `com.thumble.MarketingCapture` and a disposable home through `CFFIXED_USER_HOME`. Demo data was supplied in its process-only NSArgumentDomain through a small capture fixture loader. The editor itself is the unchanged native application. Its matching Everyday profile reports Layout Good. The window alone was captured with macOS screencapture; no desktop or unrelated window is included.

`source/prepare-profiles.py` derives the two demo profiles from the repository's Productivity Starter fixture, with explicit keyboard outputs and corresponding presentation glyphs. It writes only local fixture files. No community skin was created or modified. The failed initial CLI dry-run did not install or alter a profile; the fixtures were subsequently prepared directly for the disposable capture apps.

## Rebuild compositions

Use Node.js and Sharp:

```sh
THUMBLE_SHARP_MODULE=/absolute/path/to/node_modules/sharp node marketing/app-store/source/compose.mjs
```

The script preserves capture aspect ratios, embeds the captures into editable SVGs, renders three opaque PNGs, checks export dimensions and alpha, rebuilds the contact sheet, and writes export SHA-256 hashes to `reviews/manifest.json`. Its default Sharp path points to this workstation's bundled Codex runtime; set the environment variable on another machine.

`python3 marketing/app-store/source/prepare-profiles.py` recreates the saved demo fixtures. It does not install them or operate a running app. Do not load these preference fixtures into a personal app domain; use a disposable simulator/app copy.

## Review status

These are design review drafts. iPhone input is in real Practice Mode, visibly labeled in the captures. No paired-device shortcut delivery or sync acceptance was performed. The Mac and iPhone were independently loaded with the same fixture, so screenshot three does not constitute evidence of live synchronization. Recapture against the approved shipping build and verify the shown shortcut workflows on a paired device before treating these as submission-ready assets. The developer profile uses common editor shortcuts; their behavior depends on the focused Mac application.

The original screenshot UI pixels are preserved aside from proportional scaling and rounded edge clipping in the surrounding composition. There are no invented tap effects or connected-state indicators. The surrounding border is a simple graphic frame, not an Apple hardware rendering. No artwork has been uploaded or published.
