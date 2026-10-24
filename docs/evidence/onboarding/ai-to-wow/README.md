# AI to WoW onboarding QA — 2026-10-24

The goal includes all four workstreams: remaining game/recovery QA, generated layout quality, a coherent AI-to-phone-to-Mac-to-WoW flow, and external pilot readiness. Completion is not established by source changes or stub input tests alone.

## Completion audit — original four items

This table is the current result; the chronological notes below retain earlier failures and their subsequent resolution. The scope comes from the four numbered next steps accepted by the owner: live QA; generated layout validation; unified onboarding; and Apple/Android/Google pilot readiness.

| Original requirement | Implementation and verification | Result |
| --- | --- | --- |
| Live modifier combinations, disconnect/reconnect, app restart, controller switching, and safe release | Real phone/Mac modifier reports and owner-confirmed release; visible ConsolePort modifier bars; physical switch/restore acknowledgement; two consecutive Android restart passes; real phone Menu open/close in WoW. Final native TLS regression independently exercises held-input release on pause, profile switch and disconnect, exact persistence after restart, and explicit resume. Stub reports are transport evidence; physical game evidence is recorded separately below. | Complete |
| Reject overlapping controls and undersized targets before saving or delivering | Shared logical-point capture geometry, 48-point button/trigger and 96-point stick minimums; cloud validate/save target ownership; current-canvas delivery revalidation; renderer rejection. Backend tests cover invalid save and delivery after viewport changes. A fresh deployed read-only validation rejected a B width of 16.9 points with `target_too_small`; earlier live invalid save produced no stored profile. | Complete |
| Clear AI connected → controller delivered → Mac ready → tested in WoW progress, with direct next actions | `cloudJourney` derives each stage and route from the actual account/device/revision, render receipt, pairing/adoption acknowledgement and scoped gameplay confirmations. Tests exercise all four stages and invalidate stale account, pairing, activation, game and connection contexts. iOS signed-out regression, physical Android 3-of-4 inspection, two-pass Android restart/resume regression and real delivered/adopted gameplay establish the UI and integration boundaries. | Complete |
| Verify Apple sign-in, Android full journey, and Google production OAuth requirements for external testing | Fresh Apple provider callback succeeded; Google branding/authorized domain saved and production publication confirmed in its provider console with owner approval; Android owner sign-in and registration, actual ChatGPT revision 2/delivery, rendered receipt, exact Mac adoption, and ConsolePort/WoW controls verified. Fresh hosted readback still reports delivery `50b5fe7f-0aa5-42f8-b848-df5e679de3e5` rendered for Pixel revision 2. | Complete |

Final current-checkout verification: [197 passing repository tests](final-unit-tests.txt), [native TLS receiver adoption and safety regression](final-receiver-regression.txt), and [Lua addon regression checks](final-addon-tests.txt). The native fixture requires permission to compile Swift and bind localhost; the restricted-sandbox attempt could not start it, while the permitted run exited successfully. Mobile lint and typecheck passed after the last recovery-help edit.

The later automatic-discovery request is also implemented and live verified below. This completes the original implementation/QA objective. Personal in-app gameplay confirmations were not fabricated to display a completed checklist; automated state tests verify the completed-stage rendering rules. Marketplace approval, store distribution, recruitment of external players and player completion of their own checklists were not among these four requested items. The latest mobile help wording is in source for the next build; the installed addon provides the automatic recovery now.

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

## Physical Android progress verification

The adopted controller's journey page showed **3 of 4 complete**, with AI connected, controller delivered and Mac ready checked. Tested in WoW remained numbered **4**, and the direct action was **Test this controller in WoW**. Returning left the controller paused.

The saved semantic fragment `qa-android-ai-wow-ready-progress.yaml` passed twice with the same `flow-execute` runner (13 checks/actions each, zero failures/errors). Pass 1 used freshly recycled services scoped only to the Pixel. The menu was staged before each fragment using the proven rotation correction. Pass 2's menu idle warning is explained by the live RTT label; its destination/action gates passed. A small pixel-motion warning also occurred on the journey; its explicit progress and action checks passed. These are fragment passes with external setup, not a completed self-contained launch-to-WoW QA regression. The strict QA launch/baseline gate is still outstanding.

