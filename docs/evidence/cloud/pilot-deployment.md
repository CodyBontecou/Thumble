# Pilot deployment — 2026-10-23

## Provisioned resources and current identity configuration

- Service origin: https://thumble-cloud-pilot.costream.workers.dev
- MCP endpoint and exact OAuth resource/audience: https://thumble-cloud-pilot.costream.workers.dev/mcp
- Worker: `thumble-cloud-pilot`
- Current deployed version: `5efb9c6d-3cfc-4b81-b619-3cf774184914`
- Cloudflare account: `e4265f322e6380ee832b83ad45e3e8c0`
- D1 database: `thumble-cloud-pilot`, ID `67be3503-2cee-4303-a6d2-dcc396ce2e68`, region ENAM
- Applied migrations: `0001_cloud.sql`, `0002_better_auth.sql`, `0003_account_deletion.sql`, `0004_provider_data_minimization.sql`
- Pilot configuration: `apps/cloud/wrangler.pilot.jsonc`

The pilot is isolated from other Workers, databases and the LAN receiver. It now uses Better Auth 1.7.12 with persistent D1 identity storage and Apple/Google browser sign-in. The earlier external-provider `503 not_configured` baseline is historical; it is no longer the pilot's configured identity mode. No fixture user/session, fixture signing key, unsigned-token support or simulated phone receipt has been deployed.

The issuer is the service origin plus `/api/auth`. Authorization and token endpoints are `/api/auth/oauth2/authorize` and `/api/auth/oauth2/token`; public keys are under `/api/auth/jwks`. Server-only provider credentials and the stable Better Auth secret are not recorded here.

The fixed public native client `thumble-mobile` requires S256 PKCE and exact redirect `thumble://cloud-auth/callback`. The fixed ChatGPT client `thumble-chatgpt` uses the exact registered callback `https://chatgpt.com/connector_platform_oauth_redirect`, requires PKCE, and supports public `none` authentication unless an operator explicitly configures a confidential client secret. Both clients use public subject identifiers to preserve the same account across phone and AI authorization.

The native client requests `openid`, `offline_access` and all six cloud scopes. The ChatGPT client is limited to `openid`, `offline_access`, profile read/write, device read and delivery read/write; it cannot register or revoke phones through `devices:manage`. The current authorization-server discovery advertises the narrower AI scope list, while `/v1/config` provides the phone's full list. Version `94405aee-8aa6-48d8-a4c9-0917d717965e` also narrows protected-resource metadata. Remote verification confirmed only `profiles:read`, `profiles:write`, `devices:read`, `deliveries:read` and `deliveries:write` there, without `devices:manage`.

## Deployed changes and verification boundary

Version `0396988d-df34-4a5c-ba18-4b42e88a29ed` includes migrations 0003/0004, account deletion and provider data minimization, together with the ChatGPT/native client scope separation. Migration 0003 adds deletion tombstones and stale-write guards; migration 0004 clears previously retained provider ID tokens. The [identity retention record](identity-retention.md) describes stored data, Apple token revocation, deletion behavior and retained security records.

The coordinator reports **161 root tests** and **61 cloud tests** passing for the current implementation. Mobile lint/typecheck and 20 focused mobile cloud/OAuth/deletion tests pass. Local identity runtime tests use actual Worker/D1 and OAuth code exchange, but their preexisting social session and phone receipts are simulated. These results establish implementation behavior; they do not establish live provider sign-in, marketplace approval or physical-phone rendering.

Google's OAuth consent configuration remains in **Testing**. This is a public-release blocker even though the allowed test user completed the pilot. Production publishing and any applicable verification must be completed before claiming general Google sign-in availability. Apple live sign-in and live deletion/revocation behavior still need their own evidence; no real user account has been deleted in this implementation task.

## Successful live Google / ChatGPT / physical iPhone journey

The latest development-signed Release app was installed on the intended iPhone through Xcode, preserving existing app data. The controller UI was observed disconnected from the Mac. The user completed Google sign-in on the phone; Cloud controllers then displayed **Ready for your first controller**, with **My iPhone** registered and an empty library.

The user explicitly approved resetting the stalled ChatGPT plugin. The old **Thumble Pilot** definition retained `devices:manage` in its cached OAuth settings and was uninstalled. Reinstalling it failed with `invalid_scope`, as expected from the server's scope restriction. A refreshed **Thumble Pilot Cloud** definition discovered only the approved scopes. Its creation initially displayed a ChatGPT connection error despite creating the definition; it was recovered from the Personal directory. The original definition remains uninstalled; no permanent plugin deletion was performed.

ChatGPT's Google account selection and Thumble consent were completed for the same account as the phone, with profile read/write, device read, delivery read/write and refresh access. No phone-management permission was granted. ChatGPT confirmed the plugin was installed and used the hosted MCP tools in a [live conversation](https://chatgpt.com/c/6adc04d3-b338-83ed-874c-30d829cbbbb5).

