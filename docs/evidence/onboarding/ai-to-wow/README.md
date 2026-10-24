# AI to WoW onboarding QA — 2026-10-24

The goal includes all four workstreams: remaining game/recovery QA, generated layout quality, a coherent AI-to-phone-to-Mac-to-WoW flow, and external pilot readiness. Completion is not established by source changes or stub input tests alone.

## UI regression contract

| Baseline/action | Required outcome | Evidence |
| --- | --- | --- |
| Start the Release app on the named iOS QA simulator; normalize optional welcome | Resumable Getting started screen | Launch + destination identity and idle |
| Open From your AI to WoW | Four-stage progress with a sign-in next action | Journey identity; current-account explanation; sign-in action |
| Open sign-in next action | Cloud account connection screen | Cloud destination identity and idle |
| Return without signing in | No delivery, Mac-ready or WoW-success claim | Journey remains at its initial state |
| Restart and repeat | Saved setup still resumes, no fabricated achievements | Two consecutive unchanged flow passes |

Baseline: isolated QA installation, no cloud account, receiver disconnected. The optional welcome is setup normalization; it is not acceptance evidence. No external account or player game state is changed by this flow.

## Current verification

- Shared layout quality checks reject undersized targets/sticks, overlapping capture geometry and controls obscured by Chat/menu. Cloud validation/save require an owned target device; delivery rechecks its current canvas. Existing saved revisions remain readable.
- The real TLS receiver regression (non-HID fixture) passed modifier+button+movement report encoding, release on pause/profile switch/disconnect, exact persisted layout after fresh pairing and a recreated production phone core, and explicit-resume gating. This is transport/report evidence, not live WoW modifier proof.
- Updated iOS Release simulator build succeeds from `apps/mobile/ios/Thumble.xcworkspace`, scheme `Thumble`.
- Physical provider sign-in, Android's full authenticated journey and live in-game modifier verification remain separate required checks.

## Google public sign-in — browser verified

On 2026-10-24 the owner approved saving `thumble.io` as an authorized domain and setting the homepage, privacy and terms links to `https://thumble.io`, `/privacy` and `/terms`. Google reported **Branding changes saved!**. The owner separately approved the final public-access confirmation; Audience now reports **In production**. Verification Center reports that data-access verification is not required because the app requests no sensitive or restricted scopes. Branding is not yet shown to users; this is separate from publishing status. Apple live sign-in remains unverified.

## Latest build and regression results

- Root tests: 187 passed, zero failures. Mobile lint and TypeScript checks passed.
- Android arm64 Release APK: Gradle build succeeded (821 tasks). This is a debug-key-signed pilot artifact, not a Play Store release.
- The latest iOS Release build passed all signed-out journey assertions (29 passed, zero failures/errors). Pixel-motion readiness warnings occurred around cloud modal presentation and final dismissal; destination identities and actionable controls passed. Earlier repeated passes have the same disclosed modal-transition warning. These are not evidence of authenticated delivery or gameplay.

## Pilot deployment

Published the validated source snapshot to the existing Worker with `--keep-vars`. Version **a882a3fa-a82c-4a45-be7a-037243fdfe86**. Snapshot bundling and both bundled Worker/D1/OAuth runtime suites passed; the current combined suite passed 191 tests. Existing canonical routes, assets, provider secrets and concurrently deployed email sign-in were retained. A live call using the old validate arguments now returns `invalid_request`, confirming the new tool argument contract is active; connected AI clients must refresh their tool definitions before validation/saving. No database migration was required.

The existing Pixel app could not be updated because its signing certificate differs. A separate `com.thumble.android.pilotqa` installation was built and installed successfully, preserving the existing app and its data. The app ID override is build-only, stored in `/tmp/thumble-pixel-qa.gradle`; it is not a shipping configuration change.

## Physical Android sign-in

The Pixel 7 completed Google account selection as the existing owner identity, showed the Thumble phone consent page, returned to the app and registered device `2661910d-39d5-471c-9991-a658ad3d156d` (**My Android phone**). A separate read-only hosted `list_devices` call confirmed it under the same account as the existing iPhone. Its measured controller canvas is **898.2857 × 335.6190 logical points**, rather than the whole physical screen. The live server accepted viewport synchronization. This proves sign-in and registration; delivery, Mac adoption and game checks still need their own evidence.

The first Android walkthrough and the consent continuation were recorded in `.argent/flows/qa-android-ai-wow-live.yaml` and `qa-android-cloud-consent.yaml`. These are diagnostic recordings, not two-pass automated regression claims. The first landscape sign-in tap caused no navigation; returning to portrait and tapping succeeded, while retaining the landscape canvas measurement.

## Physical Android cloud delivery and quality gates

Using the connected hosted tools from Codex, validated and saved `pixel-wow-journey-v1` revision 1, then delivered it only to the Pixel. Delivery `c3646fb7-2b1b-4c10-b1c9-78de9767b98d` advanced from queued to received to **rendered** at `2026-10-24T11:55:26.438Z`, after opening practice through the app. The screenshot showed all 18 controls. This is hosted-tool-to-Android evidence; it does not substitute for a successful new ChatGPT browser request. Browser typing was intercepted before submission, and subsequent browser control timed out.