| Fragment navigation | Identity | Readiness | Acceptance evidence |
| --- | --- | --- | --- |
| Menu → AI to WoW | From your AI | idle | 3 of 4; Mac ready checked; WoW numbered 4; Test this controller in WoW action |
| Journey → controller | Controller paused | idle | Controls remain paused |

## Android restart regression contract

Fixture: signed-in separate QA installation, cached rendered Pixel WoW Journey revision 2, prior pairing history, no current Mac connection and incomplete WoW checks. Every run starts by restarting the app; no external account reset or controller revision is created.

| Action | Required evidence |
| --- | --- |
| Restart QA app | Pick up where you left off; previously paired/reconnect history |
| Open AI to WoW | 2 of 4; exact cached rendered revision 2 |
| Inspect unfinished stages | Mac ready numbered 3; Tested in WoW numbered 4 |
| Use next action | Connect Mac opens the pairing page |
| Cancel pairing | Pairing identity disappears; journey remains incomplete |
| Return | Resumable getting-started baseline restored |

| Navigation | Identity | Readiness |
| --- | --- | --- |
| Launch → onboarding | Pick up where | idle |
| Onboarding → journey | From your AI | idle |
| Journey → pairing | A small screen | idle |
| Pairing → journey | Pairing hidden; Tested in WoW numbered 4 | idle |
| Journey → onboarding | Pick up where | idle |

The first restart recording had an invalid launch-plus-prerequisite declaration and captured no steps; it is retained as a diagnostic. The corrected walkthrough was recorded live before polishing. The executable regression has no raw coordinates, gestures, device IDs or literal credentials.

## Latest live results

The unchanged `qa-android-restart-persistence` regression passed twice consecutively: **22 passed, zero failures/errors each**. Pass 1 reported small pixel-motion idle warnings; pass 2 completed without warnings. A focused, full-resolution onboarding idle comparison afterward found **0% pixel mismatch**. This comparison establishes stability at rest; it does not explain or erase the earlier transition warnings.

Apple sign-in completed on a fresh browser transaction and returned to Thumble as the pilot owner identity. The preceding attempt returned `state_mismatch`; a fresh transaction succeeded without a code/configuration change. The cause of the first failure was not established. [Successful callback screenshot](apple-sign-in-complete.png). The account page is a deletion-management page, but no deletion control was selected or submitted.

After the restart regression, Argent entered a new private pairing invitation. The Pixel returned to Controller paused and the Mac acknowledged the same persisted Pixel layout at activation 9. No new cloud revision or delivery was required. Hosted receipt `50b5fe7f-0aa5-42f8-b848-df5e679de3e5` remained rendered.

Live WoW initially showed no visible response despite correct Mac A/stick reports. WoW reported gamepad support enabled and three device IDs, but its active ID returned no raw state. With the phone paused, entering `/console GamePadEnable 0` then `/console GamePadEnable 1` refreshed discovery. Subsequent Pixel right-stick input visibly rotated the camera; left-stick input visibly changed character position. This recovery is now described in WoW setup's connection help. It is a recovery observed in this session, not proof of the underlying cause.

Holding both triggers visibly changed ConsolePort's action bars. A Mac GameController observer recorded LT=1 and RT=1. A split-call Argent gesture did not release the contacts as intended and subsequent automated taps stopped navigating. Pressing Home on the Pixel released both triggers to **0**, with both sticks and all observed buttons also **0**. This proves background neutralization; it does not establish normal two-finger release or explicit-resume behavior. The QA app was restarted afterward and is disconnected. Separate normal A and single-stick gestures recorded press/movement followed by zero. The sandboxed observer could not enumerate the gamepad; these report logs came from the same observer run outside the sandbox.

Evidence: [A and movement reports](mac-gamepad-actions.log.txt), [both triggers and background release](mac-gamepad-background-release.log.txt), [WoW after camera and movement](wow-after-camera-and-movement.png). The current revision's jump/action binding, menu navigation, normal modifier-combination release, physical profile switching and player-confirmed final WoW checks remain outstanding. No WoW checkboxes were marked complete. The separate Android QA app's automation tap problem is still under investigation; a single physical tap was requested to distinguish app input from automation input.

Mobile lint and TypeScript checks passed after adding the gamepad-discovery help text. The installed Pixel QA artifact predates that final copy change; the help text has not yet been rebuilt onto the phone.

### Player confirmation and final session state

