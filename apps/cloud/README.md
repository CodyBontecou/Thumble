# Thumble cloud service

The Worker stores immutable controller revisions and phone receipts in D1. Better Auth 1.7.12 provides persistent Apple/Google accounts, browser sessions, signing keys, OAuth grants and client consent. The Mac receiver remains responsible for game input.

## Better Auth deployment

| Variable | Purpose |
| --- | --- |
| `BETTER_AUTH_URL` | Public HTTPS origin, with no path; auth issuer is this origin plus `/api/auth` |
| `BETTER_AUTH_SECRET` | Strong stable secret of at least 32 characters; protects sessions and signing keys |
| `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` | Google web OAuth client, callback `${origin}/api/auth/callback/google` |
| `APPLE_CLIENT_ID` | Apple Services ID |
| `APPLE_TEAM_ID`, `APPLE_KEY_ID`, `APPLE_PRIVATE_KEY` | Apple signing credentials; the PKCS8 P8 key remains a Worker secret |
| `CHATGPT_CLIENT_SECRET` | Optional confidential-client secret, at least 32 characters; omit for public PKCE |
| `CHATGPT_REDIRECT_URIS` | JSON array of exact registered HTTPS ChatGPT callback URLs |

Apply all four D1 migrations before deploying. `0002_better_auth.sql` was generated with the installed Better Auth 1.7.12 configuration, including JWT and MCP provider plugins. Migrations 0003 and 0004 add account-deletion protection and remove unused provider profile data. Keep `BETTER_AUTH_SECRET` stable across deployments or use the framework's explicit secret-rotation process. Google and Apple credentials are server-only; provider OAuth tokens are encrypted at rest; Apple client-secret JWTs are generated dynamically with ES256 and expire after five minutes.

The native public client is `thumble-mobile`, requires S256 PKCE, and uses the exact callback `thumble://cloud-auth/callback`. The fixed client `thumble-chatgpt` uses public PKCE (`none`) by default. When a client secret is explicitly configured, it uses `client_secret_post`. Both modes require PKCE. ChatGPT is restricted to controller profile, phone-list and delivery scopes; it cannot request `devices:manage`. The native client retains device-registration permission. Public discovery advertises the narrower AI scope set, while `/v1/config` supplies the full native scope set explicitly. Both use public subject identifiers, so the same signed-in user gets the same account in either client. Every authorization requires consent. Dynamic registration, client credentials grants, passwords, public client CRUD, and the JWT session shortcut are disabled. Social callbacks preserve the signed OAuth request through the provider login and return to consent.

The resource audience is `${origin}/mcp`, the issuer is `${origin}/api/auth`, and the public signing keys are available at `${origin}/api/auth/jwks`. Resource verification reads those keys through Better Auth in-process and still checks JWT signature, issuer, audience, expiry and scopes. Neither a session cookie nor an identity token grants direct access to controller APIs.

Without Better Auth configuration, the earlier external JWT resource-server mode remains available for isolated contract tests. It uses explicit `OAUTH_ISSUER`, `OAUTH_AUDIENCE`, `OAUTH_JWKS_URL` or pinned public `OAUTH_JWKS_JSON`, and public OAuth endpoint/client configuration. There is no unsigned-token mode.

## Validation

Run `npm test --workspace @tapping/cloud` for backend, identity and MCP tests. Tests use isolated signing authorities and local SQL, never production credentials. `node apps/cloud/test-identity-runtime.mjs` bundles the actual Worker and runs native/ChatGPT authorization, consent, token issuance and MCP delivery against real local workerd/D1. Its preexisting user/session and phone receipts are explicitly simulated; Apple/Google browser sign-in and a physical phone still need live validation. `node apps/cloud/test-runtime.mjs` preserves the external JWT resource-server runtime test.

Profile writes use atomic SQL compare-and-swap. Delivery creation and supersession run in a D1 batch transaction with an account-scoped unique request key. Conditional receipt updates preserve exact immutable revisions and monotonic transitions. Phone credentials expire after 30 days and only their SHA-256 hashes are stored. Revocation invalidates polling/receipts and supersedes pending deliveries.

See the coordinator's `docs/cloud-pilot.md` for deployment and the complete first-journey runbook.
