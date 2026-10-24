# Hosted controller MCP pilot

The Worker serves stateless Streamable HTTP at `/mcp`. Point a compatible remote MCP client at the deployed HTTPS URL and connect the same account used by the phone. The client must support OAuth against the configured authorization server; marketplace listing and provider-specific app review are separate release work.

The shared [cloud contract](cloud-contracts.md) defines authority, REST shapes and phone receipt semantics. The implementation uses the official TypeScript SDK's Web Standard transport, with one request-local server instance and no in-memory sessions. Persistence belongs to D1, not the MCP process.

## First journey

1. Sign in on the phone and register it from Cloud controllers.
2. In the agent client, call `list_devices` and explicitly choose the intended phone. Its viewport helps size the controller.
3. Read `profile_schema`, construct a controller and call `validate_profile` with the chosen `deviceId`. Fix all named size, overlap and toolbar-clearance errors.
4. Call `save_profile` with that same `deviceId` and `expectedRevision: 0` to create it. For edits, read `get_profile` and use its revision as `expectedRevision`. The service enforces layout checks even if validation was skipped.
5. Call `deliver_profile` with the chosen `deviceId`, saved `profileId`, exact `profileRevision` and a fresh `requestId`.
6. Keep the phone app foregrounded. Open offline practice or explicitly choose **Use this controller on Mac** while paired. Call `delivery_status` with the returned delivery ID. A `rendered` receipt confirms this exact revision committed on the phone. It does not confirm game input or bindings. Follow **AI to WoW** on the phone for Mac readiness and player-confirmed game checks.

Reusing a request ID with the same arguments returns the original delivery. A revision conflict requires reading the latest revision and reconsidering the edit. Do not retry writes blindly. A later delivery can supersede a queued or received delivery.

## Thumble brand assets

Both MCP servers advertise `resources: {}` and support `resources/list`,
`resources/read` and an empty `resources/templates/list`. The four PNG resources
use stable URIs: `thumble://assets/icon.png`, `thumble://assets/thumble-menu.png`,
`thumble://assets/splash-icon.png` and `thumble://assets/favicon.png`. Reads return
base64 `blob` contents with `image/png`. Unknown URIs return MCP error `-32002`;
clients cannot use this endpoint to read arbitrary files or URLs.

The cloud Worker also serves the same files publicly at `/assets/thumble/<file>`
with GET/HEAD, PNG content types, wildcard image CORS and one-hour public caching.
These public images require no account token; `/mcp` resource operations still
authenticate every request. Both Wrangler configurations bind `assets/public`
as `ASSETS` and run the Worker first so its routing and headers apply.

Hosted MCP initialization advertises the canonical service's
`/assets/thumble/icon.png` in `serverInfo.icons`; the local server embeds the icon
as a data URI. ChatGPT's registered app logo is configured separately in the app
registration; serving this icon does not update that registration automatically.
No ChatGPT widget is registered by this change.

See [asset maintenance](../assets/README.md) for updating the public copies.
The implementation follows [MCP resources](https://modelcontextprotocol.io/specification/2025-11-25/server/resources)
and [Cloudflare asset bindings](https://developers.cloudflare.com/workers/static-assets/binding/).

## Authentication and browser clients

Protected-resource metadata is available at `/.well-known/oauth-protected-resource/mcp` (also aliased at the root metadata path). It advertises `OAUTH_AUDIENCE` as the resource and `OAUTH_ISSUER` as its authorization server. Configure the audience as the canonical HTTPS MCP resource URL and issue access tokens for that exact audience. Every request is authenticated, including initialize and tool discovery; each tool also enforces its required scope. The eight tools never accept an account ID and never return a phone credential.

Server and native clients normally omit `Origin`. Browser clients with an `Origin` header must match the service origin or an explicit comma-separated `MCP_ALLOWED_ORIGINS` deployment setting. CORS support, if needed, should use that same allowlist; adding an allowed origin does not grant an account scope.

The pilot includes no phone acknowledgement, device registration, filesystem access or arbitrary device-control tools. Registration and render receipts stay inside the authenticated mobile flow.

## Verification

Run `node --test apps/cloud/test/mcp.test.js` after workspace dependency installation. Tests exercise the actual SDK transport (initialize, discovery, call, ping, notifications), argument guards, scoped access, REST forwarding, conflicts, metadata and browser-origin rejection. Cross-layer tests should additionally use signed account tokens and persistent D1 data to exercise save → delivery → phone receipt.

Primary implementation references: [SDK Web Standard transport](https://github.com/modelcontextprotocol/typescript-sdk/blob/v1.x/src/server/webStandardStreamableHttp.ts), [MCP Streamable HTTP specification](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports), [MCP authorization](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization).

## Better Auth sign-in and consent

The hosted pilot uses Better Auth with Apple and Google social sign-in. Its authorization server lives under `/api/auth`; `/sign-in` and `/consent` are browser views for that server. Social callbacks must be registered as the deployed origin followed by `/api/auth/callback/google` or `/api/auth/callback/apple`. A provider button appears only after its provider credentials are configured. An unconfigured deployment cannot issue a pretend sign-in.

The login view forwards the provider-signed OAuth query through social sign-in. Better Auth verifies that query and resumes authorization after the social callback. The consent view separately verifies the signed query with Better Auth before displaying the requesting application's public name, its ID, requested scopes, resource URLs and any identity claims. The signed query is short-lived; changing a scope invalidates it. Approve and cancel submit the exact signed request to Better Auth without adding scopes. The provider remains responsible for client registration, redirect URI, session, PKCE, origin and CSRF validation.

Pages use same-origin JSON requests with session cookies, a per-response script nonce, no-store caching, frame restrictions and a no-referrer policy. Test coverage includes actual Better Auth signature verification against tampering and expiration. Provider credentials, social identity creation and marketplace approval remain deployment steps and require their respective account owners.

## Account deletion

The phone opens `/account?accountId=…` without sending tokens in the URL. The browser derives its own account ID from the authenticated user and issuer, then compares it with that expected phone account. A mismatch never displays a deletion action. Deletion requires a recent social sign-in and an explicit confirmation checkbox. The browser submits a same-origin, session-bound request to Better Auth; an account assertion header prevents a different browser session from being deleted if the session changes after the page loads.

The page shows success only after the server confirms deletion. Returning to Thumble triggers a separate authenticated account check before the app clears its secure cloud cache. A callback URL or `deleted` query flag cannot prove deletion. Other offline devices may retain cached controllers until they reconnect or sign out.
