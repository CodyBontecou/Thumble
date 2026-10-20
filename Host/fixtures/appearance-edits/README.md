# Native owned-appearance edit oracle

`v1/fixture.json` contains 21 native-generated edits and 168 expected appearance snapshots: every light/dark and Base/LT/RT/both-trigger combination. `Tests/AppearanceEditOracleTests.swift` regenerates the complete result in `build/AppearanceEditOracle/fixture.json` and checks its exact SHA-256 against the frozen copy. The manifest pins both the fixture and generator. These fixtures are separate from the immutable pre-removal baseline.

Cases cover nested normal/pressed typography and pointing paint, haptics, explicit state/content clearing, reusable-style selection, direct icon/fill edits, fill-storage bookkeeping, artwork identity and native ordering, style-token edits/reordering, bar paint and manual geometry, asset replacement, all six accent fallbacks, icon clearing, and added/removed controls. Native assertions retain every element ID, executable output and part output. Peer checks also require unchanged geometry and input owners.

Profiles use the existing pooled resource envelope. Expected snapshots expand those references into the native standalone appearance codec. Rust retains compact references and validates/shares immutable binary buffers; only its test comparison expands bytes. Android expands them during worker preparation through its existing resource reader. No package lookup is involved.

Comparison requires exact structure, identities, text, resource bytes and non-color values. The sole numeric tolerance is `2e-7` for normalized RGBA channels under color owners. Native SwiftUI/NSColor palette conversion differs from direct sRGB division by up to `1.2e-7` in this set; the tolerance is less than one ten-thousandth of an 8-bit channel step. It is not a pixel-diff tolerance and must not be used for geometry, opacity, haptics or other numeric fields.

Artwork normalization follows the native model: hidden layers are excluded, and visible layers sort by plane, z-index and identity. Array reordering alone does not change the native artwork order; editor stacking changes use z-index. Default bar paint is omitted from snapshots so bookkeeping records do not become user overrides.

To intentionally update the oracle, run the native generator, inspect its changed cases and invariants, copy its output to the frozen path, refresh the manifest hashes/counts, and rerun Swift, Rust and Android consumers. Do not regenerate the original feature-removal baseline.

This preparation does not enable version-5 exports, authority acceptance, automatic migration, landscape conversion or old-peer negotiation. Those remain required before deleting the skin runtime or committing user-data conversion.
