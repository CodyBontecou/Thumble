# Mobile production submission status

## November 12, 2026 — 1.1.0 submitted to both stores

- Source `4424382` (redesign, Codex in-app editor branch merged, text-only controller labels, ScrawlKit excluded from production builds). 304 tests, mobile lint and typecheck pass.
- **iOS 1.1.0 (13): Waiting for Review.** Build `73df1bb0-09c2-463d-a50c-2495f7dd9bc0`; hashes are in `.claude/worktrees/mobile-1.1.0/build/ios-release-1.1.0b/release.json` and `upload.json`. Two clean-install Release simulator launches passed; the TestFlight build launched on a physical iPhone 13 Pro Max (iOS 27.2) to onboarding and loaded StoreKit prices. Build 10's submission was cancelled; the version was renamed 1.0.0 → 1.1.0 and resubmitted as submission `6cd99fdb-347c-4280-8c7a-ffd5cb19714b` with the same 8 items (version, 4 subscriptions, subscription group, 2 lifetime IAPs). Review notes updated. Manual release.
- **Android 1.1.0 (7): Changes in review**, full production rollout, replacing 1.0.0 (4). Built locally with EAS (cloud queue stalled), AAB SHA-256 `2cca4892f1b0b49a5601c948a1d93fe8998e31a2f3500f04c8ccabf1f48924b1`, uploaded through the Play API. The `thumble-play-verifier` service account was granted "Release to production" for Thumble on Nov 12 at the owner's request. Not tested on a Play-installed Pixel build.

## November 10, 2026 — iOS launch rejection diagnosed

- Apple rejected **1.0.0 (6)** under **2.1(a)** after a launch crash on iPhone 17 Pro Max, iOS 27.0. Both reviewer crash reports identify the same native-module abort. The archived binary UUID `BBF78427-318C-3DFB-8309-638834148045` matches the reports.
- Reproduced using the archived build's exact Hermes bundle and assets in the iOS 27.0 simulator. LLDB captured `Unhandled JS Exception: TypeError: profile must be an object` from `Connection` initialization. The bundle reads `defaultProfile` but contains no export for it. The assembled text-only release combined newer connection code with the older controller package entry point.
- The current checkout includes the `defaultProfile` export. Its fresh Release simulator build reaches Welcome successfully. Added `eas-build-post-install` type checking to prevent packaging unresolved imports. An in-memory reproduction of the missing export produces TS2305 errors at the actual connection and calibration imports. The normal build hook, mobile lint/typecheck, and 74 controller/connection tests pass.
- A corrected App Store build still needs to be prepared from the chosen release source. For the older text-only baseline, keep its Xbox default when reconciling `defaultProfile` with the connection code. The current checkout uses the ConsolePort default and includes the newer UI and plans.

## November 3, 2026 — Android live

