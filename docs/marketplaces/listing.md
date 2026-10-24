# Thumble listing and reviewer copy

Publisher: Thumble  
Contact: codybontecou@gmail.com  
Website: https://thumble.io  
Support: https://thumble.io/support  
Privacy: https://thumble.io/privacy  
Terms: https://thumble.io/terms (published October 23, 2026).  
MCP: https://thumble.io/mcp  
Transport: stateless Streamable HTTP over HTTPS; OAuth required for discovery and tools.

## Public copy

**Name:** Thumble  
**Subtitle:** Controller layouts for phones

Create, validate, save, and send custom controller layouts to your Thumble phone for practice. Connect the same account on your phone and AI assistant, choose a registered phone, and confirm the exact layout revision rendered. Layouts can include buttons, sticks and triggers, with labels and placement suited to your screen.

Cloud access is currently a pilot. Phone app installation and a registered device are required for delivery. The Apple-approved iOS 1.0.0 (3) review build is available at https://testflight.apple.com/join/kxwHv4qW (Marketplace Review, capped at 10 testers). Local setup and practice are free. Live connected controller use includes a 30-minute total demo; Pro is a $19.99 USD base-price one-time native store purchase that removes the time limit. This connector does not sell Pro or process payments.

Hosted tools manage controller layouts and phone practice. Game input uses the separate paired local Mac receiver; a `rendered` cloud receipt does not prove Mac input or game bindings.

## Permissions and effects

| Tool | Required scope | Effect |
| --- | --- | --- |
| `profile_schema` | `profiles:read` | Read layout schema and constraints. |
| `validate_profile` | `profiles:write` | Check a supplied layout without saving or delivering. Although non-mutating, current implementation requires the write scope. |
| `list_profiles` | `profiles:read` | Read saved layout names and latest revisions for the connected account. |
| `get_profile` | `profiles:read` | Read a saved layout/revision. |
| `save_profile` | `profiles:write` | Save an immutable revision using expectedRevision. Does not deliver. |
| `list_devices` | `devices:read` | Read registered phone names, IDs, viewports and last-seen times; no phone credentials. |
| `deliver_profile` | `deliveries:write` | Queue one exact saved revision on an explicitly selected phone; supersedes a pending delivery. |
| `delivery_status` | `deliveries:read` | Read queued, received, rendered, failed or superseded status. |

No hosted tool can register phones, send game input, access arbitrary files, send messages or process payments. The AI scope set excludes `devices:manage`. `openid` and `offline_access` support identity and refresh access. OAuth uses PKCE; no shared bearer token is distributed.

Inputs and outputs follow the tool schemas discovered from MCP. Requests are limited to 262144 bytes by the shared contract; layout validation imposes additional constraints. Account scope is derived from the verified bearer token, never a tool-supplied account ID. Authentication is database-rate-limited in code; no verified production general-throughput quota is advertised here. Handle throttling according to returned errors.

Revision conflicts require rereading and reconsidering the edit. Retry a delivery with the same requestId only when its arguments are identical. Check receipt status before claiming success; do not retry writes blindly or treat queued as rendered. An offline phone may not provide a receipt until it reconnects.

## Reviewer setup — still to execute

Use a dedicated sample-data account, never the owner's private library. Supply account credentials and private installation access through the marketplace's secure review fields, outside public packages. Email-code sign-in is live; reviewers must control the dedicated account inbox. Each marketplace needs a working OAuth client before these instructions are executable there.

1. Install the intended Thumble phone build and sign in to Cloud controllers.
2. Register the test phone. Keep it foregrounded and disconnected from its Mac receiver for practice.
3. Connect the MCP integration to the same account and approve only the documented AI scopes.
4. Run the five positive and three negative scenarios in the OpenAI manifest. Record actual tools/results for each; they are proposed cases, not claimed passes.
5. Demonstrate a rendered receipt and the corresponding layout on the actual phone. Include the walkthrough URL in review metadata after recording.

Existing evidence: [owner Google / ChatGPT / physical iPhone pilot](../evidence/cloud/pilot-deployment.md). This establishes one live owner happy path; it does not replace the dedicated review run, cross-client tests or public availability checks.

Data handling evidence: [identity retention](../evidence/cloud/identity-retention.md), [cloud contract](../cloud-contracts.md), [hosted MCP](../hosted-mcp.md).
