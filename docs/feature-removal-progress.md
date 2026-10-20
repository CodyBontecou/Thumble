# Feature removal implementation progress

The original working tree is preserved in commit `5fadf15`, including Android editing/synchronization work, design sources, screenshots, and recordings. Additional work from other chats continues in the shared checkout; removal changes are staged separately where files overlap.

## Implemented

- Frozen native appearance, legacy-profile, pending-edit, trigger-bank, and migration-input fixtures under Host/fixtures/feature-removal/v1, including hashes and eight native normal/pressed images. Swift, Rust, and Android tests consume the same frozen data.
- An ownership inventory and migration contract covering version 4 imports, the intended version 5 destination, resource completeness, unknown metadata, offline edits, deterministic conversion, authority transactions, interruption recovery, and rollback.
- Shared visual roles, control appearance, artwork, normalized geometry, color-scheme, and trigger-state primitives extracted from skin source files into Sources/Shared/GamepadAppearance.swift. Codable shape and inline representation remain unchanged. Legacy type names are retained during removal. The static stack checker includes the new object under its existing limits.
- Calibration UI, tracing, scoring, storage implementations, worker state, and dedicated tests removed on iOS and Android. The normal phone editor, layout reconciliation, Practice Mode, haptic preferences, and general layout-quality checks remain. Existing accepted calibration suggestions remain ordinary saved layout changes.
- Obsolete iOS reach preferences and Android trace files are cleaned up independently of saved profiles. Android cleanup is best effort and retries with a new session if needed. Public setup text no longer offers calibration.

## Verification evidence

- Initial full Rust workspace run: 655 passed, 5 ignored across 49 test targets. The ignored tests remain outstanding; they are not counted as passing acceptance.
- New Rust baseline tests: two pass, covering legacy-document validation/roundtrip and unknown metadata plus unresolved package references.
- Swift preservation fixtures: five pass, including eight light/dark trigger banks and native rendering. Phone policy tests also pass. The focused exact-prefix cleanup test passes, preserving haptic preferences, offline-edit bytes, and unrelated future keys.
- Android isolated build, 177 unit tests, and instrumentation-test compilation pass after calibration removal. Instrumentation compilation does not establish device behavior.
- The real Thumble Link Lua 5.1.5 exporter passes against the checked-in importer fixture. The existing packaged CLI passes review, import, selection preservation, refresh, geometry preservation, metadata, and invalid-input checks in a private temporary home. Repeat against the final freshly built CLI before accepting the entire removal.
- Existing CLI synthetic latency verification passes the 4 ms max/p95 budgets: 1.41 ms for ordinary/burst cases and 3.91 ms for UDP recovery cases. Physical device latency comparison remains outstanding.
- The required ./scripts/verify-stack-safety.sh gate passes: 30 constrained-stack tests plus macOS and iOS Debug builds with static frame budgets. Its first run exposed the need to include the new appearance object in static inspection; no budget was raised.

## Remaining work

1. Implement actual migration and persistence, including multi-scheme/trigger appearance ownership, portrait-only conversion, missing resources, pending phone edits, interruption recovery, and rollback. The fixtures and contract do not themselves perform these conversions.
2. Remove active skin UI/runtime, catalog/distribution, and package-only authoring infrastructure after successful migration.
3. Remove hosted builder/relay/pickup code and release packaging while retaining local CLI/MCP and ordinary profile interchange. Inventory live services before any operational retirement.
4. Make the controller and layout editor landscape-only and remove active portrait variants after reconciliation and migration are verified.
5. Finish retained-platform/device acceptance, physical haptics, input latency, WoW client acceptance where available, final documentation/capability cleanup, and complete build/release gates.

No deployed service has been stopped, and no skin-backed or portrait user profile has been migrated or discarded by this batch.