Live negative checks also passed: validation named an undersized B control; attempting to save `qa-rejected-pixel-layout` returned `invalid_layout` with both the A/X overlap and B minimum-size correction. Reading that ID afterward returned `not_found`, so the invalid candidate was not written. Canvas reports updated to 846.4762 × 387.4286 after opening the landscape controller with hidden system bars; the server used those updated dimensions in the negative check.

The practice fragment records the successful cloud-to-controller navigation only. Landscape menu taps did not navigate, including after a scoped Pixel transport restart. Those unsuccessful taps were removed during polish; no gameplay or successful menu-tap assertion is claimed. Owner assistance to open the menu was requested. The fragment is recorded and polished, but has not yet received its required replay passes.

Screenshots: [Pixel signed in](pixel-signed-in.png), [Pixel rendered controller](pixel-rendered.png). The receiver was restarted with a fresh pairing code; its live status reports connected=false and ready=false, with the old active profile unchanged. No game input has been resumed in this session.

## Pairing follow-up and current boundary

The owner opened the Pixel menu and scanned the Mac QR. Live phone UI showed Controller paused, and the receiver reported connected=true, ready=true, activation revision 8. The existing layout was still `cloud-7e162aad5e900775815ddaa99c1bf4cb5fee498d` (WoW cloud adoption test). A later owner reply said adoption was done, but a fresh receiver/phone check still showed that old layout. Adoption of the Pixel revision therefore remains unproven, and inspection of the Cloud controllers page was requested.

Tab/Tab/Enter did not open the landscape menu. The exploratory keyboard and pairing recordings are retained under `recordings/*.yaml.txt` as diagnostics, not runnable regression tests. Permission and scanner waits in the pairing take became stale while the owner completed those steps; they must not be converted into passing assertions.

Live QA also found a menu-label mismatch: offline cloud practice displayed the local default profile name. The menu now derives its name from the same offline cloud selection as the renderer, while connected mode continues to show the Mac layout. Mobile lint and typecheck passed; a refreshed Pixel QA build was started.

## Actual ChatGPT revision and delivery

After explicit owner authorization, sent the prepared prompt to the existing ChatGPT chat **Create controller revision** (`6adc04d3-b338-83ed-874c-30d829cbbbb5`). ChatGPT completed the request; a read-only hosted `get_profile` independently confirmed revision **2**, with A labelled **Jump · ChatGPT**, and the Pixel Cloud controllers page showed that revision. A follow-up in the same approved test reserved idempotency key `3703a957-a1f7-49e7-9e94-559f90d158f7` for one exact delivery. After ChatGPT completed, repeating the identical delivery parameters returned its existing receipt **50b5fe7f-0aa5-42f8-b848-df5e679de3e5**, created at `2026-10-24T12:13:59.913Z`, already **received**. This was an idempotent readback of the ChatGPT-created delivery, not a second queue entry. Rendering and Mac adoption remain separate checks.

A direct Argent `thumble://cloud` route opened the correct QA account/device without browser typing; explicitly launching `com.thumble.android.pilotqa` confirmed that target. Its page showed Connect Mac, so the earlier receiver connection cannot establish this QA app's pairing. Direct-route entry is functional setup and is not claimed as a full navigation regression. A direct D1 receipt query failed with Cloudflare authorization code 7403; no credential or permission change was attempted. Hosted tools provided the successful independent evidence instead.

## Confirmed Android Mac adoption

The receiver's documented private `TAPPING_INVITATION_FILE` QA export enabled Argent to enter a fresh pairing link via a secret placeholder, without exposing the invitation in chat, logs or source control. The tool server resolves secrets from its home-directory registry, so the temporary key was stored there while preserving existing entries.

Confirmed the physical Pixel's landscape input mapping workaround: the observed menu centre `(0.967, 0.063)` opens correctly when sent to Argent as portrait-natural `(1-y, x) = (0.937, 0.967)`. This is a tool-coordinate calibration, not an app UI fix or an allowed raw target in the strict QA regression. The menu then exposes ordinary portrait semantic targets.

Through the actual app menu → Cloud controllers → Use this controller on Mac, adopted ChatGPT revision **2**. Phone UI showed **Jump · ChatGPT** and **Controller paused**. Hosted receipt **50b5fe7f-0aa5-42f8-b848-df5e679de3e5** reached **rendered** at `2026-10-24T12:20:38.084Z`. The Mac saved `cloud-444ead90cc437b16b93890560d7f399b72227bac` at activation **9**.

An older duplicate receiver process was writing disconnected status over the active process's status file. Its exact executable and start time identified it as the earlier instance; it was terminated. A fresh process inventory showed only the current QA receiver, and a fresh `controller_status` then reported **connected=true, ready=true, revision=9, delivery=acknowledged**. This establishes actual Mac acknowledgement; live WoW actions remain unverified for this revision.