The owner subsequently reconnected the Pixel manually and confirmed **jumps work**. A fresh receiver read confirmed the exact Pixel WoW Journey layout acknowledged at activation 9. This completes the first working ChatGPT → Pixel → Mac → ConsolePort → WoW action journey. It does not complete the remaining release/menu/profile-switch regression cases.

Argent taps still failed after that manual reconnection, including a portrait Cloud controllers target. Opening that page by deep link worked, but interrupted the Mac connection. A requested standard-controller switch reached activation 10 while disconnected, so it is **not** a successful physical-switch test. The original Pixel layout was restored as activation **11**, queued for the next connection. Do not treat the earlier activation-9 acknowledgement as current activation-11 proof.

The final Android QA Release build succeeded (17 seconds, 821 tasks), including the recovery help text. It was not installed over the live session; the installed build still predates that copy change. Temporary Pixel pairing keys were removed from both Argent secret registries while preserving other entries. The QA-export receiver was stopped, its private invitation file removed, and the normal signed receiver reopened. It shows **Ready · scan to connect**. Only Pixel-owned Argent services were stopped. The phone is disconnected; no gameplay input remains active.

## Final-build follow-up

The newly built QA APK was subsequently installed with `adb install -r` successfully, retaining the cloud controller and account data. The visible controller still shows **Jump · ChatGPT** and the updated countdown button. This confirms the final artifact is installed; the added connection-help copy has not yet been inspected on screen. An ordinary portrait tap failed before installation, and a landscape menu tap failed afterward. A screen off/on cycle and normal owner unlock also did not restore Argent taps. No Argent update or tool installation was performed.

The complete current root test suite passed again: **191 tests, 191 passed, zero failures/skips**. These cover layout geometry, target-device validation, cloud receipt/account isolation, exact Mac adoption, activation-bound journey progress and connection recovery. Their scope remains distinct from the outstanding physical interactions.

| Workstream | Current authoritative evidence | Remaining completion evidence |
| --- | --- | --- |
| Live controls and recovery QA | Player-confirmed jump; visible camera/movement; real modifier reports and ConsolePort bar changes; background neutralization; repeated restart persistence | Normal simultaneous modifier release, game menu navigation, acknowledged physical profile switching, final player checks |
| Generated layout quality | Shared geometry tests; deployed validation/save/delivery gates; live rejected invalid layout with no write | No known implementation gap |
| Unified onboarding | Account/revision/pairing/activation-bound progress tests; physical 3-of-4 before restart and 2-of-4 afterward; resumable navigation regression | Finish the remaining physical checks without marking unperformed checks complete |
| External pilot readiness | Google production enabled; fresh Apple sign-in callback; actual ChatGPT revision/delivery; physical Android render and Mac adoption | Complete remaining physical QA above before declaring the full pilot QA complete |

## Physical modifier release and profile switching

After the owner reconnected the Pixel, the normal signed receiver reported **connected=true, ready=true, activation=11, delivery=acknowledged**. The read-only Mac GameController observer captured the owner's physical LT+RT chord together with A, followed by LT=0, RT=0 and A=0, with both sticks and all other observed buttons neutral. Separate individual LT and RT presses also returned to zero. This establishes normal physical modifier/button release, replacing the earlier outstanding release check. [Physical report log](mac-gamepad-manual-release.log.txt).

With that live connection intact, the saved Mac profile tool selected Xbox-style controller revision 1 at activation **12**. A fresh receiver status reported acknowledged and the physical Pixel's accessibility tree showed the standard A/B/X/Y, Move/Look layout. Selecting Pixel WoW Journey's saved local revision 1 restored its exact cloud-revision-2 content at activation **13**. A fresh receiver status again reported **connected=true, ready=true, delivery=acknowledged**. The physical phone showed **Jump · ChatGPT**. This proves live physical switching and restoration; the switches originated from the Mac profile tool, not the phone's Profiles page.

The phone then reached **Your free time is up**, with **0:00** remaining and live input gated. No free-time reset, Pro bypass, purchase or entitlement change was performed. [Gate screenshot](pixel-free-time-ended.png). The current Mac activation is 13; the current exact layout was acknowledged before the gate appeared.

At the owner's request, direct computer use verified WoW's menu opens with Escape and closes with Escape. A read-only in-game query showed `GetBindingAction("PADFORWARD")` is `TOGGLEGAMEMENU`. [Direct menu-open screenshot](wow-menu-direct-open.png). This confirms the game's menu and current binding; it does **not** prove the remaining phone Menu → WoW interaction. Argent still reported tap completion without navigation, including the free gate's practice button. Full end-to-end Menu verification and final onboarding confirmations therefore remain incomplete.

