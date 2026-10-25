# Muse OAuth integration — October 24, 2026

Registered public client `thumble-muse`, restricted to the exact callback `https://agent.meta.ai/api/hatch/oauth/callback` confirmed in Muse's live sign-in flow. The client has no secret; PKCE S256 and explicit user consent are required. Only `offline_access profiles:read devices:read deliveries:read` are allowed, bound to `https://thumble.io/mcp`.

Muse setup and test chat: https://muse.ai/thread/3c507ecb-22f7-4e25-9e58-db5bb79b4297 . The owner explicitly approved persistent read-only access to the existing sample monitoring account and the sample-account reads. The OAuth callback and token exchange completed. Production readback found one consent and one active refresh grant with precisely the approved scopes and canonical resource; no token values were read or saved.

Worker version `1e627bcf-965a-4713-bc25-f6238e7b0928` adds a default resource indicator only for the fixed Muse authorization client when the request omits one. Explicit resource values still undergo normal provider validation. Other clients retain their existing handling, including the already-live Cline behavior. The prior live version was `c709ffbc-dbbf-4d4a-84d1-7f44cb99baf6`. Deployment used `--keep-vars`; no schema migration or existing grant replacement occurred.

The integration test exercises the real Better Auth provider, exact callback and scope rejection, missing-PKCE rejection, code exchange and refresh without a resource parameter, canonical token audience, and exact granted scopes. All 224 repository tests passed; deployment dry-run passed.

The sample account contains `glama-monitor-starter`, revision 1, named “Glama monitor sample”, zero devices and zero deliveries, verified independently in D1. Live MCP reads through Muse passed using its stored OAuth credential: initialize, tools/list (six tools), profile_schema, list_profiles, list_devices and get_profile. Muse returned the same sample profile at revision 1 with 18 controls and 18 mappings, and zero devices. Initial 45-second client attempts timed out; the completed test used a 120-second request timeout and reported no authenticated HTTP or JSON-RPC errors. No write or pairing operation was called. No real phone delivery receipt is available, so delivery_status remains untested.

The replacement marketplace submission is `9c318c5a-6bd7-4cf5-9965-bdda71f2205d`. OAuth client ID, PKCE setting, scopes and email-code reviewer instructions were submitted successfully. The owner explicitly approved using “Not applicable — email-code sign-in; see Notes” in the required Password field. Notes prominently state that this is not a credential, explain the five-minute email-code flow, and ask reviewers to coordinate a code via codybontecou@gmail.com. No password was created and unattended inbox access is not claimed. The portal displayed “Credentials submitted.” and a read-only summary with an Edit button. This confirms intake, not reviewer approval of the email-code process.

Evidence: [consent](../../marketplaces/evidence/muse-read-only-consent.png), [saved OAuth settings](../../marketplaces/evidence/muse-oauth-client-configured.png), [successful live test](../../marketplaces/evidence/muse-oauth-end-to-end-passed.png).

Credentials submission evidence: [submitted OAuth settings](../../marketplaces/evidence/muse-email-code-credentials-submitted.png).
