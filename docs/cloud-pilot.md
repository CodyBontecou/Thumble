# Cloud controller pilot

The first journey is implemented across the Worker, hosted MCP, phone and Mac receiver: an authenticated agent saves a controller revision, sends that exact revision to a registered phone, and reads the phone's render receipt. The phone supports offline practice and explicit adoption on its paired Mac. The local receiver owns game input and activation.

The pilot runs at https://thumble-cloud-pilot.costream.workers.dev with Better Auth 1.7.12 and persistent D1 identity storage. Apple and Google sign-in use the service's browser flow; Auth0 is not required. The [deployment record](evidence/cloud/pilot-deployment.md) separates deployed configuration, automated proof and the successful live Google/ChatGPT-to-iPhone journey.

The [shared contract](cloud-contracts.md) defines payloads, permissions, revisions and delivery states. [The architecture decision](adr/0001-cloud-profile-delivery.md) records the authority boundary, and [hosted MCP guidance](hosted-mcp.md) describes the hosted tools and optional Mac pairing.

## Pilot identity configuration

| Setting | Pilot value |
| --- | --- |
| Service origin | `https://thumble-cloud-pilot.costream.workers.dev` |
| MCP endpoint and exact OAuth resource/audience | `https://thumble-cloud-pilot.costream.workers.dev/mcp` |
| Better Auth issuer | `https://thumble-cloud-pilot.costream.workers.dev/api/auth` |
| Authorization endpoint | `/api/auth/oauth2/authorize` |
| Token endpoint | `/api/auth/oauth2/token` |
| Public signing keys | `/api/auth/jwks` |
| Native public client | `thumble-mobile`, S256 PKCE, token endpoint authentication `none` |
| Exact native OAuth callback | `thumble://cloud-auth/callback` |
| Fixed ChatGPT client | `thumble-chatgpt`, S256 PKCE; public `none` unless an operator explicitly configures a confidential client secret |
| Registered ChatGPT callback | `https://chatgpt.com/connector_platform_oauth_redirect` |
| Google provider callback | `/api/auth/callback/google` |
| Apple provider callback | `/api/auth/callback/apple` |

All HTTP paths above are relative to the service origin. Authorization, code exchange and refresh bind access tokens to the exact MCP resource. Both clients request `openid` and `offline_access`; the phone receives the six cloud scopes, including `devices:manage` for its own registration/revocation. The AI client receives profile read/write, device read and delivery read/write permissions, without `devices:manage`. Discovery for AI clients must advertise that narrower set; the phone receives its full scope list explicitly through `/v1/config`.

Both clients use public subject identifiers so the same Better Auth user resolves to the same account. A browser session or provider ID token cannot directly access controller APIs. JWT signature, issuer, audience, expiry, scopes and deletion state are verified by the resource server. Consent remains explicit. Dynamic client registration and password sign-in are disabled.

## Configure or update this deployment

The pilot Worker and D1 database already exist; do not create replacements for this pilot. Use `apps/cloud/wrangler.pilot.jsonc` explicitly for every pilot migration or deployment.

1. Configure the server-only Better Auth and Apple/Google variables described in [the service README](../apps/cloud/README.md). Keep `BETTER_AUTH_SECRET` stable. No provider credential, client secret, account token or phone token belongs in the native bundle or documentation.
2. Register the exact HTTPS Apple/Google provider callbacks above and the exact native/ChatGPT client callbacks. The native callback requires both a custom-scheme host and a nonempty path; `thumble://cloud-auth` is not the registered callback.
3. Apply all four D1 migrations, `0001_cloud.sql` through `0004_provider_data_minimization.sql`. They cover controller delivery, Better Auth storage, deletion/tombstone guards and provider data minimization. Review the target account/database, then run the commands in the deployment record. New environments must configure their own resources and credentials.
4. Dry-run and deploy the Worker. Verify `/v1/config`, authorization-server discovery, protected-resource metadata, exact client callbacks and the AI/native scope separation. Unconfigured services must fail closed; no fixture signing authority or demo identity is allowed in production.
5. Bundle and install the native app with its Expo authentication and SecureStore modules. The public pilot origin is the default; `EXPO_PUBLIC_CLOUD_URL` overrides it for another deployment. Users can also change the service from **Cloud controllers**. Rebuild after native dependency changes.
6. Connect ChatGPT to the HTTPS `/mcp` URL using the fixed OAuth client and the same account as the phone. Marketplace listing, other frontier-client compatibility and public OAuth-provider release checks remain separate work.