Argent deep links still navigate successfully: `thumble://wow-setup` opened the actual final-build WoW setup screen without resetting saved controller data. Normal taps, Tab and Arrow Down did not produce navigation or visible focus on that screen. The owner asked for autonomous computer-use/Argent QA rather than more manual checks. Approval was requested to update shared Argent tooling from 0.25.0 to the advertised 0.30.1; no update has been performed pending that explicit approval. The final unverified live Menu probe also requires valid controller access after the exhausted free timer.

## Approved Argent update and native input diagnosis

The owner explicitly approved the shared-tool update. Argent's update tool completed the global upgrade; the installed package and CLI report **0.30.1**. The restarted tool server was independently checked outside the filesystem/network sandbox and reported **process alive, health ok**. The sandbox's earlier unreachable report was not a real server failure.

A fresh portrait tap on the observed WoW Classic Era row still produced no navigation. The same operation through the updated Argent CLI also returned `tapped: true` without changing the phone's screen. This rules out the MCP adapter as the sole cause.

Logs scoped to the actual phone-side screen-sharing agent contain **Unable to inject an input event** for the matching ACTION_DOWN and ACTION_UP at x=540, y=2007, display 0. Android's system InputManager independently reports input-event injection from that agent PID failed at both matching times. [Scoped injection-error evidence](argent-input-injection-errors.log.txt). The logs establish rejection of injected input, not its underlying cause. No Android security setting was weakened, and no alternate raw input injection was used. The QA app's visible WoW setup screen remained at step 1.

The update is complete; successful phone touch automation and the final live Menu check remain unverified. The free controller timer is still exhausted. Full goal completion remains unproven.

An additional clean-process retry ruled out an orphaned old agent: after scoped cleanup, neither the Pixel's screen-sharing/instrumentation processes nor a matching host control process remained. Fresh services still returned `tapped: true` on the same observed portrait target without navigation. Cleanup afterward again left no Pixel automation processes. Repeating package updates or service restarts is not supported as a fix by this evidence.

## Android rejection cause: stale synthetic pointers

Android's InputDispatcher now supplies the exact rejection reason: `Invalid DOWN event - pointers already down for device DeviceId(-1): {DeviceId(-1): {0, 1}}`. Matching UP events fail because Android still has two pointers down. A focused `dumpsys input` confirms the filter verifier retains pointer IDs 0 and 1 for injected device -1, with downTime 188468648000000 ns. Dispatch is enabled, unfrozen, and Thumble has focus. This establishes inconsistent synthetic touch state as the immediate cause; the earlier split-call two-finger modifier test is the leading origin.

A single documented Android system CANCEL was attempted as cleanup, without changing app data or security settings. It was rejected because the system command supplies device 5 and one pointer, while the stale gesture belongs to device -1 with two pointers. The exact log says `Got ACTION_CANCEL, but the pointers don't match`. No successful cleanup or restored Argent touch input has yet been verified. A correct matching gesture cancellation remains needed; another generic service restart is not supported by these findings.

## Matching cancellation and resumed physical QA

A one-shot local Java helper constructed only an ACTION_CANCEL matching the observed gesture: device -1, pointer IDs 0 and 1, FINGER tools, source 0x5002, display 0, and the original downTime 188468648 ms. Android's existing shell input-injection API returned `accepted=true`. Immediately afterward, the filter verifier reported `Touching pointer IDs by device: {}`. No app data, entitlement, Android security settings, or user credentials were changed.

The original failing portrait tap on the Classic Era row then advanced WoW setup from step 1 to step 2 through Argent. This verifies the fix against the original symptom. Subsequent ordinary taps and scrolls also worked; a final dispatcher read still showed no touching pointers. This establishes the retained gesture as the immediate cause of the rejection. The most likely originating operation remains the earlier split-call two-finger QA gesture.

The current receiver's QR pairing link was decoded locally from its UI screenshot and opened through Argent. Fresh receiver status reported connected=true, ready=true, revision=13, delivery=acknowledged, with the exact Pixel WoW Journey content including Jump · ChatGPT. The phone then showed the expected exhausted-time gate. Continue in practice mode dismissed that gate and disconnected live play as intended. The landscape menu still requires Argent's observed rotation correction (screen x,y maps to injection 1-y,x); this is separate from the cleared touch-state fault.