| Evidence | Observed result |
| --- | --- |
| Profile | `pilot-first-controller`, name **Pilot first controller**, revision **1** |
| ChatGPT validation | Zero validation errors; two analog sticks and four A/B/X/Y buttons |
| Target | **My iPhone**, physical iPhone 17 Pro, landscape viewport 874 × 402 |
| Delivery | `ef831aa9-e8db-45ef-ac03-bfe079909f3d` |
| Phone download | **A controller has arrived**, exact name and revision 1 |
| Phone preview | **Try controller in practice** opened the six-control layout, observed through Argent |
| Follow-up tool check | ChatGPT called `delivery_status` and reported **rendered**, error `null`, updated October 23, 2026 at 9:08:09 PM America/Puerto_Rico |

Physical screenshots: [controller arrived](live-pilot-2026-10-23/controller-arrived.png) and [controller in practice](live-pilot-2026-10-23/controller-practice.png). This proves the owner pilot's Google authentication, hosted MCP creation/delivery and real phone preview. It does not establish live Apple sign-in, general marketplace availability, working Mac/game input or the broader regression checklist.

Final local Worker/D1 runtime verification passed with all four migrations and the scope separation. It exercised native and public ChatGPT PKCE, consent, token exchange, MCP delivery, isolated test-account deletion, and rejection of the deleted account's JWT and stale writes. Social login and phone rendering remained simulated in that test. The physical app build passed with development signing; its Cloud controllers screen and disconnected practice state were observed after installation.

## Remaining release and journey checks

The subsequent [cloud-to-Mac adoption test](mac-adoption.md) delivered a fresh complete gamepad from ChatGPT, confirmed its physical-phone rendering and explicit receiver adoption, and observed movement, camera and Menu in ConsolePort/WoW. It separately records the controls still awaiting live verification.

1. Extend the completed Google happy path with browser cancellation and expired-token/network recovery checks; separately verify live Apple sign-in.
2. Preserve the verified protected-resource scope separation when updating clients or metadata; the native configuration must retain registration permission while AI clients cannot request it.
3. Preserve the completed ChatGPT connection's verified scopes, resource audience and account alignment. Other frontier clients and plugin marketplaces remain unverified.
4. Extend the successful exact-revision delivery/render check with background/foreground, supersession, offline cached restart and revocation scenarios.
5. Complete Google's production/verification requirements before public release. Review published privacy/store disclosures and the infrastructure retention limitations described in the retention record.
6. Keep live account deletion and Apple grant revocation as separate, explicitly authorized checks; local test results are not a live deletion demonstration.

## Repeatable deployment commands

### Thumble asset deployment — October 23, 2026, 9:21 PM America/Puerto_Rico

Version `5efb9c6d-3cfc-4b81-b619-3cf774184914` deployed with the pilot configuration
and `--keep-vars`, adding the public asset binding, MCP image resources and server
icon metadata. No database migration was needed for this update.

Live verification at `2026-10-24T01:21:45.929Z` confirmed GET and HEAD return 200
for all four files under `https://thumble-cloud-pilot.costream.workers.dev/assets/thumble/`:

| File | Bytes | Verified |
| --- | ---: | --- |
| `icon.png` | 552409 | Exact match to local PNG |
| `thumble-menu.png` | 552409 | Exact match to local PNG |
| `splash-icon.png` | 17547 | Exact match to local PNG |
| `favicon.png` | 552409 | Exact match to local PNG |

All images returned `image/png`, `Access-Control-Allow-Origin: *`,
`Cache-Control: public, max-age=3600` and `X-Content-Type-Options: nosniff`.
A missing image returned 404, POST to an image returned 405, and unauthenticated
MCP resource discovery returned 401 with the protected-resource challenge.
Protected-resource discovery and `/v1/config` returned 200; AI discovery still
excluded `devices:manage`. Authenticated MCP image reads passed the local bundled
Worker smoke test; they were not separately exercised with a live account token.

### Commands

From `apps/cloud`, always select the dedicated pilot configuration:

```sh
npx wrangler deploy --config wrangler.pilot.jsonc --dry-run
npx wrangler d1 migrations apply DB --remote --config wrangler.pilot.jsonc
npx wrangler deploy --config wrangler.pilot.jsonc
```

Database creation has already completed. Do not create another database for this pilot or copy fixture keys/tokens into this environment.

### OpenAI submission domain verification — October 23, 2026

Deployed pilot version `bfd58c7b-aef9-4288-909a-4086c36fc916` with `--keep-vars`. Added only the public, exact-path `/.well-known/openai-apps-challenge` asset route for GET/HEAD; writes are rejected and it exposes no account data. OpenAI portal displayed **Domain verified** after its verification request. All 43 cloud tests passed; focused checks confirmed exact text response, write rejection and the missing-binding case. No database migration or OAuth scope change was made.