Google's OAuth app remains in **Testing**. Moving it to an appropriate production configuration and completing Google's applicable verification requirements is a public-release blocker. A successful test-user journey does not establish public availability.

## Walk the first journey

Open **Cloud controllers** from the controller menu or first-layout screen, sign in through the system browser, and keep the app open. Share the generated request with the AI client. The request identifies this phone without sharing credentials. The agent reads the schema, validates a controller, saves it with compare-and-swap, and sends the returned immutable revision to the explicitly selected phone.

The phone downloads and validates the profile, then issues `received`. Open practice to render it, or choose **Use this controller on Mac** while paired. Adoption stores an immutable local copy and waits for the receiver layout and neutral acknowledgements; it leaves controls paused until explicitly resumed. The foreground renderer issues `rendered` only for the exact offline selection or confirmed adopted LAN layout. A render receipt confirms the phone layout; it does not confirm Mac HID or game bindings. See the [adoption contract](cloud-contracts.md#paired-mac-adoption) and [live adoption evidence](evidence/cloud/mac-adoption.md).

After successful rendering, the profile is securely cached for offline practice. Signing out clears local credentials and the cache even without network access, and attempts server-side device revocation. Phone credentials expire after 30 days. Render receipts reconcile idempotently if the server commits an acknowledgement but the response is lost; account refresh uses a single exchange for concurrent requests.

**Delete account** opens the account-bound browser page without tokens in its URL. Fresh browser sign-in and explicit confirmation are required. On return, the app removes its secure cloud cache only after an authenticated `account_deleted` response. A callback alone, an ordinary expired-token response or a network error does not prove deletion. See [identity storage and deletion facts](evidence/cloud/identity-retention.md) for Apple revocation, retained security tombstones, offline copies and the limits of automated deletion tests.

## Automated checks and live evidence

From the repository root:

```sh
npm run test:cloud
npm run test:cloud:runtime
node apps/cloud/test-identity-runtime.mjs
npm run lint --workspace @tapping/mobile
npm run typecheck --workspace @tapping/mobile
```

The suites use signed access tokens, the SDK's Streamable HTTP transport, actual SQL and the phone's production delivery state machine. Coverage includes exact revisions, compare-and-swap conflicts, supersession, tenant/scope isolation, spoofed receipts, device expiry/revocation, foreground/LAN gating, secure cache cleanup, lost-response reconciliation and rotating refresh-token races. Better Auth runtime validation runs real PKCE/consent/token issuance, MCP delivery and deletion against isolated local workerd/D1. Its social session and device render receipts are fixtures; they do not prove a live Apple/Google sign-in or physical-phone render.

The latest development-signed Release build was installed on the intended iPhone through Xcode while preserving app data. On October 23, 2026, Google sign-in and phone registration completed. ChatGPT's refreshed **Thumble Pilot Cloud** plugin validated and saved `pilot-first-controller` revision 1, delivered it, and subsequently reported the phone's `rendered` receipt after the controller was opened in practice. The deployment record contains the delivery ID, conversation link and physical-phone screenshots. Apple live sign-in and the broader regression checklist below remain unverified.

For the live run, record the same profile ID **and revision** at save, download, renderer commit and receipt. Also exercise browser cancellation, refresh, background/foreground delivery, supersession, app restart with the cached controller, sign-out offline and revocation. A `queued` or `received` response is not a successful render. No real account deletion is authorized as part of routine journey validation.
