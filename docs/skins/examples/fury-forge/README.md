# Fury Forge

An editable Fury Warrior presentation for Thumble's `wow-forever-v1` native gamepad template. Original steel framing and crimson seams surround full-color Blizzard ability icons.

The suggested action-bar arrangement is **X Bloodthirst, Y Whirlwind, B Execute, A Cleave**. These are visual suggestions: the controller continues to emit ordinary X/Y/B/A gamepad inputs. Arrange the abilities on the matching WoW gamepad action-bar slots yourself. Trigger, shoulder, stick-click, D-pad, View and Menu identities remain explicit. No macros or automatic class/talent detection are included.

The four package icons come from Blizzard's official shared WoW CDN. URLs, hashes and spell associations are in `sources/provenance.json`; original JPEGs are preserved in `sources/originals`. They have not been independently compared against a Forever-client export. Optional Death Wish, Charge, Berserker Rage and Recklessness PNGs are preserved for user-directed customization but excluded from the package until assigned. Raging Blows is not shown as an action.

Edit `styles/controller.css` to change a face icon's `url(#asset-id)`. Declare replacement assets in `skin-source.json`; give every packaged asset a real use so strict validation stays warning-free. Edit `sources/artwork/forge-*.svg` for the separate portrait/landscape and light/dark frames.

```sh
thumble skin compile docs/skins/examples/fury-forge -o docs/skins/examples/fury-forge/build/fury-forge.pocketpad --clean
thumble skin validate docs/skins/examples/fury-forge/build/fury-forge.pocketpad --strict
thumble skin quality docs/skins/examples/fury-forge --artboard wow-forever-v1 --strict
thumble skin preview docs/skins/examples/fury-forge -o docs/skins/examples/fury-forge/reviews/contact-sheet-1.png --all-variants --all-states --native-renderer --contact-sheet --columns 4
```

The package requires the native WoW Forever template for aligned framing. Other layout geometries may hide the framing. Review evidence and human approval are recorded under `reviews`; approval is pending. No skin has been published or applied to the live host.

The reviewed distributable is `dist/fury-forge-1.0.0.pocketpad`. Final native evidence is `reviews/contact-sheet-2.png`; the independent visual pass and technical QA are in `reviews/critique-2.md` and `reviews/qa-report.md`. Recompile after an edit and repeat review before approving a changed package.

After reviewing the exact candidate, create a **WoW Forever** setup named **WoW Fury Warrior** in the app, import the package in the skin library, and apply **Fury Forge** to that setup. Duplicate the setup for another talent build and choose different icon assets as needed. The CLI can create the matching base setup with `thumble template install wowForever --name "WoW Fury Warrior"`; skin import/apply follows the receiver's configured authority rules.

Original framing and CSS may be used under MIT. Blizzard icons remain © Blizzard Entertainment, all rights reserved.
