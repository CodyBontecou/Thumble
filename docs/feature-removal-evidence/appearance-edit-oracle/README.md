# Owned appearance peer preparation

The new Rust `ProfileAppearanceBank` resolves package-independent paint while retaining canonical geometry and executable owners. Resource references stay compact; lookups share immutable decoded buffers. It implements the native three-way policy for nested states/content/pointing, explicit clears, reusable styles, direct fills/icons, artwork, assets and bar paint. Owner allowlists, the complete eight-state set, collection identities, asset references and compact-JSON byte bounds are checked before resolution. This preparation does not activate authority acceptance, version-5 interchange or user-data migration.

The shared native oracle has 21 edits and 168 results. Its source, case descriptions, hashes, regeneration instructions and color-only comparison policy are in `Host/fixtures/appearance-edits/README.md`. Native regeneration must match the frozen file exactly; Rust and Android comparisons allow `2e-7` only on normalized RGBA channels to account for SwiftUI/NSColor palette conversion. Other values, input owners and geometry are exact; binary bytes are preserved.

Verification:

- `rust-gate.log`: the full pinned-toolchain Rust gate passes formatting, clippy, 482 tests and retained target checks. Three native-dependent tests remain ignored. The five new cases include the full oracle, resource sharing, corruption/recovery, opaque metadata, exact input/geometry preservation and the byte-limit boundary.
- `final-core-tests.log` and `final-core-clippy.log`: after adding explicit nesting and malformed-mirror guards, all five resolver cases and core/all-target clippy pass again. The full Rust gate above ran before these final guards; the guard does not activate authority support.
- `native-tests.log`: 20 tests pass across stable oracle regeneration, native bank edits and pooled resources. No native production appearance behavior was changed.
- `stack-safety.log`: 35 constrained-thread tests and both Apple Debug builds pass under the existing budgets.
- `android-units.json`: all 198 unit tests pass, including all 168 native oracle results. `android-build.log` also confirms device-test compilation/packaging, which is not a device test run.
- `fixture-manifest.json`: pins the native generator and frozen oracle used by these checks. The original pre-removal fixture verifier also passes. CI runs the new native tests and the retained Rust gate now verifies both fixture sets.

The oracle revealed and corrected Android differences in native artwork ordering, omission of default bar paint, and the required empty normal state when a reusable style changes alongside a pressed-only edit. Existing collection tests now assert native plane/z-index/identity order for artwork. Reusable-style collection ordering remains identity-based.

These are semantic model/worker-preparation checks, not new native-renderer screenshots, Android device instrumentation, physical haptics, network latency or live WoW acceptance. Complete configuration/transport budgets, live authority integration, version-5 negotiation and atomic migration remain outstanding. No user profile was migrated, and no deployed service changed.
