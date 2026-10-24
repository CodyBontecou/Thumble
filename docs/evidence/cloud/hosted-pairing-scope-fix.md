# Hosted pairing scope fix — October 24, 2026

Worker version: `ade9f4d6-61bc-4fd3-aa0c-1da125bc9ea0` on `thumble-cloud-pilot`.

Existing `oauthResource` records for the canonical and legacy MCP audiences still had the pre-pairing allowed-scope list. Better Auth defaults to insert-only resource seeding, so deploying new scope configuration did not update those records. Consent included `pairing:read`, but resource-token issuance intersected that request with the persisted policy and removed it.

The fix uses `resourceSeedMode: merge` for the operator-managed resources. Existing records receive the explicitly configured allowed scopes and access-token TTL; policy fields omitted from configuration remain unchanged. Client-specific scope restrictions and explicit consent still apply. MCP tools now also declare their OAuth requirements in top-level `securitySchemes`, mirrored under `_meta` for compatibility.

The deployment was built from the existing authentication-domain release plus the scope fixes, preserving canonical/legacy issuer handling and the account namespace. No secret or user grant was edited directly. Deployment used `--keep-vars` and required no schema migration.

Verification: 203 isolated unit tests passed. An actual Worker/D1 regression seeds an existing resource with the pre-pairing policy, authorizes an old ChatGPT grant, then requests the added pairing scope. It failed before the seeding fix and passed afterward, including the hosted image response, receiver permission separation, auth-domain migration and account deletion checks. Social identity and the phone renderer in that test are simulated.

Live readback confirmed both resource policies now include pairing scopes and a newly issued ChatGPT refresh grant includes `pairing:read` without `pairing:manage`. The replacement personal MCP app is named Thumble, ID `asdk_app_6add065d3b0c8191a7606ca344fb9730`, with `pairing:read` explicitly configured as a base scope. The older app remains installed. An imported v1.0.5 package also exists as an unused desktop-only personal package; the functioning ChatGPT connection was created through Add custom MCP server instead.

Live end-to-end verification succeeded after the owner authorized temporary receiver sharing: the replacement hosted `show_pairing_code` returned a single-use QR image directly in chat. This confirms hosted code availability; an actual phone scan and connection were not verified. The local receiver needed its existing Apple Development signature and approved HID provisioning profile to start; a separate local bundle avoided interference from concurrent receiver builds. No temporary QR, token or invitation is stored in this record.
