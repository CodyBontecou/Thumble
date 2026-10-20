# Feature removal migration fixtures

These frozen inputs and expectations were copied from the native reference fixtures at checkpoint `5fadf15`, before removing any features. They are retained independently of the skin, hosted-builder, portrait, and calibration tests that will be deleted.

- `v1/appearance.json`: ten native appearance resolutions across light/dark modes, local overrides, mixed control kinds, productivity controls, and WoW Forever outputs. Includes embedded asset payloads and reusable styles.
- `v1/legacy-profiles.json`: four saved skin-backed profiles and current detachment expectations, including separate orientation variants and user overrides. These record old behavior; detachment alone is not a complete migration because color-scheme and trigger-state differences need preservation.
- `v1/pending-edits.json`: six native reconciliation cases, including offline edits, host identity mismatch, untrusted edits, two orientations, acknowledgements, and shared appearance preferences.
- `v1/action-sets.json`: eight explicit light/dark and trigger-bank appearance requirements.
- `v1/migration-cases.json`: missing-package, portrait-only, and plain profiles with retained unknown metadata and explicit required migration dispositions.
- `v1/input-latency-model.json`: existing CLI synthetic verification with 4 ms max/p95 budgets. Its binary hash is recorded in the manifest. This verifies modeled wire/recovery timing, not physical phone-to-game latency.
- `v1/manifest.json`: checkpoint, case counts, and SHA-256 hashes. `python3 scripts/verify-feature-removal-fixtures.py` checks the frozen files without rewriting them.

Swift tests replay appearance, detachment, and pending-edit behavior. Android tests check the same appearance and control identities. Rust validates and round-trips complete legacy profile documents without losing metadata. These are baseline contracts, not proof that a future migration is implemented. Add separate expected migration outputs when that conversion exists; do not replace these inputs with newly normalized profiles.

`FeatureRemovalBaselineTests/testRenderFrozenAppearanceWithNativeControls` writes native normal/pressed PNG candidates for mixed controls and WoW layouts to `build/FeatureRemovalBaseline`. Capture and inspect those before accepting appearance changes. Pixel output depends on the installed OS and fonts; compare on the same rendering environment.

Eight original native PNGs are retained in `v1/previews`, with their hashes and rendering environment in the manifest. These exercise native geometry, color, and pressed-state rendering. The synthetic resolver asset payload is deliberately not a real PNG; these images do not establish fidelity for external artwork decoding or actual game icons.

Still required before the migration is complete: implemented unresolved/missing-package recovery, portrait-only conversion, atomic persistence/interruption recovery, physical haptics, measured device latency, and live WoW acceptance where available.
