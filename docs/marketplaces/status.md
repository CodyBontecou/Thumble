# Thumble marketplace submissions

Checked October 24, 2026 (America/Puerto_Rico). Publisher copy: **Thumble**. Public support/contact: **codybontecou@gmail.com**, confirmed by the owner.

Muse, the canonical ChatGPT plugin, and the Grok/Cursor intake have been submitted for review. Claude is published, the Official MCP Registry entry is active, and Glama is approved with ownership verified. See the channel rows for remaining limitations.

| Channel | Verified route | Current result / blocker |
| --- | --- | --- |
| ChatGPT + Codex universal directory | [OpenAI Plugins](https://platform.openai.com/plugins) | [Canonical Thumble draft 0.2.0](https://platform.openai.com/plugins/manage/plugin_asdk_app_6adc8f83963881918c960106b339df6d). `https://thumble.io/mcp`, domain verified, OAuth authorized, all eight tools discovered; latest scan has no findings. Terms linked. **Submitted for review October 24, 2026.** Portal confirms In review; package 0.2.0. Email-code reviewer account, approved TestFlight build 3, unlisted walkthrough and approved final attestations are included. Old pilot draft is unpublished and superseded. |
| Claude directory | [Developer portal](https://claude.ai/directory/manage) | Submitted for review with https://thumble.io/mcp and dedicated confidential OAuth client thumble-claude. All five currently live read-only tools tested in Claude. Seven policy acknowledgements accepted with explicit owner authorization. **Approved as a community connector**, confirmed by decision email and refreshed portal. **Published October 24, 2026**, verified in the portal with Published (done). Public URL: https://claude.ai/directory/thumble . Initial public readback is still unavailable; portal says new listings can take up to an hour to appear. Server record: https://claude.ai/directory/manage/thumble . |
| Grok / Grok Bot / Cursor | [Combined intake](https://x.ai/bot/marketplace/submit-a-plugin) | Combined intake completed with canonical endpoint, public logo, current read-only description and reviewer sign-in instructions; all three destinations selected. Dedicated read-only Grok OAuth client registered with owner authorization, live connection and all five tools verified in Grok. Local MCP and identity tests pass. Submitted successfully through the combined intake after owner-authorized Publisher Terms acceptance. Review contact: cody@isolated.tech. Receipt confirmed that review will follow up by email. Canonical MCP endpoint: https://thumble.io/mcp. Grok itself is labeled “coming soon”; review receipt does not confirm approval or publication. |
| Grok Build | [Official catalog](https://github.com/xai-org/plugin-marketplace) | Public PR route exists. Package/source and exact immutable commit pin must be ready before proposing an entry; OAuth compatibility is unverified. Draft Grok package prepared; no PR opened. |
| Muse | [Submission management](https://platform.muse.ai/submissions/4ceeddaa-8016-4e73-86cb-dfdc8e47b2f9) | **Submitted for review.** Owner explicitly authorized accepting Muse Connector Terms and submitting Thumble. All final attestations checked; confirmation reads “Thank you for your submission!” and “We’ll review Thumble and get in touch.” Current pilot/OAuth limitations were disclosed. Submission ID: `4ceeddaa-8016-4e73-86cb-dfdc8e47b2f9`. |
| Gemini CLI | [Gallery publishing guide](https://geminicli.com/docs/extensions/releasing/) | **Published for automatic gallery discovery October 24, 2026:** https://github.com/CodyBontecou/thumble-gemini , version 0.1.0, root manifest and `gemini-cli-extension` topic verified. Canonical https://thumble.io/mcp, five allowlisted read-only tools, dedicated public native OAuth client. Official Gemini CLI 0.65.0 validation and public Git install passed; all 16 identity tests passed. Gallery crawler runs daily; listing visibility is not yet confirmed. This is CLI distribution, not a Gemini consumer-app connector. |
| MCP Registry / Copilot discovery | [Remote publishing](https://modelcontextprotocol.io/registry/remote-servers) | **Published and active October 24, 2026:** io.github.CodyBontecou/thumble version 0.1.0, canonical https://thumble.io/mcp. Official CLI validation and public API readback passed. Registry inclusion does not imply curated client approval. |
| Smithery | [Publishing flow](https://smithery.ai/servers/new) | **Blocked by Smithery:** configuration step returns 403 “Updating servers has been removed. Contact support@smithery.ai.” No publication confirmed. Proxy/accounts retire October 31; public registry remains. Owner authorized support request; sent to support@smithery.ai from codybontecou@gmail.com and verified in Sent. Awaiting manual listing decision. |
| Glama | [Hosted connector submissions](https://glama.ai/mcp/connectors) | **Approved; public listing exists:** https://glama.ai/mcp/connectors/io.thumble/thumble . **Ownership verified** through the _glama-claim.thumble.io TXT record. Keep this record published to retain verification. **Authenticated health check passed October 24, 2026 at 15:51 America/Puerto_Rico**; public status Healthy, six tools indexed, and Thumble appears in connector search. Monitoring uses a dedicated sample-only account with renewable read-only OAuth. Publisher account cody@isolated.tech. |
| Perplexity | [Custom remote MCP support](https://www.perplexity.ai/en-GB/changelog/what-we-shipped---march-13-2026) | Custom connectors are documented. No public self-service marketplace submission route verified in the sources checked. Client registration/testing still required; not marked submitted. |
| Mistral Vibe Work / Studio | [MCP connectors](https://docs.mistral.ai/vibe/work/connectors/mcp-connectors) | Curated directory and custom connector support documented. No public self-service directory submission route verified in the sources checked. Standard OAuth path documents DCR, which our service disables; compatibility work required. |

Kimi, Qwen and DeepSeek are not marked as submission destinations: no official public MCP marketplace intake was verified in this pass. This inventory covers verified routes, not a claim that every model vendor operates a marketplace. Third-party aggregators are separate from frontier-vendor approval.

## Concrete release blockers

1. **General sign-in:** Google's consent screen was published to In production on 2026-10-24 after explicit owner approval. Verification Center says no data-access verification is required for the current scopes; branding is not yet shown. Reviewer sign-in still needs live verification. Apple live sign-in has separate outstanding evidence.
2. **Client registration:** the service provisions only `thumble-mobile` and `thumble-chatgpt`; DCR is disabled. Register each additional client with verified exact callback URLs, PKCE and only the AI scope set. Preserve the existing phone/ChatGPT scope boundaries.
3. **Domain ownership:** OpenAI supplies a challenge in the draft's MCP connection dialog. Serve the current exact token as plain text at `https://thumble.io/.well-known/openai-apps-challenge`, then verify it. Do not overwrite another listing's challenge.
4. **Terms resolved:** `https://thumble.io/terms` was published and verified in the browser on October 23, 2026. Muse now links it. OpenAI package 0.1.1 predates publication and still needs the new URL in a subsequent upload. Privacy is live; review its retention/deletion text against the latest implementation before submission.
5. **Logo hosting:** use `https://thumble.io/assets/thumble/icon.png` for the public app icon. Verify that the asset loads before submitting a listing. The earlier pilot-host inspection returned `Route not found`; that historical result does not describe the canonical endpoint. Grok needs a working public square SVG/PNG URL with a background plate.
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


### Official MCP Registry publication — October 24, 2026

Updated distribution/thumble/registry/server.json with the canonical https://thumble.io/mcp endpoint, website and accurate current read-only description. Installed official mcp-publisher 1.8.4 from modelcontextprotocol/registry GitHub releases in a temporary directory and verified its SHA-256 checksum against the release checksums. Production validation passed. Authenticated through official GitHub device flow as CodyBontecou; the authorization screen requested identity verification and resource knowledge, no repository write scope. Published io.github.CodyBontecou/thumble version 0.1.0 successfully. Public API readback confirmed status active, isLatest true and canonical endpoint at https://registry.modelcontextprotocol.io/v0.1/servers/io.github.CodyBontecou%2Fthumble/versions/0.1.0 . PublishedAt: 2026-10-24T19:05:13.421315Z. This publishes metadata, not server code or a vendor endorsement.

Glama hosted connector submission started at https://glama.ai/mcp/connectors . Add Server requires account sign-up. Prepared Cody Bontecou / cody@isolated.tech; before account creation requested owner confirmation for Glama terms/privacy acceptance and its CAPTCHA. No Glama listing submitted yet. Evidence: evidence/glama-signup-ready.png.


### Glama submission confirmed — October 24, 2026

Owner explicitly authorized Glama account creation with Cody Bontecou / cody@isolated.tech, acceptance of Terms of Service/Privacy Policy and CAPTCHA completion. Verification succeeded. Sign-up returned without a visible receipt; normal email OTP sign-in succeeded and the account menu confirmed cody@isolated.tech. The connected Gmail API reports mail_service_not_enabled, so used the Mac Mail UI to retrieve the requested Glama OTP from forwarded mail. No credentials were persisted in repository files.

Submitted Add MCP Server → Hosted endpoint, name Thumble, canonical https://thumble.io/mcp and a description within the 500-character limit. Copy accurately states five read-only tools, disabled AI generation/saving/sending, OAuth, phone-rendering versus Mac-input boundary and public docs/privacy/terms/support links. No API keys or owner OAuth tokens supplied to Glama. Form says approved submissions receive health-check setup instructions; healthy checks are required for search indexing.

Verified the receipt email from Glama Support, subject **Your MCP connector "Thumble" is pending review on Glama**, received at approximately 15:09 America/Puerto_Rico. Body: Thanks for submitting Thumble (link https://thumble.io/mcp) to Glama; it is now pending review; they will email when a decision is made. The public search currently has no Thumble result, consistent with pending review. No duplicate submission made. Evidence: evidence/glama-pending-review.png. This confirms submission, not approval or indexing.


### Smithery publication blocked — October 24, 2026

Authenticated as cody@isolated.tech using ordinary Google identity sign-in. Opened https://smithery.ai/servers/new; entered thumble under the existing default namespace cody-82px and canonical https://thumble.io/mcp. No custom connection parameters, credentials, OAuth client creation or server changes were made. Continuing past the parameter screen returned **403 {"error":"Updating servers has been removed. Contact support@smithery.ai."}**. No publication or functioning Smithery connection confirmed.

Smithery’s live announcement https://smithery.ai/future says its proxy, managed identity, API, accounts, CLI and SDK stop October 31, 2026; the public non-proxied registry remains, with a curated verified set. Do not retry via the retiring CLI/API or create a proxy dependency. Prepared docs/marketplaces/smithery-listing-request.txt for a direct endpoint listing through the support contact specified by the error. Sending requires explicit owner authorization. Evidence: evidence/smithery-publishing-disabled.png.


### Claude and Glama approval discovered — October 24, 2026

While completing the authorized Smithery support request, found new review decision emails in Mac Mail. Glama Support email “Approved: claim Thumble on Glama” says approved and live. Verified public record https://glama.ai/mcp/connectors/io.thumble/thumble shows the submitted description and canonical endpoint. Ownership is unclaimed and Last Tested is Never; public page existence does not establish authenticated health or search indexing. Evidence: evidence/glama-approved.png.

Anthropic email “Anthropic MCP Directory Follow-Up” says approved as a community connector by automated listing review. Refreshed canonical https://claude.ai/directory/manage/thumble confirmed Approved, Approved done and Live not yet, with Publish button. Did not publish or change the listing. Evidence: evidence/claude-approved.png. Stopped both completed review monitors after reporting the approvals; OpenAI and Grok monitors remain active.


### Smithery support request sent — October 24, 2026

Owner explicitly authorized sending the prepared docs/marketplaces/smithery-listing-request.txt to support@smithery.ai. Mail’s cody@isolated.tech (Google) sender failed with Cannot send message using the server Google. Used Edit Message on that same failed queued item, changed the From address to the existing CodyBontecou@gmail.com account, retained cody@isolated.tech as publisher contact in the approved message, and sent successfully. Verified exactly one matching message in Sent — CodyBontecou@gmail.com, addressed to support@smithery.ai, subject Thumble direct MCP registry listing — publishing flow returns 403, at 15:27 America/Puerto_Rico. Outbox became empty. No duplicate message was created. Evidence: evidence/smithery-request-sent.png. This confirms the request was sent, not a Smithery listing approval.


### Claude published and Glama ownership verified — October 24, 2026

Owner requested publishing Claude and claiming Glama. Confirmed Claude Publish dialog and verified the resulting portal state: Published, Live in the directory, and all three progress stages done. Endpoint remains https://thumble.io/mcp with five read-only tools. The View listing link is https://claude.ai/directory/thumble; initial public page says unavailable, consistent with the portal notice that new listings can take up to an hour to appear. Evidence: evidence/claude-published.png.

Added one TXT record at _glama-claim.thumble.io via the signed-in Cloudflare dashboard, preserving the seven existing DNS records. Glama Check DNS record succeeded and the public listing now shows Ownership verified. Leave this account-bound public proof record in DNS to retain verification. No OAuth credentials were supplied to Glama. Health testing remains Not tested / Never. Evidence: evidence/glama-ownership-verified.png.


### Glama health-check setup inspected — October 24, 2026

Opened the claimed connector's Admin → Test profile and selected OAuth 2.0 to match Thumble's authentication. Existing anonymous check fails HTTP 401. Authenticate with OAuth fails because Glama requires dynamic client registration; its callback check reports Not connectable and client_id none. Thumble intentionally disables DCR and does not yet have a Glama client. No account tokens, API keys, or custom Authorization headers were sent. No production authentication changes made.

Requested owner authorization for a restricted Glama OAuth integration with a sample-only monitoring account and persistent read-only access before creating this new grant. The current Glama request derives pairing:read, profiles:read/write, devices:read and deliveries:read/write from metadata; these must not be granted wholesale to a health-check account. A compatible integration must bound scopes and retain PKCE, explicit consent and canonical resource restrictions. Health/indexing remain unconfirmed. Evidence: evidence/glama-health-oauth-blocked.png.


### Glama authenticated health checks and search verified — October 24, 2026

Owner explicitly authorized restricted persistent Glama monitoring. Deployed a callback-restricted RFC 7591 adapter: only https://glama.ai/api/app/mcp/oauth/callback is registered; Glama's optional localhost callback is discarded. Client capability ceiling is offline_access, profiles:read, devices:read and deliveries:read, with canonical resource, PKCE and consent. Other callback domains and write/pairing capabilities are excluded. A resource-server check pins these clients to the configured sample account and rejects owner-account tokens. Glama copies broad discovery scopes, so the adapter requests only the permitted read scopes plus explicitly consented offline renewal.

Provisioned codybontecou+thumble-glama@gmail.com with a fictional starter controller; signed in by normal email code retrieved from the owner's Mail inbox. No verification bypass. Initial saved-owner connection was rejected by the account boundary and cleared in Glama before connecting the sample account. Verified a sample-only read grant and refresh issuance without reading token values; refresh expiry is November 23, 2026.

Live test passed at 15:51:39 America/Puerto_Rico, duration 2752 ms, status Healthy. Public listing shows Healthy and six indexed tools, and Thumble appears at https://glama.ai/mcp/connectors?query=Thumble . Search attribute counters may lag the detail page. Updated description from five to six read-only tools, including pairing QR handoff; selected Games & Gamification category required by the edit form. The monitoring account cannot access pairing QR credentials.

Deployment built from an isolated HEAD snapshot plus the existing deployed resource-seeding fix and this integration, preserving unrelated local work. Latest Worker version: eebae5f4-ff63-428d-9439-3bf043cddd61. All 59 cloud tests passed; updated identity suite passed all 15 tests, including normal clients, migration, email sign-in, Glama callbacks/scope ceiling, PKCE, consent, renewal and owner-account rejection. No API secrets were committed. Code changes remain local and deployed; no Git commit/push performed in this step.

Evidence: evidence/glama-health-check-passed.png, evidence/glama-healthy-listing.png, evidence/glama-searchable.png.


### Gemini CLI extension published for gallery discovery — October 24, 2026

The official releasing guide says public GitHub repositories with a root gemini-extension.json and the gemini-cli-extension topic are crawled daily; no form, email, issue or PR submission is required. Published the standalone package at https://github.com/CodyBontecou/thumble-gemini, main commit 92302a93b6ae0327d46a990dcf44bc758b87cfc7. Only the manifest and human README were published; the private tapping repository remains private. Verified public visibility, default branch, discovery topic and root manifest through GitHub API readback.

Version 0.1.0 uses https://thumble.io/mcp and explicitly allows profile_schema, list_profiles, get_profile, list_devices and delivery_status. Registered the dedicated public native client thumble-gemini-cli, token authentication none, PKCE required, consent required, canonical resource only, and scopes offline_access, profiles:read, devices:read, deliveries:read. The configured loopback callback is http://localhost:7777/oauth/callback; the native OAuth library follows standard loopback redirect matching. No client secret, owner token or user grant was published or created. No production Worker deployment was needed.

Gemini CLI 0.65.0 from the official npm package validated the extension, installed the local package into an isolated CLI home, then successfully installed the public GitHub URL into a separate isolated CLI home. The identity integration suite passed 16/16, covering consent and PKCE, callback host/path restrictions, resource isolation and write/pairing-scope rejection. A live user's sign-in and model-driven tool calls were not exercised. No claim of gallery indexing or Google approval is made before crawler confirmation.

Install: gemini extensions install https://github.com/CodyBontecou/thumble-gemini . Restart Gemini CLI and run /mcp auth thumble. Source package: distribution/thumble/gemini; provisioning helper: tools/lib/gemini-oauth-client.mjs.


### Awesome Remote MCP Servers submitted — October 24, 2026

Opened https://github.com/punkpeye/awesome-remote-mcp-servers/pull/2838 from CodyBontecou:codex/add-thumble. Adds three README lines under Gaming, alphabetically between The Pit and TickerMint, with https://thumble.io/mcp, OAuth marker, and the healthy io.thumble/thumble Glama connector badge. Public endpoint probe returned HTTP 401 with Bearer resource_metadata; connector and badge returned HTTP 200. Description is 115 characters; alphabetic order, unique endpoint and git diff --check passed. Starred the repository as required. Submission awaits upstream review; no merge requested.
