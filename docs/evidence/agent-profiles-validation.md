# Agent profile verification — October 23, 2026

Implemented and verified the declarative configuration path: agent tool API → atomic Mac profile store → signed receiver → pinned TLS session → physical iPhone renderer acknowledgement.

- `npm test`: 38 passing tests, including MCP stdio initialize/list/save/activate, concurrent-writer conflicts, failed-edit isolation, independent saved/active snapshots, receiver-status freshness, touch replacement, stale layouts and superseded render acknowledgements.
- Mobile ESLint and TypeScript check: pass. Shared package syntax check: pass.
- Receiver Swift type check: pass. Optimized signed receiver build and strict codesign verification: pass.
- Swift report tests: pass for all button bits, axis endpoints, triggers, opposing D-pad, strict numeric validation and 1,000 codec-equivalent states.
- Native TLS integration test: pass for queued activation, live replacement, superseded acknowledgement, stale input rejection with a fresh lease, neutral recovery and reconnect restoration. Test sends only neutral gameplay state.
- iPhone 13 Pro Max, physical UDID ending `3CA0401E`, iOS 26.3.1: updated Release development app built and installed. Default → Warrior layout displayed on connect; a subsequent live activation changed the title to `Warrior · Live` without reconnecting. Exact activation acknowledged by phone and recorded by receiver status. No gameplay controls were pressed by the agent.
- Final recording setup: one updated receiver using the normal application-support store, same directory as the registered Codex MCP server `tapping-profiles`. Warrior saved revision 1, activation revision 1, `delivery: acknowledged`, `connected: true`, `ready: true` at verification. Final physical screenshot: [Warrior](agent-warrior-iphone.png).
- Visual comparison against the initial built-in layout: 6.23% pixel mismatch, expected for moved/resized/relabelled controls. Accessibility confirms Charge, Execute, Chat, Move and Look; manual screenshot inspection confirms no diagnostic overlap. OCR returned no text changes, so OCR alone was not used to establish label correctness.
- Android networking module: `ANDROID_HOME=/Users/codybontecou/Library/Android/sdk ./gradlew :tapping-link:compileReleaseKotlin --offline` passed. The initial attempt lacked ANDROID_HOME; setting the verified SDK path resolved it. Android was not reinstalled or device-tested for this feature.

The iPhone build completed with three toolchain/script warnings and no errors. The Android compile reported existing Gradle deprecation notices. Neither is evidence of latency qualification or Forever-specific game compatibility.

Automatic WoW ability binding is not implemented. See [companion bridge feasibility](../research/consoleport-agent-bridge.md). The demo labels require matching bindings in WoW/ConsolePort before recording gameplay. Profile delivery evidence is separate from spell-binding evidence.
