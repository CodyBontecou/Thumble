# Mac clean preview and lossless icon polish

The Mac app is open in Clean Preview with Warband Command · Warrior selected, package1.0.2. Real window evidence: `mac-clean-preview-1.0.2.png`, captured by `thumble app screenshot`. The system is dark. Navigation, editor panels, command bar, guide/crosshair lines, hit-area/quality overlays and secondary binding glyphs are absent. Primary LT/RT HOLD, utility labels and native input tags remain. The canvas fits the available space; underlying coordinates are unchanged. Return to Editor is the pencil toolbar action.

`thumble app editor-view clean|edit|status` provides matching CLI control. Actual clean/edit/clean checks restored navigation, guides, secondary binding labels and editor commands (see `mac-editor-aids-restored.png`) and returned to clean. The complete native configuration document remained identical across the round trip: content SHA-256 `a01fcd4c86659eae6dc1698aa74a3cd0100f826c3e5a1242c56ae69a25b2d730`. No saved-profile appearance or executable binding changed from the preview toggle. Editor keyboard command monitoring and pointer hit testing are disabled in clean preview; editing remains available after returning. Accessibility presentation was not independently exercised with VoiceOver.

The package was installed locally after independent skin QA. Its SHA-256 is `1f53393e57dc7f93741b0067d6b36fdcdb7773f7170712aee8242642f1591782`. Native skin-bridge application plus revision-checked configuration commit verified all control frame fields and input mappings were unchanged. No game input was sent to verify this presentation. Thumble Host remains stopped under the user's earlier instruction; the native Mac editor owns current configuration.

Icon replacement uses eight exact original64 PNGs with precise56px interior crops, removing JPEG damage without an upscale or increased-resolution claim. The compiled skin appearance JSON and four authored canvas rasters are byte-identical to1.0.1; provenance, comparisons, 64-frame contact sheet6 and QA report3 are retained.

The local website hero now uses the byte-identical native base render from1.0.2. Preview refreshed at http://127.0.0.1:8174/?preview=hero; screenshot `website-hero-1.0.2.png`. No hosted deployment or catalog change.

Validation: CLI scheme build succeeded (including compatibility CLI targets); Mac build and required stack-safety suite passed in `/tmp/thumble-warband-polish-stack-safety.log`. `git diff --check` passed. Skin visual reviews6–7 and deterministic QA3 passed independently. Human approval remains pending.
