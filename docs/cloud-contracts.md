# Cloud controller pilot — contract v1

First journey: an account-authenticated MCP client saves an immutable profile revision, requests delivery to an explicitly selected account-owned phone, and observes an acknowledgement from that phone. The phone can explicitly adopt that revision on its paired Mac using the LAN protocol below. Hosted MCP has no live input, WoW binding, arbitrary phone command or Mac activation tool.

## Authority and identity

Use a configurable established OAuth/OIDC authorization server, not a new password database. The Worker is an OAuth resource server; validate JWT signature, issuer, audience, expiry, required scopes and a stable `sub`. Account IDs are derived from issuer + subject; request arguments never choose an account. Production config must fail closed when issuer/audience/JWKS configuration is absent. Local tests use an isolated signing authority and never enable unsigned production tokens.

MCP requests use account access tokens with explicit scopes. Mobile uses authorization code + PKCE in the system browser with a configured public OAuth client, and SecureStore for credentials. Registration requires `devices:manage`; it returns an opaque high-entropy device token once, hashed at rest, expiring after 30 days. A device token is NOT an account access token. Only device tokens can acknowledge deliveries, and only for their registered device. Agent tools never expose device tokens or the acknowledgement endpoint.

## HTTP routes (JSON, /v1)

Success response is the JSON object below, not a wrapped `data` envelope. Error response is `{error:{code,message,details?}}`. Status codes: 400 invalid_request/invalid_profile, 401 unauthorized, 403 forbidden, 404 not_found (also for another account's resource), 409 revision_conflict/delivery_conflict, 413 payload_too_large, 503 not_configured. All responses with account/device data use Cache-Control: no-store.

- `GET /v1/config` public: `{apiVersion:1, auth:{issuer,authorizationEndpoint,tokenEndpoint,mobileClientId,audience,scopes}, mcpUrl}`. Endpoints come from deployment configuration / trusted issuer discovery; never tokens/secrets. No configured provider => 503, not a demo sign-in.
- `GET /v1/me` (account token): `{accountId}`.
- `POST /v1/devices` (`devices:manage`): `{name,platform:'ios'|'android',viewport:{width,height}}` => 201 `{device,deviceToken,expiresAt}`. Viewport in logical points. Device `{id,name,platform,viewport,createdAt,lastSeenAt,revokedAt:null|ISO}`.
- `GET /v1/devices` (`devices:read`): `{devices:[device]}`.
- `DELETE /v1/devices/:deviceId` (`devices:manage`): `{revoked:true}`. Revokes device token and pending deliveries; deleting someone else's device is 404.
- `GET /v1/profiles` (`profiles:read`): `{profiles:[{id,name,revision,updatedAt}]}`.
- `GET /v1/profiles/:profileId` (`profiles:read`): `{profile,revision,createdAt}` latest.
- `GET /v1/profiles/:profileId/revisions/:revision` (`profiles:read`): same shape, immutable revision.
- `POST /v1/profiles/validate` (`profiles:write`): `{profile,deviceId}` => `{valid,errors,viewport,limits}`. Target must be owned and active. Checks the schema, actual capture geometry, minimum target sizes and toolbar clearance for its current usable canvas. No write.
- `POST /v1/profiles` (`profiles:write`): `{profile,deviceId,expectedRevision}` => 201 `{profile,revision,createdAt}`. Validates geometry against that owned phone before writing; `invalid_layout` includes named corrections in `details`. Existing saved profiles remain readable. `expectedRevision:0` creates, otherwise exact compare-and-swap against latest. Conflict never silently retries. Every revision retained. Reject an expected revision whose increment would exceed the safe integer range.
- `POST /v1/devices/:deviceId/viewport` (that device's token only): `{width,height}` => `{viewport:{width,height}}`. The phone reports the actual controller canvas after safe-area insets and controller margins, in logical points. It synchronizes dimensions before polling deliveries and before sharing a new request.
- `POST /v1/deliveries` (`deliveries:write`): `{deviceId,profileId,profileRevision,requestId}` => 201 `{delivery}`. requestId is an account-scoped idempotency key (1–80 alphanumeric/_/- chars). Same key+same args returns original delivery; changed args returns 409. Supersedes any queued/received delivery for this device. Verify exact immutable revision exists in same account, and the phone credential has not expired or been revoked.
- `GET /v1/deliveries/:deliveryId` (`deliveries:read`): `{delivery}`. No claim of render before device receipt.
- `GET /v1/devices/:deviceId/deliveries` (device token only): `{deliveries:[{delivery,profile}]}` current non-superseded pending item (or empty). Includes validated immutable profile. Poll while app foregrounded, 3 seconds; no persistent background work required.
- `POST /v1/devices/:deviceId/deliveries/:deliveryId/ack` (device token only): `{profileId,profileRevision,state:'received'|'rendered'|'failed',error?:string}` => `{delivery}`. Match device+profile+revision; Allowed transitions are queued → received/failed and received → rendered/failed; exact repeats are idempotent, terminal/superseded cannot advance. `rendered` only after actual controller render commit. Errors contain bounded user-facing descriptions, no tokens.

Delivery `{id,deviceId,profileId,profileRevision,requestId,state,createdAt,updatedAt,error:null|string}`. New deliveries recheck the exact saved revision against the target's current canvas before superseding anything. Targets need 48 logical points on both dimensions; sticks need a 96-point diameter. Touch regions cannot overlap another control or the reserved top Chat/menu areas. Cloud delivery IDs/revisions are independent from LAN activation revisions/leases. A cloud `rendered` receipt confirms the phone renderer, not Mac HID or WoW actions.

## Mobile behavior

Cloud library remains useful without Mac pairing. Fetch and validate profile before preview. Keep last acknowledged cloud profile cached securely for offline practice; scope cache/credentials by service + account, clear on logout/account change. Poll only foreground and authenticated; cancel stale work on logout/account change. Logout revokes the registered device when possible and clears credentials even offline.

When LAN is connected, incoming cloud delivery only downloads and validates the revision. **Use this controller on Mac** requires an explicit action. Revalidate the authenticated account, refresh the Mac catalog and adopt against its exact activation revision. The receiver remains the authority for the live layout. Mark received after download/validation; rendered only from its committed foreground renderer. A LAN render receipt additionally requires the confirmed adoption proof to match the current pairing session, local profile ID and activation revision, with layout and neutral acknowledgements complete. Discard stale/superseded asynchronous results and pause live controls on layout changes. Resume requires a separate explicit action.

## Paired Mac adoption

Handshake capability `cloudAdoption:1` permits authenticated `profile-adopt` messages up to 65,536 UTF-8 bytes; other phone commands retain the 4,096-byte limit. Request fields are `requestId`, `expectedActivationRevision`, `profile`, and `source:{service,accountId,profileId,revision}`. Service is an HTTPS origin/path without credentials, query or fragment; account ID is the cloud account hash; source ID must match the validated profile. No OAuth credentials travel to the receiver.

The receiver validates the declarative controller schema and provenance, releases input, then performs an atomic catalog compare-and-swap under the shared write lock. Each cloud revision becomes an immutable local revision-1 copy named `cloud-<40 hex characters>`, derived from the canonical source hash, with `cloudSource` metadata on its catalog entry. Existing local controllers are preserved. Repeating the same adopted revision is idempotent; changing its content or using a stale activation revision fails. A newer cloud revision gets a separate local ID.

The catalog response includes `adoption:{profileId,profileRevision:1,source}`. Phone success requires matching provenance and exact profile content, receipt of the receiver-owned layout, a render commit, and a fresh neutral acknowledgement. Disk persistence alone is insufficient. A disconnect or account/selection change cancels the success claim; an already accepted disk operation can still finish while controls remain paused. Provenance is supplied by the authenticated paired phone, not a server signature. The receiver does not sign into or fetch from the cloud.

## Hosted MCP /mcp

Stateless Streamable HTTP (2025-11-25); initialize, tools/list, tools/call, ping, notifications. SDK transport preferred. Every tool authenticates account access and enforces scopes. Tools: `profile_schema`, `validate_profile`, `list_profiles`, `get_profile`, `save_profile`, `list_devices`, `deliver_profile`, `delivery_status`. Tool arguments mirror API names. Explicit deviceId and saved profileRevision are mandatory for delivery. No accountId or acknowledgement tools. Return structuredContent plus matching JSON text; errors are isError with actionable codes. Tool annotations describe reads/writes accurately. OAuth protected-resource metadata advertises the configured trusted authorization server and the MCP resource audience. No hosted filesystem/addon-export tool.

## Implementation ownership

Coordinator owns packages/cloud-contracts, this contract/ADR, worker composition, root dependency/lock changes and cross-layer tests. Backend owns apps/cloud backend storage/auth/REST plus migrations and backend tests. MCP owns apps/cloud/src/mcp.js and MCP tests/docs (coordinates imports with backend). Mobile owns apps/mobile cloud modules/screens and their integration into existing renderer/onboarding, mobile native dependency config, plus tools/test/cloud-mobile.test.js. No deployment or live receiver restart during implementation.
