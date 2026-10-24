# Thumble marketplace submissions

Checked October 23, 2026 (America/Puerto_Rico). Publisher copy: **Thumble**. Public support/contact: **codybontecou@gmail.com**, confirmed by the owner.

Muse and the canonical ChatGPT plugin have been submitted for review. Other marketplace entries remain drafts or preparation; no listing has been published in this task.

| Channel | Verified route | Current result / blocker |
| --- | --- | --- |
| ChatGPT + Codex universal directory | [OpenAI Plugins](https://platform.openai.com/plugins) | [Canonical Thumble draft 0.2.0](https://platform.openai.com/plugins/manage/plugin_asdk_app_6adc8f83963881918c960106b339df6d). `https://thumble.io/mcp`, domain verified, OAuth authorized, all eight tools discovered; latest scan has no findings. Terms linked. **Submitted for review October 24, 2026.** Portal confirms In review; package 0.2.0. Email-code reviewer account, approved TestFlight build 3, unlisted walkthrough and approved final attestations are included. Old pilot draft is unpublished and superseded. |
| Claude directory | [Developer portal](https://claude.ai/directory/manage) | Submitted for review with https://thumble.io/mcp and dedicated confidential OAuth client thumble-claude. All five currently live read-only tools tested in Claude. Seven policy acknowledgements accepted with explicit owner authorization. Receipt confirmed; not yet approved or published. Server record: https://claude.ai/directory/manage/thumble . |
| Grok / Grok Bot / Cursor | [Combined intake](https://x.ai/bot/marketplace/submit-a-plugin) | Combined intake completed with canonical endpoint, public logo, current read-only description and reviewer sign-in instructions; all three destinations selected. Dedicated read-only Grok OAuth client registered with owner authorization, live connection and all five tools verified in Grok. Local MCP and identity tests pass. Submitted successfully through the combined intake after owner-authorized Publisher Terms acceptance. Review contact: cody@isolated.tech. Receipt confirmed that review will follow up by email. Canonical MCP endpoint: https://thumble.io/mcp. Grok itself is labeled “coming soon”; review receipt does not confirm approval or publication. |
| Grok Build | [Official catalog](https://github.com/xai-org/plugin-marketplace) | Public PR route exists. Package/source and exact immutable commit pin must be ready before proposing an entry; OAuth compatibility is unverified. Draft Grok package prepared; no PR opened. |
| Muse | [Submission management](https://platform.muse.ai/submissions/4ceeddaa-8016-4e73-86cb-dfdc8e47b2f9) | **Submitted for review.** Owner explicitly authorized accepting Muse Connector Terms and submitting Thumble. All final attestations checked; confirmation reads “Thank you for your submission!” and “We’ll review Thumble and get in touch.” Current pilot/OAuth limitations were disclosed. Submission ID: `4ceeddaa-8016-4e73-86cb-dfdc8e47b2f9`. |
| Gemini CLI | [Gallery publishing guide](https://geminicli.com/docs/extensions/releasing/) | Draft `gemini-extension.json` prepared. Gallery indexes a public GitHub repo with root manifest and `gemini-cli-extension` topic. A monorepo subdirectory alone does not satisfy the root-manifest requirement. Authentication has not been tested. This is CLI distribution, not a Gemini consumer-app marketplace listing. |
| MCP Registry / Copilot discovery | [Remote publishing](https://modelcontextprotocol.io/registry/remote-servers) | Remote-only `server.json` prepared under the owner's GitHub namespace. Requires publisher authentication and successful registry validation. Registry metadata publication does not guarantee placement in any client's curated directory. No registry version published. |
| Perplexity | [Custom remote MCP support](https://www.perplexity.ai/en-GB/changelog/what-we-shipped---march-13-2026) | Custom connectors are documented. No public self-service marketplace submission route verified in the sources checked. Client registration/testing still required; not marked submitted. |
| Mistral Vibe Work / Studio | [MCP connectors](https://docs.mistral.ai/vibe/work/connectors/mcp-connectors) | Curated directory and custom connector support documented. No public self-service directory submission route verified in the sources checked. Standard OAuth path documents DCR, which our service disables; compatibility work required. |

Kimi, Qwen and DeepSeek are not marked as submission destinations: no official public MCP marketplace intake was verified in this pass. This inventory covers verified routes, not a claim that every model vendor operates a marketplace. Third-party aggregators are separate from frontier-vendor approval.

## Concrete release blockers

1. **General sign-in:** Google's consent screen was published to In production on 2026-10-24 after explicit owner approval. Verification Center says no data-access verification is required for the current scopes; branding is not yet shown. Reviewer sign-in still needs live verification. Apple live sign-in has separate outstanding evidence.
2. **Client registration:** the service provisions only `thumble-mobile` and `thumble-chatgpt`; DCR is disabled. Register each additional client with verified exact callback URLs, PKCE and only the AI scope set. Preserve the existing phone/ChatGPT scope boundaries.
3. **Domain ownership:** OpenAI supplies a challenge in the draft's MCP connection dialog. Serve the current exact token as plain text at `https://thumble-cloud-pilot.costream.workers.dev/.well-known/openai-apps-challenge`, then verify it. Do not overwrite another listing's challenge.
4. **Terms resolved:** `https://thumble.io/terms` was published and verified in the browser on October 23, 2026. Muse now links it. OpenAI package 0.1.1 predates publication and still needs the new URL in a subsequent upload. Privacy is live; review its retention/deletion text against the latest implementation before submission.
5. **Logo hosting:** the package includes the current app icon, but browser inspection of `https://thumble-cloud-pilot.costream.workers.dev/assets/thumble/icon.png` returned `Route not found`. Local asset-serving implementation exists in the shared worktree; its existence is not proof of deployment. Grok needs a working public square SVG/PNG URL with a background plate.
6. **Review account and evidence:** prepare dedicated sample-data access that reviewers can use without owner MFA, execute the five positive and three negative cases, and record an accessible walkthrough. The current owner ChatGPT/iPhone evidence does not cover all these cases or other hosts.
7. **Final attestations:** do not attest that Grok/Cursor testing passed until it has. Request confirmation for publisher-terms acceptance only once the submission is complete and reviewable.

## Verification performed

- `npm test --workspace @tapping/cloud`: **43 tests passed**, zero failures. This includes current local asset tests; it does not prove production asset availability.
- Portable plugin and base MCP configuration validated using the official downloaded schemas' compatible keywords with installed Ajv. The upstream MCP schema does not include OpenAI's documented vendor authentication extension; that extension was separately accepted and displayed by the OpenAI portal.
- Corrected OpenAI draft 0.1.1 confirmed after reload; publisher displays Thumble and only the terms URL remains a blocking metadata finding. Review information and MCP setup remain incomplete.
- Browser verified the public website and privacy policy, unavailable terms page, missing deployed cloud icon, signed-in submission portals, and the actual OpenAI findings.
- Shell HTTP checks returned 403 for Thumble URLs in this environment while the browser loaded the website; do not interpret the shell results alone as a service outage.

## Primary submission references

- [OpenAI submission and reviewer requirements](https://developers.openai.com/plugins/deploy/submission)
- [OpenAI package and authentication format](https://developers.openai.com/plugins/build/plugins)
- [Claude current publishing guide](https://claude.com/docs/directory/publish) — replaces older, conflicting admin-only submission instructions found in search.
- [Muse connector requirements](https://platform.muse.ai/docs)
- [Grok Build marketplace announcement](https://x.ai/news/grok-plugin-marketplace)

See [listing and reviewer copy](listing.md) and [package sources](../../distribution/thumble/README.md).

## Muse login follow-up

The email-code attempt reached a provider account-creation error, with a birthday-setup screen visible behind the modal. No birthday was supplied and no account terms were accepted. The precise reason was not disclosed. [Captured error](evidence/muse-account-error.png). The code is not saved in the submission materials.

## Muse authenticated intake follow-up

The owner resolved sign-in using a different email. Populated connector/company name, website, five example prompts, non-payment classification, confirmed contact/support, privacy URL and truthful pilot limitations. The original icon exceeded the 256 KiB upload limit; a packaging resize to 512×512 produced a 142885-byte PNG accepted by the form. Clicking Next focused the empty product terms field with “This field is required.” Browser reconfirmed `/terms` is unavailable. No substitute URL was entered, no final submission made, and no connector terms accepted. [Prepared overview](evidence/muse-overview.png).

## Terms publication and Muse final review

Published from `/Users/codybontecou/dev/thumble/Website` using the existing Cloudflare Pages project `pocketpad-site`, production branch `main`. Deployment succeeded at https://9e885184.pocketpad-site.pages.dev; browser verified https://thumble.io/terms and its dated content. Added footer links to the homepage, privacy, support and setup guide, plus the sitemap entry. Validated HTML structure, local links, pricing/duration copy and sitemap XML. Existing D1/R2 configuration and Pages Functions were preserved.

Muse overview and technical specifications are now complete. Technical intake uses the hosted pilot endpoint and https://thumble.io/docs#agents. It explicitly discloses Google testing, unavailable public phone install, missing Muse OAuth client, unverified Muse end-to-end compatibility, scopes, delivery semantics and demo/Pro access. The final review requires brand authorization, an approval-discretion acknowledgement and acceptance of https://platform.muse.ai/terms. No final checkbox or submit action has been taken. Browser-use rules require confirmation at action time for the binding agreement. [Final review](evidence/muse-final-review.png); [published terms](evidence/terms-published.png).

## Muse submission receipt — October 23, 2026

The owner explicitly confirmed: accept Muse Connector Terms and submit Thumble for review. Accepted the three final acknowledgements and submitted once. Muse navigated to the confirmation URL and displayed “Thank you for your submission!” and “We’ll review Thumble and get in touch.” This confirms submission, not approval or publication. [Manage submission](https://platform.muse.ai/submissions/4ceeddaa-8016-4e73-86cb-dfdc8e47b2f9); [confirmation screenshot](evidence/muse-submitted.png). The documented Muse OAuth/client and reviewer-access work remains outstanding.

## October 24: canonical ChatGPT submission

- OpenAI rejected changing the pilot draft’s MCP origin. A separate plugin package, `thumble-controller`, retains the public name Thumble and uses `https://thumble.io/mcp`. Canonical draft ID: `plugin_asdk_app_6adc8f83963881918c960106b339df6d`; version 0.2.0.
- Domain proof published and verified. Cloudflare deployment `c7347e94-c867-4b29-b646-5d7f15cd4b56` used source from commit 59a8ccc after read-only verification that production still matched canonical deployment 80acb27a-fd3f-4078-bd16-232fb3ad2efd. Only the public challenge asset changed; unrelated concurrent local changes were excluded.
- OAuth consent approved with the user-authorized ChatGPT scope set. Portal shows Configured and no findings in the latest scan, with eight tools. Evidence: `evidence/openai-canonical-configured.png`.
- Mobile sign-in validation now accepts a separately hosted canonical MCP URL advertised by the trusted API service, with an exact audience match and HTTPS validation. Regression test passes; all 20 cloud-mobile tests, mobile lint and typecheck passed after concurrent source updates settled.
- Recording preparation: simulator release rebuilt, Google sign-in requires user completion. No completed demo or YouTube upload yet. Six generated thumbnail candidates are saved in `build/marketplace-demo/thumbnails/`; selection requested under the YouTube package skill. YouTube uploader dependencies and saved OAuth configuration are present.

- Personal ChatGPT test plugin `Thumble Canonical Demo` (`plugin_asdk_app_6adc91b59c988191923febc7dd07463a`) is installed at the canonical endpoint. Demo conversation: https://chatgpt.com/c/6adc928a-96bc-83eb-8bb3-19ee4f74d465 . Created and updated `marketplace-practice` revisions 1 and 2, both independently verified in D1 with read-only queries. Unsupported autonomous game control correctly declined without tool execution. The test connection reports no registered phones; do not assume its connected identity matches the older owner pilot connection. Confirm identity and phone target before delivery.
- Saved actual browser captures and the recording plan in `build/marketplace-demo/`; these are preparation, not a finished demo video. No video has been recorded or uploaded, and neither OpenAI draft has been submitted for review.

- User approved thumbnail 6, “Design a Controller”; selection stored in `build/marketplace-demo/thumbnail-approval.json`. Current auth implementation explicitly disables email/password and offers Google/Apple only. Reviewer-access method decision requested. Simulator window brought forward and phone sign-in reopened for user completion.

## October 24: email sign-in, reviewer account and demo

- Deployed email-code sign-in in Worker version `a300b79c-15ad-4fc3-b22c-38da99877112`. Cloudflare sends from `signin@auth.thumble.io`. Better Auth stores hashed six-digit codes, expires them after five minutes, rotates on resend and limits attempts/requests. Live email sign-in and explicitly approved phone consent succeeded. Cloud tests: 76 passed; isolated auth runtime: 24 passed.
- With explicit owner authorization, pre-created the OpenAI reviewer account with unverified email and sample-only `reviewer-starter` revision 1. A read-only production query confirmed that sample record. Reviewers must verify their own inbox code; no fixed code or password bypass exists.
- Real ChatGPT conversation delivered `marketplace-practice` revision 2 to the authorized review simulator. Delivery `18cfe4c5-507d-4a4d-9a28-09bbbb70d63d` reached `rendered` at 2026-10-24T11:52:35.853Z. This proves phone rendering, not live Mac/game input.
- Recorded actual phone delivery and practice footage, assembled it with real ChatGPT captures and disclosed synthetic narration. Uploaded the 77-second demo with user-approved thumbnail 6: https://www.youtube.com/watch?v=TRO97-s1slY . YouTube receipt and page both show **unlisted**. Audio verified at -16.50 LUFS / -4.58 dBTP. Local package: `build/marketplace-demo/youtube-package/`.
- Saved email-code instructions and video URL in the canonical OpenAI draft. Instructions explicitly disclose the unresolved phone installation gap. The final submission panel is reachable and requires six owner attestations, including agreement to OpenAI’s Terms and Plugin Guidelines. No final checkbox or submission action taken.
- App Store Connect check: current app 6826421489 has only build 1.0.0 (2), internal group only, no public link, external state READY_FOR_BETA_SUBMISSION. Its archived bundle predates the demonstrated cloud flow. Legacy app 6788494990 has public link https://testflight.apple.com/join/yC23NWbG and July build 6 expiring October 28; it is not verified for current cloud delivery. Preparing isolated cloud-enabled build 3 from commit 0ce92c8 plus the tested canonical OAuth validation fix. Unrelated concurrent worktree changes are excluded.
- Automatic approval review initially rejected saving instructions with an unresolved promise about future install access. Replaced that promise with the verified limitation; the corrected details saved successfully.

### Public review beta — October 24, 2026

The owner explicitly approved making the review beta public after automatic approval review initially rejected a broadly accessible group. Created **Marketplace Review**, public link https://testflight.apple.com/join/kxwHv4qW, capped at 10 testers. Group ID `bb38a634-0a63-4874-a250-f169b2043434`.

Archived and exported isolated iOS **1.0.0 (3)**. Corrected a stale generated Info.plist build number before upload; the final artifact is `build/Thumble-Plugin-Review-3-Final.ipa`. Strict signature verification passed with normal Mac certificate trust, and the compiled JS bundle contains the canonical OAuth validation fix. Build source is commit `0ce92c8` plus that tested fix, with isolated generated signing/build-number settings. A manifest records source hashes in `build/marketplace-demo/review-build-manifest.json`.

Apple accepted upload and processing (**VALID**) and the external beta-review submission. Build/submission ID: `632cf0a0-d7a2-4bc9-b98e-3489ba0a7aa2`. Read-back state: **WAITING_FOR_REVIEW**, submitted 2026-10-24T12:15:05Z. External installation is not yet verified available. No App Store release was submitted. Existing Apple review contact data was reused; beta notes explain optional email-code cloud sign-in and account-free local practice. No tester invitation email was sent.

The canonical OpenAI draft now includes the exact public beta link and pending Apple approval state in reviewer instructions. Demo URL remains https://www.youtube.com/watch?v=TRO97-s1slY . OpenAI’s final six attestations remain unchecked; the plugin is **not submitted**. Complete beta availability verification and refresh those instructions before final OpenAI terms acceptance/submission.

### Build 3 approval — October 24, 2026

Scheduled check at 17:41 UTC confirmed Apple beta review **APPROVED** for build `632cf0a0-d7a2-4bc9-b98e-3489ba0a7aa2`, external state **BETA_APPROVED**, unexpired and assigned to Marketplace Review. Public link https://testflight.apple.com/join/kxwHv4qW remains enabled with a 10-tester limit. Refreshed public page shows “View Thumble: Phone Controller Beta” and “View in TestFlight.” External beta availability is verified; no device installation was performed in this check. The recurring approval check was stopped. Canonical ChatGPT draft remains unsubmitted; refresh pending-approval wording and obtain final owner attestations before submission.

### Final OpenAI submission preparation — October 24, 2026

Updated and saved canonical draft 0.2.0 reviewer instructions with approved TestFlight build 3 and verified external invitation. Confirmed the saved unlisted demo URL. MCP configuration remains authorized and domain verified with no scan findings. Portal now reports one non-blocking category finding for Productivity; prepared private submission context explaining the controller-layout authoring workflow and hosted gameplay boundary. Final dialog reached with all six attestations unchecked. Requested action-time owner confirmation for OpenAI Terms, Plugin Guidelines and final attestations before clicking Submit. Evidence: `evidence/openai-final-review-approved-build.png`. Not submitted yet.

### OpenAI submission confirmed — October 24, 2026

After explicit owner confirmation to accept the six final attestations and submit, accepted OpenAI’s Terms and Plugin Guidelines and the remaining policy attestations. Submitted the canonical Thumble plugin once at approximately 14:08 America/Puerto_Rico (18:08 UTC). The portal returned to the plugins list showing In review, and opening the canonical record confirmed **Review status In review**, **Metadata & skills version 0.2.0 · In review**, and **Publication Not published**.

Submitted plugin: https://platform.openai.com/plugins/manage/plugin_asdk_app_6adc8f83963881918c960106b339df6d . MCP endpoint: https://thumble.io/mcp . Reviewer instructions include the dedicated sample account, email-code sign-in, Apple-approved TestFlight build 3 and public beta link. The unlisted video remains https://www.youtube.com/watch?v=TRO97-s1slY . Private submission context explains the non-blocking Productivity-category finding and hosted tool scope. The older pilot draft remains unsubmitted and superseded.

Receipt screenshot: `evidence/openai-submitted.png`. This confirms submission, not OpenAI approval or publication.


### Claude submission prepared — October 24, 2026

Registered operator-managed confidential OAuth client `thumble-claude` after explicit owner authorization. Exact callback: `https://claude.ai/api/mcp/auth_callback`; resource restricted to `https://thumble.io/mcp`; PKCE and consent required. Scopes are explicitly limited to openid, offline_access, profiles read/write, devices read, and deliveries read/write. Pairing and phone-management scopes are excluded. Client secret is hashed server-side and entered only into Claude’s secure authentication fields. OAuth connection succeeded after owner-authorized consent for bontecouc@gmail.com. A focused integration test verifies secret enforcement, callback matching, scope restrictions, PKCE, consent, refresh issuance, and canonical audience.

The live server currently exposes five read-only tools because AI controller generation is disabled. The Claude listing and reviewer instructions describe this actual behavior. Tested profile_schema, list_profiles, list_devices, get_profile and delivery_status in Claude custom connector chat https://claude.ai/chat/60ef932a-f319-4dfb-b094-f0471a0f8747 . The existing owner receipt returned rendered; an unknown delivery UUID returned not_found. No write, gameplay or activation actions were performed. The portal’s self-test checkbox expressly permits testing in Claude, despite its review summary saying MCP Inspector.

With explicit owner authorization, pre-created mcp-review@anthropic.com with unverified email and sample-only reviewer-starter revision 1. Production readback verified both records. Normal inbox verification remains required; Anthropic’s ability to retrieve codes at its published review contact is unverified and disclosed in test instructions with support fallback. No synthetic devices or receipts were seeded.

Draft includes listing, icon, privacy/docs/support links, three read-only use cases, company, Anthropic-held client credentials, data handling and test instructions. Five tool metadata suggestions for missing annotations.title remain disclosed in Additional notes. No Worker code was deployed from the concurrently modified worktree. Final seven policy acknowledgements remain unchecked; owner confirmation requested. Not submitted yet. Evidence: evidence/claude-final-review.png and evidence/claude-read-only-tools-tested.png.


### Claude submission confirmed — October 24, 2026

After explicit owner confirmation, accepted all seven directory policy acknowledgements and clicked Submit for review once. The portal confirmed **Server submitted for review** and **Your MCP server has been received**. Canonical submitted server record: https://claude.ai/directory/manage/thumble . The review team will contact the supplied support email, codybontecou@gmail.com. Receipt screenshot: evidence/claude-submitted.png. This confirms receipt for review, not approval or public publication.

Opening the canonical record confirmed **In review**, **Submitted (done)**, **In review (current)** and **Live (not yet)**. The saved listing shows canonical https://thumble.io/mcp, OAuth and all five tested tools. Status evidence: evidence/claude-in-review.png. Removed the temporary plaintext OAuth client-secret file after successful submission; the server retains its hash and Claude holds the submitted credential.


### Grok submission prepared — October 24, 2026

Official combined intake: https://x.ai/bot/marketplace/submit-a-plugin . Selected Grok (coming soon), Grok Bot and Cursor under publisher Thumble, handle thumble, contact Cody Bontecou / codybontecou@gmail.com. Canonical endpoint https://thumble.io/mcp; public square app icon https://thumble.io/assets/app-icon.png returned HTTP 200 image/png. Listing accurately describes the current five read-only tools and disabled controller generation/writes. Testing instructions specify public client ID, exact read-only scopes, normal email-code/Google/Apple sign-in, sample prompts and support provisioning for a populated reviewer account. No new reviewer email was invented or provisioned.

After explicit owner authorization, registered public OAuth client thumble-grok with exact callback https://grok.com/connectors-oauth-exchange-code/ (verified against Grok’s published https://grok.com/oauth/mcp-client.json metadata). Client requires PKCE and explicit consent, resource is restricted to https://thumble.io/mcp, scopes limited to openid offline_access profiles:read devices:read deliveries:read. No secret, write, pairing or phone-management permission. Production readback confirmed configuration. Source helper: tools/lib/grok-oauth-client.mjs. Identity regression tests: 13 pass; MCP tests: 11 pass. No Worker code deployed.

Grok custom connector successfully connected via OAuth to the approved owner account. Live chat https://grok.com/c/79f8715d-250f-4e65-af7b-61c20d9f5394 ran profile_schema, list_profiles, list_devices, get_profile and delivery_status successfully. Actual result: 4 controller profiles, 2 registered phones, saved Pixel WoW Journey revision 2, and the existing rendered receipt. No write, pairing or game-input actions performed. Evidence: evidence/grok-live-tools-tested.png. Grok Bot native UI automation failed to route input; completed the live in-app test through Grok web, which supports the connector.

Completed the form’s local/in-app tested checkbox only after those tests passed. Final Submit Plugin click accepts Cursor Marketplace Publisher Terms, so requested action-time owner confirmation. Not submitted yet. Evidence: evidence/grok-final-review.png.


### Grok submission blocked by work-email validation — October 24, 2026

Owner explicitly authorized accepting Cursor Marketplace Publisher Terms and submitting the combined listing. Clicked Submit Plugin once. The form returned “Please use a work email address (no Gmail, Hotmail, etc.)” for codybontecou@gmail.com; no receipt or successful submission occurred. Preserved completed form and requested a real accessible non-Gmail work address. No substitute address invented, no validation bypass attempted. Final acceptance remains authorized for the same listing. Evidence: evidence/grok-work-email-required.png.


### Grok / Grok Bot / Cursor submission confirmed — October 24, 2026

Owner supplied cody@isolated.tech as the work email after Gmail validation failed. Updated that field and submitted the same approved listing. The official form replaced all fields with **Thanks for submitting your plugin! We'll review it and follow up by email.** Selected destinations: Grok (coming soon), Grok Bot and Cursor. Canonical MCP endpoint: https://thumble.io/mcp. No reference number or status portal was provided. Successful receipt confirms submission, not approval or public availability. Review correspondence should go to cody@isolated.tech; existing support contact remains codybontecou@gmail.com. Evidence: evidence/grok-submitted.png.