WoW setup preserved Classic Era and returned to step 2 while disconnected. Expanding and scrolling connection help exposed the installed GamePadEnable 0 / GamePadEnable 1 discovery recovery copy. Both accessibility inspection and the [physical help screenshot](pixel-wow-recovery-help.png) verified the content. Full phone Menu → WoW verification remains incomplete because live controller time is exhausted. No unchecked gameplay confirmation was marked complete.

## Authorized QA timer reset and phone Menu pass

The owner explicitly requested resetting the QA build's timer and completing the live Menu test. A temporary Gradle init script rebuilt only `com.thumble.android.pilotqa` with debugging enabled; installation with `adb install -r` preserved the account, cached ChatGPT controller, and onboarding data. With the QA process stopped, only the `used` float in its `tapping.demo` preferences was reset to 0. A private pre-reset backup remains within that QA app's files. No reset API, entitlement bypass, or debug change was added to repository source or the regular Android package.

Because the Mac mirrors the highest usage counter, the signed receiver was launched against `/tmp/thumble-menu-qa-profiles`, a separate directory containing a copy of the existing profile store and a fresh QA demo record. The regular receiver was stopped and its original `demo.json` remained at used=1800. The QA receiver's identity is `61f0a5c5-ed54-466d-9882-aff884d3bc77`; the copied exact Pixel layout remained at activation 13. The QA phone showed 30:00 after the reset and 29:59 after connecting, with ready=true and connected=true from the isolated receiver. Pro remained false.

The initial Menu attempt after restarting the receiver did not open WoW's menu. With the phone controller paused, computer use ran the documented `/console GamePadEnable 0` followed by `/console GamePadEnable 1` recovery. After returning to the controller, an Argent tap on the phone's observed Menu control opened WoW's actual menu. A second phone Menu tap closed it and returned to the game. No Escape key or Mac menu click was used between those two phone presses.

Evidence: [menu open after phone press](wow-phone-menu-open.png), [menu closed after second phone press](wow-phone-menu-closed.png), and [real Mac GameController Menu reports](mac-gamepad-phone-menu.log.txt). The report shows MENU 1→0 twice, with sticks, triggers, and other observed buttons neutral. This completes the previously outstanding physical phone Menu → receiver → ConsolePort/WoW check. The phone controller was paused afterward; no unperformed gameplay onboarding confirmation was marked complete.

## Automatic discovery after a receiver restart

Thumble Bridge now includes `Discovery.lua`, loaded by its TOC. On macOS with ConsolePort and gamepad support enabled, it observes receiver disconnects, waits for neutral input and refreshes gamepad discovery through WoW's configuration APIs. Recovery is deferred in combat, respects a saved character opt-out, rate-limits retries and stops retries after configuration errors. Stale mapped entries require a bounded 30-second retry window after disconnect; detected button/stick/trigger input cancels that window. With no mapped devices, low-frequency retries continue to support launching the receiver later. A healthy mapped controller outside a recovery window causes no refresh. This is addon configuration, never generated chat text, binding changes, or gameplay input.

The original single-refresh prototype executed in WoW but did not restore the phone Menu response. That live failure motivated the bounded retry window. The final installed addon was tested with WoW open on the same safe Classic Era character and the real signed receiver using `/tmp/thumble-menu-qa-profiles`. After a receiver stop/start, `/tbbridge discovery` reported six automatic refreshes during the bounded window. The Pixel re-paired, acknowledged activation 13, and its Menu button opened WoW's menu; a second phone Menu press closed it. No manual GamePadEnable commands were run during this final restart test. [Automatic recovery menu open](wow-auto-discovery-menu-open.png), [menu closed](wow-auto-discovery-menu-closed.png). The phone was left paused afterward.

The repository suite passed 197 tests. Lua addon checks additionally cover rate limits, stale entries, rescan-event recursion, neutral controls, combat deferral, opt-out, disabled gamepad support, macOS/ConsolePort/API gates, unreadable device state and configuration errors. Mobile lint and typecheck passed after updating recovery-help copy in source. The mobile copy has not been rebuilt onto the Pixel in this change; automatic recovery is provided by the updated installed WoW addon.
