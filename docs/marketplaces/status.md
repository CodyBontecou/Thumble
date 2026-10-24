# Thumble marketplace submissions

Checked October 23, 2026 (America/Puerto_Rico). Publisher copy: **Thumble**. Public support/contact: **codybontecou@gmail.com**, confirmed by the owner.

Muse has been submitted for review. Other marketplace entries remain drafts or preparation; no listing has been published in this task.

| Channel | Verified route | Current result / blocker |
| --- | --- | --- |
| ChatGPT + Codex universal directory | [OpenAI Plugins](https://platform.openai.com/plugins) | [Thumble draft created](https://platform.openai.com/plugins/manage/plugin_asdk_app_6adc07c8d6f08191812f87b55c8525b5). Uploaded a remote-MCP package; provided public PKCE settings were accepted and displayed. Domain verification, terms URL and reviewer materials remain. Subtitle was shortened to 29 characters and the corrected upload was confirmed. Corrected package 0.1.1 is verified in the portal: Developer displays Thumble and the subtitle finding is cleared. Upload identity was Individual — CODY RUSSELL BONTECOU; confirm the final verified publishing identity before review. |
| Claude directory | [Developer portal](https://claude.ai/directory/manage) | Signed-in portal accessible. Started MCP connector intake; server discovery reaches OAuth setup and detects that a provided client is needed. No Thumble client with Claude's exact callbacks is registered, so connection and submission cannot complete. Do not use `thumble-chatgpt` as a substitute. |
| Grok / Grok Bot / Cursor | [Combined intake](https://x.ai/bot/marketplace/submit-a-plugin) | Contact, organization, endpoint, description and testing instructions entered; all three destinations selected. Form not submitted. Public logo URL and completed local/in-app testing required. Submission accepts [Publisher Terms](https://cursor.com/marketplace-publisher-terms), so final acceptance needs owner confirmation at action time. The form labels Grok itself “coming soon.” |
| Grok Build | [Official catalog](https://github.com/xai-org/plugin-marketplace) | Public PR route exists. Package/source and exact immutable commit pin must be ready before proposing an entry; OAuth compatibility is unverified. Draft Grok package prepared; no PR opened. |
| Muse | [Submission management](https://platform.muse.ai/submissions/4ceeddaa-8016-4e73-86cb-dfdc8e47b2f9) | **Submitted for review.** Owner explicitly authorized accepting Muse Connector Terms and submitting Thumble. All final attestations checked; confirmation reads “Thank you for your submission!” and “We’ll review Thumble and get in touch.” Current pilot/OAuth limitations were disclosed. Submission ID: `4ceeddaa-8016-4e73-86cb-dfdc8e47b2f9`. |
| Gemini CLI | [Gallery publishing guide](https://geminicli.com/docs/extensions/releasing/) | Draft `gemini-extension.json` prepared. Gallery indexes a public GitHub repo with root manifest and `gemini-cli-extension` topic. A monorepo subdirectory alone does not satisfy the root-manifest requirement. Authentication has not been tested. This is CLI distribution, not a Gemini consumer-app marketplace listing. |
| MCP Registry / Copilot discovery | [Remote publishing](https://modelcontextprotocol.io/registry/remote-servers) | Remote-only `server.json` prepared under the owner's GitHub namespace. Requires publisher authentication and successful registry validation. Registry metadata publication does not guarantee placement in any client's curated directory. No registry version published. |
| Perplexity | [Custom remote MCP support](https://www.perplexity.ai/en-GB/changelog/what-we-shipped---march-13-2026) | Custom connectors are documented. No public self-service marketplace submission route verified in the sources checked. Client registration/testing still required; not marked submitted. |
| Mistral Vibe Work / Studio | [MCP connectors](https://docs.mistral.ai/vibe/work/connectors/mcp-connectors) | Curated directory and custom connector support documented. No public self-service directory submission route verified in the sources checked. Standard OAuth path documents DCR, which our service disables; compatibility work required. |

Kimi, Qwen and DeepSeek are not marked as submission destinations: no official public MCP marketplace intake was verified in this pass. This inventory covers verified routes, not a claim that every model vendor operates a marketplace. Third-party aggregators are separate from frontier-vendor approval.

## Concrete release blockers

1. **General sign-in:** the deployment record says Google's consent screen is still in Testing. An allowed owner pilot does not establish reviewer or public access. Apple live sign-in has separate outstanding evidence.
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
