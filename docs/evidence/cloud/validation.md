# Cloud pilot validation — 2026-10-23

## Automated evidence

- `npm test`: **129 passed**, zero failures. Includes existing controller, profile, entitlement, onboarding and pairing tests alongside the cloud suites.
- `npm run test:cloud`: **29 passed**, zero failures. Signed OAuth JWT verification, account/scope isolation, CAS saves, idempotent delivery, exact receipts, device expiry/revocation, MCP SDK protocol, mobile foreground/LAN gating, cache, supersession, lost-response reconciliation, single-flight refresh and logout races.
- `npm run test:cloud:runtime`: **passed**. Bundles the production Worker with Wrangler, starts isolated local workerd with real D1, applies the migration, verifies signed account tokens and exercises MCP save/deliver/status with device-token poll/received/rendered HTTP requests. Device renderer is simulated in this test.
- Mobile ESLint and TypeScript: **passed**.
- iOS Release build for dedicated QA simulator: **BUILD SUCCEEDED**. Includes AuthSession, Crypto, WebBrowser and SecureStore native modules.
- Android Release build: **BUILD SUCCESSFUL**. Includes the same native authentication/storage modules.
- `git diff --check`: **passed**.

## Native UI evidence

Reinstalled and launched the Release apps with Argent on the dedicated iOS simulator `87952CD2-B760-40A1-AF11-5CE40995960B` and Android emulator `emulator-5554`. Opened `thumble://cloud`. Both display the cloud introduction, service URL and sign-in button together in landscape without scrolling. The blank service disables sign-in. No native-module error appeared during launch or routing. This is a one-off visual and accessibility-tree check, not a saved regression flow.

- [iOS cloud sign-in](ios-cloud-sign-in.png)
- [Android cloud sign-in](android-cloud-sign-in.png)

Review found and fixed three issues before final validation: a sign-in form below the landscape fold, rollback after a committed render receipt's response was lost, and duplicate exchange of a rotating refresh token. Targeted regression tests cover both asynchronous recovery fixes.

## Boundaries of this evidence

No live OAuth provider/client, deployed D1 database or public MCP endpoint was provisioned. Browser sign-in, live token refresh, marketplace clients and a real authenticated phone-render receipt still require the configured staging walk in [the pilot runbook](../../cloud-pilot.md). The tests verify phone delivery logic and server authority boundaries; screenshots verify the signed-out native screen. They do not establish a full native authenticated journey or game input compatibility. No physical phone or live Mac receiver was controlled during this work.
