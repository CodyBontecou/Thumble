# Resumable onboarding verification — October 23, 2026

- `npm test`: 90 passed. Includes v1 migration, serialized writes, save failure/retry, preference/request persistence, stale/mismatched agent checks and matching-layout completion after neutral recovery.
- Mobile ESLint and TypeScript: passed.
- `npm run check`: passed.
- `node tools/test-profile-catalog.mjs`: passed. Node-written check marker survives Swift activation; fresh/expired/invalid catalog markers checked.
- `node tools/test-onboarding-receiver.mjs`: passed against the actual receiver linked to GamepadStub, in a temporary profile directory. Fresh catalog works without store.json; agent-tool marker reaches the authenticated catalog; expiry omits it without activating a profile.
- Receiver Swift source typecheck: passed.
- iOS simulator Release build: passed, native v2 persistence included.
- Android native module compile and full Release build: passed. Regenerated the generated autolinking cache after the concurrent app package rename; no generated Java source was edited.

## Manual UI results

On isolated iOS simulator 87952CD2-B760-40A1-AF11-5CE40995960B, Welcome → Getting started → first-layout preferences → prepared request → full app restart → Getting started → first-layout retained the chosen right-side movement and prepared request. A literal newline in three new headings was caught and fixed; the final first-layout heading was visually rechecked. Simulator pairing was blocked by the existing beforeConnect foreground guard reporting the app inactive, including on a manual retry. No iOS live agent/layout round-trip success is claimed.

On Android emulator emulator-5554, Release com.thumble.android paired with the isolated real receiver stub. The agent_connection_check tool recorded the displayed code in the isolated store. Check connection displayed the matching verification. The first-layout request specified first-layout-8244565d. A validated fixture was saved and activated under exactly that ID; controller_status reported delivery acknowledged while the setup screen was open. Check layout delivery completed the milestone. After a force-stop/relaunch, Getting started showed 2 of 4 complete: pairing and first layout only. Controls and WoW remained unconfirmed. See the adjacent screenshots.

The receiver stub never creates a real HID gamepad. No gameplay input was requested, the connected-use demo was not started, and no real profile store or WoW binding was changed.

## Tooling limits and recordings

Argent normalized landscape taps missed their intended targets on both test platforms; direct Android ADB taps at the discovered landscape bounds worked. Two iOS scripted replay attempts stopped at navigation. Failed draft flows were removed; this is a recorded manual walkthrough, not a passing automated UI regression. Physical gameplay, Dynamic Type XL and measured motion performance were not requalified for this change.

Local recordings (ignored build evidence):

- `.argent/recordings/screen-recording-87952CD2-B760-40A1-AF11-5CE40995960B-1792794368748.mp4` — iOS persistence walkthrough, before the heading repair.
- `.argent/recordings/screen-recording-emulator-5554-1792794943985.mp4` — Android welcome, paired agent verification, matching first-layout delivery.

The new phone persistence methods require rebuilt mobile native apps. Agent checking also requires the updated receiver and refreshing the MCP tool connection; this verification did not replace or restart the player's live receiver.
