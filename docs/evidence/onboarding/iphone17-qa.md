# Physical iPhone onboarding QA — 2026-10-23

Tested on the connected iPhone 17 Pro (iOS 27.0.1), installed app `com.thumble.ios`. Used the real receiver transport compiled with `GamepadStub.c`, an isolated temporary profile directory, and the actual profile-tools stdio MCP server through a local test client. No production profiles or WoW bindings were modified. No gameplay input was sent.

## Results

| Scenario | Result | Evidence |
| --- | --- | --- |
| Pair phone with isolated receiver | PASS after permission/link retry | [Paired](iphone17/paired.png) |
| Wrong agent code | PASS: no matching check | [Rejected code](iphone17/agent-wrong-code.png) |
| Matching but expired agent check | PASS: rejected; isolated timestamp deliberately aged beyond 10 minutes | Manual walkthrough |
| Fresh matching agent check | PASS: connection verified | [Verified](iphone17/agent-verified.png) |
| First-layout preferences and request | PASS: right movement, larger actions, unique target ID retained | [Preferences after restart](iphone17/preferences-after-restart.png) |
| Invalid profile geometry | PASS: validation rejected out-of-bounds frame | Real MCP validate_profile call |
| Stale save revision | PASS: rejected expected revision 0 against current revision 1; reread before saving | Real MCP save_profile calls |
| Unrelated active layout | PASS: first-layout milestone stayed incomplete | [Rejected delivery](iphone17/unrelated-layout-rejected.png) |
| Activation while phone backgrounded | PASS: queued, receiver disconnected | [Delivery receipt](iphone17/delivery-receipt.json) |
| Reconnect and acknowledge requested layout | PASS after dismissing and reopening pair link; activation revision 2, profile revision 3 | [Rendered](iphone17/requested-layout-rendered.png), [receipt](iphone17/delivery-receipt.json) |
| Confirm matching delivery | PASS: layout milestone completed | [Confirmed](iphone17/delivery-confirmed.png) |
| Kill/relaunch persistence | PASS: 2/4 complete, previously paired, first layout ready; preferences and agent verification retained | [Restart progress](iphone17/progress-after-restart.png) |
| Reusable resume smoke | PASS: 18/18 steps, uninterrupted full replay on physical iPhone | [.argent flow](../../../.argent/flows/iphone17-onboarding-resume-smoke.yaml) |

The [generated layout](iphone17/generated-layout.json) moves the movement stick to the right, places enlarged ABXY actions on the left in familiar order, preserves every Xbox output mapping, and has no overlapping normalized control rectangles. It was saved only in the isolated test store.

## Findings

1. **Pair-link recovery needs investigation.** Initial local-network permission handling interrupted automatic pairing. Later, opening the pairing link after backgrounding showed Connect Mac without completing the connection. Dismissing that screen and reopening the link succeeded, and the queued layout was acknowledged. This run proves recovery with that extra step, not seamless reconnect. The exact cause is not established.
2. **The main actions are too far down in landscape.** On this device, agent verification and first-layout delivery controls require scrolling. The generated prompt expands the first-layout page to five or six screenfuls; confirmation/error text can initially appear clipped below the viewport. Consider a compact request preview and a persistent delivery action/status.

## Scope and replay

Mac HID and actual WoW actions were intentionally left unconfirmed. ConsolePort export, learned-spell character layouts, in-game Review/Apply, reinstall migration, camera/QR permission branches, and production receiver pairing were not exercised in this physical run. The onboarding correctly remains at 2/4 complete.

The full [manual diagnostic transcript](iphone17/manual-walkthrough.yaml.txt) is **not replayable**: private pairing links and backend mutations were intentionally omitted, and one permission tap was miscaptured. Only the separate resume smoke flow is a verified replay. It assumes the saved state established by this run: setup dismissed, pairing and personalization complete, controls and WoW incomplete, larger buttons/right movement, agent verified. It restarts the app without clearing data, opens Getting started, and checks saved state. No coordinate or raw-gesture exceptions remain in that smoke flow. Run on this phone with:

```sh
argent flow run iphone17-onboarding-resume-smoke --device 00008150-001405DA2188401C --platform ios
```

Phone left in offline practice after relaunch, with its saved onboarding state. The isolated receiver and physical automation server are stopped after evidence capture. Existing user production profiles and bindings remain unchanged.
