# Feature removal implementation progress

The original working tree is preserved in commit `5fadf15`, including Android editing/synchronization work, design sources, screenshots, and recordings. Additional work from other chats continues in the shared checkout; removal changes are staged separately where files overlap.

## Implemented

- Frozen native appearance, legacy-profile, pending-edit, trigger-bank, and migration-input fixtures under Host/fixtures/feature-removal/v1, including hashes and eight native normal/pressed images. Swift, Rust, and Android tests consume the same frozen data.
- An ownership inventory and migration contract covering version 4 imports, the intended version 5 destination, resource completeness, unknown metadata, offline edits, deterministic conversion, authority transactions, interruption recovery, and rollback.
- Shared visual roles, control appearance, artwork, normalized geometry, color-scheme, and trigger-state primitives extracted from skin source files into Sources/Shared/GamepadAppearance.swift. Codable shape and inline representation remain unchanged. Legacy type names are retained during removal. The static stack checker includes the new object under its existing limits.
- Calibration UI, tracing, scoring, storage implementations, worker state, and dedicated tests removed on iOS and Android. The normal phone editor, layout reconciliation, Practice Mode, haptic preferences, and general layout-quality checks remain. Existing accepted calibration suggestions remain ordinary saved layout changes.
- Obsolete iOS reach preferences and Android trace files are cleaned up independently of saved profiles. Android cleanup is best effort and retries with a new session if needed. Public setup text no longer offers calibration.

- Public skin catalog, package downloads, browsing UI, publishing scripts, and directory-specific CSS removed from website source. Four original archives are retained under Host/fixtures/legacy-skin-packages with hashes; test consumers use that location. Old directory links show a retirement notice pointing to the editor. The homepage and notice were checked in the local browser; no deployment was made.

- Hosted gateway, cloud-builder, and tunnel crates, remote MCP relay mode, Fly deployment recipe, remote connection commands, and release-installed relay launcher removed. Local stdio MCP, local CLI generation, portable profile import/export, and local controller design tools remain. The cleanup-only `thumble relay uninstall` command verifies and removes the old local LaunchAgent.
- Active hosted setup instructions replaced with local-tool guidance; source deployment retirement requirements are recorded in docs/hosted-service-retirement.md. The Fly CLI is signed out, so live inventory and shutdown remain outstanding. Phone shared-build pickup/adoption and pending-build recovery are a separate unfinished removal step.

## Verification evidence

- Initial full Rust workspace run: 655 passed, 5 ignored across 49 test targets. The ignored tests remain outstanding; they are not counted as passing acceptance.
- New Rust baseline tests: two pass, covering legacy-document validation/roundtrip and unknown metadata plus unresolved package references.
- Swift preservation fixtures: five pass, including eight light/dark trigger banks and native rendering. Phone policy tests also pass. The focused exact-prefix cleanup test passes, preserving haptic preferences, offline-edit bytes, and unrelated future keys.
- Android isolated build, 177 unit tests, and instrumentation-test compilation pass after calibration removal. Instrumentation compilation does not establish device behavior.
- The real Thumble Link Lua 5.1.5 exporter passes against the checked-in importer fixture. The existing packaged CLI passes review, import, selection preservation, refresh, geometry preservation, metadata, and invalid-input checks in a private temporary home. Repeat against the final freshly built CLI before accepting the entire removal.
- Reduced local Rust workspace gate passes after hosted-source removal: formatting, clippy, parity, 472 tests, and all-target checks. Five integration tests remain ignored. Real local stdio MCP initialization exposes 28 tools, and all five retired relay flags reject.
- The final canonical CLI rejects seven remote relay operations and reports retirement for shared-build commands while retaining local design/generation/import. Its final source was compiled and linked by replaying exact cached Xcode commands after Xcode’s metadata-discovery process stalled on compiler output pipes. The new CLI and fresh Rust bridge pass the WoW import/refresh checks with the existing native Swift transformer. The old LaunchAgent cleanup command was not executed.
- Existing CLI synthetic latency verification passes the 4 ms max/p95 budgets: 1.41 ms for ordinary/burst cases and 3.91 ms for UDP recovery cases. Physical device latency comparison remains outstanding.
- Marketplace removal checks verify that four exact legacy package archives remain outside Website, no package/catalog assets are deployed by that directory, and HTML links no longer offer the directory. Local HTTP checks return 404 for retired catalog/package URLs. The full stack-safety gate also passes after relocation. Eight host skin tests, including the real native bridge test, pass after fixture relocation.
- The required ./scripts/verify-stack-safety.sh gate passes: 30 constrained-stack tests plus macOS and iOS Debug builds with static frame budgets. Its first run exposed the need to include the new appearance object in static inspection; no budget was raised.

## Remaining work

1. Implement actual migration and persistence, including multi-scheme/trigger appearance ownership, portrait-only conversion, missing resources, pending phone edits, interruption recovery, and rollback. The fixtures and contract do not themselves perform these conversions.
2. Remove active skin UI/runtime and package-only authoring infrastructure after successful migration. The public catalog/distribution source is retired.
3. Remove remaining phone shared-build pickup/adoption and provide pending-build recovery/export. Hosted gateway/relay source and release installer are retired. Authenticate the Fly CLI to inventory live services before any operational retirement.
4. Make the controller and layout editor landscape-only and remove active portrait variants after reconciliation and migration are verified.
5. Finish retained-platform/device acceptance, physical haptics, input latency, WoW client acceptance where available, final documentation/capability cleanup, and complete build/release gates.

No deployed service has been stopped, and no skin-backed or portrait user profile has been migrated or discarded by this batch.
