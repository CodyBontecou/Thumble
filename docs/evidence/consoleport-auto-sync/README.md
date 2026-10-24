# ConsolePort automatic sync QA — 2026-10-24

Implemented and installed the updated Thumble addon in Classic Era and built the universal, Developer ID signed Mac receiver. The existing phone build already supports receiving these profiles; no phone rebuild was needed.

## Automated checks

- `npm run test:addon`: Lua 5.1 addon and sync tests pass, including event debounce, combat deferral, final logout capture, opt-out and separate manual exports.
- `npm run test:consoleport-sync`: native fixture tests pass for bounded non-executing Lua decoding, malformed/stale input, startup baseline, reload detection, all eight modifier states, actual modifier outputs, geometry/mapping retention, artwork caching/fallback, idempotence, shared-store revision conflicts, character switching, theme guard, symlink exclusion and file replacement during artwork lookup. Node reads the resulting store and the shared phone validator accepts the profile.
- `npm run test:pairing`: native QR/private bridge and hosted pairing regressions pass outside the sandbox (Core Image and localhost transport require macOS access).
- `AI_CONTROLLER_GENERATOR_ENABLED=true node tools/test-onboarding-receiver.mjs`: existing isolated receiver transport regression passes. This flag applies only to that test's legacy agent-check fixture; app/service flags were not changed.
- `tools/build-macos-receiver.sh`: universal receiver builds and signature verification passes using the existing approved Developer ID identity/profile.

## Live WoW and physical iPhone

Computer Use reloaded the actual Fuskotargar session on Azuresong. The first reload loaded the new addon; the next saved `syncText`. The native watcher automatically created and activated the character profile at activation 16. Repeated reloads refreshed provenance without another activation. The saved context reports action page 7; a Shift+2 probe did not produce a changed layout, so a live action-page-change assertion is not claimed.

Argent opened the current private receiver pairing link on the cabled iPhone 13 Pro Max. `receiver-status.json` reported `connected: true`, `ready: true`, `revision: 16`, proving the phone acknowledged the automatically generated profile. The attached screenshot shows it after Continue in practice mode: Heroic Strike, Attack, Tough Jerky and utility controls. `synced-profile.json` records the generated layout and all modifier states without pairing credentials.

The phone's free controller time is exhausted. Layout delivery/acknowledgement and practice rendering were verified; gameplay input from the phone was not tested in this run. No entitlement state or game bindings were changed. Live cooldowns and in-combat state streaming are outside this saved-snapshot feature.