- **Android is publicly available on Google Play** at [com.thumble.android](https://play.google.com/store/apps/details?id=com.thumble.android) as **Thumble: Gamepad for Mac**. Verified from the public US listing: rated Everyone, in-app purchases, 1+ downloads, updated October 27, 2026, with the reconnect-fix What's new text, so the live build is 1.0.0 (3). Play Console was not checked (not signed in), so the exact approval time and per-country rollout status are unconfirmed.
- iOS status below has not been rechecked.

## October 27, 2026 — reconnect release

- **Mac Receiver 1.0.3 (4) is public** (Nov 11) at [latest download](https://thumble.io/downloads/receiver-latest.dmg) → [1.0.3 DMG](https://thumble.io/downloads/Thumble-Receiver-1.0.3.dmg). Hotfix for macOS 27.2: the virtual gamepad now presents as an Xbox Series X|S controller so GameController (and WoW) detect it. SHA-256 `785cef6e370c5f9028899fff61b5e2e9a2273ef00d381ca576a2847565c4bf02`; app/DMG notarized and stapled; Worker version `216e9285-6bce-4171-b891-2e80d5a73210`. See `docs/releases/macos-receiver-1.0.3.json`.
- **Mac Receiver 1.0.1 (2) is public** at [latest download](https://thumble.io/downloads/receiver-latest.dmg), resolving to the immutable [1.0.1 DMG](https://thumble.io/downloads/Thumble-Receiver-1.0.1.dmg). Universal Developer ID signature, Apple app/DMG notarization, stapling and Gatekeeper checks pass. Public download exactly matches the local notarized package; SHA-256 `4377bfa6d5d6b4840f376dd598e2738c1df558717fc86e50b2fc7f7c00dc50e6`. Prior 1.0.0 download remains available. Download Worker deployment `7aac1e48-b8b4-4c52-8a04-678b2004d61e` preserves the private review route and old public artifact.
- **iOS 1.0.0 (6): Waiting for Review.** Build `a4b1530c-b36f-4a86-a5ec-79cea8639515`; submission `473b3f77-757b-4244-ae2a-17ee803eee83`, submitted **12:42:34 UTC / 08:42:34 America/Puerto_Rico**. Includes the existing lifetime Pro review item, two items total. Prior submission/build 3 removed to replace it with the fixes. Existing manual release setting retained. Readiness validation: zero errors, zero blocking. Source is the previously submitted text-only iOS baseline `0ce92c8` plus tested OAuth and reconnect changes, excluding unrelated UI changes. Built through EAS locally with existing Apple distribution identity/profile; private signing key was kept on the Mac.
- **Android 1.0.0 (3): submitted for production review; Google automated quick checks running.** Play Console confirms Changes in review for “1.0.0 (3) - Reconnect fixes,” replacing the earlier version 2 rollout. Remaining approved listing, countries and declarations remain in the submission. Full rollout in all targeted countries; managed publishing remains off, so Google publishes after approval. Submission is complete; this is not approval or public mobile availability. (Superseded: approved and live as of the November 3 check above.)
- Android EAS build `e64991cb-d7b5-4c01-9eed-d8f440248b91` finished successfully; version/package, bundletool validation and JAR signature verified. Production signing certificate matches version 2. AAB SHA-256 `6e5284e6090c007915793c883befcf7d799ae7f4b4f7bb8bd1b6428fbd0107ed`. User explicitly approved EAS source uploads after automatic approval review required specific authorization.
- Private full-access reviewer receiver also updated to 1.0.1, signed/notarized/stapled, with existing authentication preserved. Authenticated download matches the new package. Existing reviewer URL remains unchanged.
- Five download/security tests and 40 connection/pairing tests pass; mobile lint/typecheck pass. Receiver process-restart, TLS/credential persistence, layout and Pro acceptance evidence remains in the linked QA reports. [Release receipts and source hashes](../evidence/reconnect-release-2026-10-27/release.json), [iOS receipt](../evidence/reconnect-release-2026-10-27/ios-submitted.png), [Android receipt](../evidence/reconnect-release-2026-10-27/android-submitted.png).

The earlier October 27 entries below describe the superseded initial submission and local verification checkpoints.

## October 27, 2026 — live store verification

### iOS: submitted, waiting for review

- App `6826421489`, bundle `com.thumble.ios`, current listing name **Thumble: Gamepad for Mac**.
- Submitted version **1.0.0 (3)** and **Thumble Pro Lifetime** (`thumble_pro_lifetime`, product `6826421543`) together at **10:14:29 UTC / 06:14:29 America/Puerto_Rico**.
- Submission `afbacad5-d6c8-4f9f-85b1-7393441a9a90`: API returned `WAITING_FOR_REVIEW`; App Store Connect visibly confirmed **Waiting for Review**, **2 Items**.
- Release remains **manual after approval**. This is submission, not approval or publication.
- User explicitly authorized production submission and separately approved publishing the completed App Privacy declaration and its accuracy agreement.
- Privacy published: Name, Email Address, User ID, Device ID, Other User Content, Product Interaction, Other Diagnostic Data. Each is for App Functionality, linked to user identity, not used for tracking. Reconciled against cloud identity/session schema, device/profile/delivery retention, and Apple's current privacy definitions. Photos/video collection was not declared based on framework permission strings.
- `asc validate` checked the attached IPA and public metadata URLs: **0 errors, 0 blocking**. The pre-attachment IAP warning was resolved by adding IAP version `050aeec8-3658-401e-ae01-935f70dce16e` to this submission. Marketing URL resolving to the homepage is nonblocking.
- Submitted build is the existing October 24 archive from commit `0ce92c8` plus the tested OAuth fix, described in `build/marketplace-demo/review-build-manifest.json`; subsequent local changes are not in build 3.
- Evidence: [review receipt](evidence-2026-10-27/ios-submitted.jpg), [privacy publication agreement](evidence-2026-10-27/privacy-confirmation.jpg).
- [Review console](https://appstoreconnect.apple.com/apps/6826421489/distribution/reviewsubmissions).

### Android: submitted; automated pre-review checks running

- Mac receiver restart persistence subsequently fixed and verified locally: Keychain-backed identity/phone credential and stable port; Pixel automatically reconnected after two receiver restarts with Pro and layout restored, without another pairing link. Signed local receiver only, not yet notarized/published. [Receiver restart evidence](../evidence/receiver-restart-2026-10-27/README.md).

- Reconnect fix verified locally on October 27: phone app restart and checkout-style background/foreground automatically restore the same running Mac receiver and Pro access. Local Android test version 1.0.0 (3) and updated signed receiver are not submitted/published. Existing Android review remains version 1.0.0 (2). See [reconnect verification](../evidence/reconnect-2026-10-27/README.md).

- Google Play developer `8478281120215349264`, app `4973267958607968038`, package `com.thumble.android`, name **Thumble: Gamepad for Mac**, English (US), free download. **Production submission confirmed October 27 at approximately 11:11 UTC / 07:11 America/Puerto_Rico.**
- Production **1.0.0 (2)** built and signed by EAS; project `33a59fef-e85d-4af9-9d7d-8bd6f59727eb`, build `5190e44b-e08f-4909-aab0-9d92a37d898f`, finished October 27 at 10:54:17 UTC. Remote production keystore generated by EAS. Build includes current working source; later edits require a new build.
- AAB SHA-256 `acd7fbc8e90e10e93d5b6d2a1d20c46f761f1938f854585b30d78d9c12d34675`; bundletool validation and JAR signature verification passed. Package/version verified, min SDK 26, target SDK 36, BILLING permission present. Emulator APK generated from this exact AAB launched successfully. A no-charge Google Play license-test purchase and explicit restore passed on Pixel 7 using a matching-key test APK generated from this exact AAB; see the purchase evidence below. A paid transaction / Play-installed binary was not tested.
- Bundle uploaded and accepted by Play Console in production draft `1.0.0 (2)`, with mapping file and native debug symbols; estimated delivered size 16.7 MB. Release notes saved. Final release preview passed with **Ready to release**, and release was saved to Publishing overview.
- User approved export certification and IARC terms. Content rating completed: ESRB Everyone, PEGI 3, USK 16, Brazil 14; native game-chat communication declared. Privacy URL, no ads, government/financial/health declarations, Tools category and public contact details saved.
- Signed unlimited review receiver copied separately from the existing local-testing receiver; production demo and Pro behavior unchanged. User explicitly authorized private delivery and Apple notarization. Apple submission `248fa2e7-6c9c-4d62-ab62-5f14d034330f` **Accepted**, stapled, validated, Gatekeeper **Notarized Developer ID** accepted.
- Private review ZIP stored at a fixed R2 object, served through `/downloads/app-review/receiver.zip` with HTTP Basic authentication. Only its SHA-256 credential hash is stored as an encrypted Worker secret. Anonymous and incorrect credentials return 401; correct credentials return 200; responses are private/no-store. Four security/regression tests pass; all 16 combined download/entitlement/monetization tests pass. Full private download checksum matches notarized local package (`a373bff659b12529ef04570ccc9234700da6679560bf2dcc1b6bfe1025f55f73`). Worker version `b7b913b1-cdbf-4a2b-8cfd-ddf299b9a23d`. Credentials are ignored owner-only local files and Play private reviewer fields, never this ledger.
- Reviewer full-access instructions saved in Play Console: private notarized Mac receiver, same-Wi-Fi QR pairing, unlimited time without purchase or trial, no Thumble account required.
- Google reauthentication succeeded. User approved app-only purchase verifier setup. Service account `thumble-play-verifier@crested-drive-492000-u7.iam.gserviceaccount.com` is active with only Thumble financial/order permissions and their required view dependencies. Credential stored encrypted as `GOOGLE_CREDENTIALS_JSON` on existing `thumble-purchases` Worker. Existing Apple configuration preserved; 12 entitlement/monetization tests passed. User explicitly approved Android Pro terms. Product `thumble_pro_lifetime`, name Thumble Pro Lifetime, purchase option `lifetime` (Buy, backwards compatible) is Active in 174 Google billing countries/regions, US USD 19.99 with Google-converted regional prices.
- Store text, icon, feature graphic and two actual production-app Android screenshots prepared/uploaded. User approved the AI declaration on the newly composed feature graphic; listing finalized and ready for review.
- User explicitly approved ages 13–15, 16–17, 18+ and all supported countries. Saved all 178 distribution entries (177 named countries/regions plus Rest of World).
- Data safety draft prepared from current source: optional account identifiers, device identifiers, purchase history, diagnostics, app interactions and controller content; collected, not shared under Google's exceptions; encrypted in transit; account-deletion privacy URL. Final Data safety declaration saved after target audience completion.
- Advertising ID declaration saved as No after verifying no AD_ID permission or advertising SDK usage in the production artifact/source. All 11 setup tasks complete; release preview shows Ready to release. Final **11-change submission** confirmed. Play Console visibly shows **Changes in review**, including production `1.0.0 (2)` Start full rollout, countries, store listing, ratings, target audience, privacy, Data safety and app category. Automated quick checks are still running (UI estimated up to 13 minutes); changes automatically proceed to review if checks pass. No manual action remains to send this submission.
- Live production Android verifier rejects forged purchase proof with 422. After publishing the same version to the internal license-tester track, a Google no-charge test purchase completed and the normal production receiver accepted the server-signed Pro grant. Explicit Restore Purchases completed before and after app restart, with ownership retained and receiver pro=true. Checkout/restart required fresh Mac pairing. See [purchase and restore evidence](../evidence/google-play-purchases-2026-10-27/status.md) for scope and limitations.
- **Managed publishing off**: Google will publish after review approval. This is submission, not approval or live availability. Evidence: [Android submission receipt](evidence-2026-10-27/android-submitted.jpg), [release validation](evidence-2026-10-27/android-release-ready.jpg), [active Pro](evidence-2026-10-27/android-pro-active.jpg).
- Mobile lint and typecheck passed. Local disk space improved; cloud build avoided a large local native build.
- [Play dashboard](https://play.google.com/console/u/0/developers/8478281120215349264/app/4973267958607968038/app-dashboard).

## Historical preparation — October 23, 2026

The notes below are historical; the October 27 status above supersedes their submission and privacy status.

App: 6826421489 / com.thumble.ios / Thumble: Phone Controller.
Version: 1.0.0, manual release. Pro: thumble_pro_lifetime / 6826421543, $19.99 USD non-consumable.

Prepared/saved:
- App Review contact: Cody Bontecou, codybontecou@gmail.com, +1 808-384-1335.
- Subtitle: Your phone. Your controller.
- Privacy URL https://thumble.io/privacy; support URL https://thumble.io/support.
- Standard Apple EULA configured in the app; purchase/privacy/support links now present in production and sandbox source configuration.
- Age-rating questionnaire completed: no ads, gambling, violence or mature material in the app; messaging declared. Private controller profiles do not constitute broad distribution of user content under Apple’s questionnaire definition, so user-generated content is false.
- User approved v1 text/built-in symbols. Remote spell/ConsolePort artwork imports removed from the mobile renderer. Content rights set to no third-party content for that text-only release.
- Receiver 1.0.0 is signed, notarized and published on thumble.io.
- Review notes drafted in review-notes.txt; placeholders are explicit and not uploaded as final instructions.
- Two native 6.5-inch iPhone screenshots uploaded and processed successfully. Pro review image shows the real StoreKit $19.99 product; the non-consumable is READY_TO_SUBMIT.
- Paid/Free Apps agreements, banking, tax and DSA compliance checked in the authenticated account; all currently active/complete. See account-readiness.md for dates.
- Current text-only mobile renderer compiled in a standalone Release simulator build; mobile lint/typecheck, purchase/config checks and screenshot validation passed.

In progress:
- New production-configured iOS archive, upload and attachment after cloud code/signing is stable.

Remaining external/dependent checks:
- The user confirmed another chat owns Cloud Controllers. Coordination authorized; message sent to Improve agentic onboarding (2), thread 01a16aef-48e6-7d40-9263-5646e615775b. It is implementing Better Auth plus Apple/Google sign-in. Do not undo its files or remove cloud unilaterally.
- Cloud sign-in, in-app account deletion, real phone delivery/render and provider production availability must pass before submission if included.
- App Privacy publication must match the final cloud implementation, including collected account/profile/session/delivery data. The in-app browser is authenticated; the declaration remains unsaved/unpublished. Automatic approval review rejected saving a broader draft containing unverified Photos/Videos and other data categories. The modal was cancelled. Reconcile the final cloud inventory and obtain approval for exact verified disclosures before retrying; do not bypass the rejection through another interface.
- Cloud owner currently reports a Google test-user-only pilot. Public provider availability, account deletion with Apple revocation and live authenticated phone delivery still require completion/evidence. Existing source does not yet enable Better Auth account deletion.
- Real TestFlight purchase, restore and receiver unlimited-access verification. Local StoreKit fixture tests cannot prove this.
- Physical-device demonstration showing the iPhone pairing and controlling the Mac. A simulator screen recording does not establish hardware interaction.
- Apple's day-based trial language differs from a 30-minute connected-use demo. Preserve the user's approved model; explain it transparently and obtain App Review guidance if necessary. Do not silently change to subscription/trial products.
- User did not authorize final submission to review in this task; prepare but do not submit.

Current App Store Connect validation has one blocking error: no release build selected. Existing TestFlight 1.0.0 (2) is an older sandbox-configured build and must not be selected merely to clear that error. App Privacy is a separate browser-only blocker not covered by the API validator.
