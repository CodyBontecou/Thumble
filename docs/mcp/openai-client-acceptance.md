# OpenAI-hosted remote MCP acceptance receipt

Acceptance date: 2026-08-23

## Client and endpoint

- Client binary: `/Applications/ChatGPT.app/Contents/Resources/codex`
- Client version: `codex-cli 0.149.0-alpha.4.1`
- Authentication: existing ChatGPT/Codex subscription in `~/.codex/auth.json`
- Provider/runtime: OpenAI-hosted Codex, launched ephemerally with user config
  disabled except explicit MCP overrides
- MCP endpoint: `https://thumble-mcp-gateway.fly.dev/mcp`
- MCP auth: short-lived bearer token issued by the production gateway's DCR,
  link-code consent, PKCE S256, and token endpoints
- Codex thread: `01a030a9-0c6b-7532-b654-d336eb97fac7`

The client recognized the server as a bearer-authenticated Streamable HTTP MCP
server and emitted native `mcp_tool_call` events with `server: "thumble"`.
No shell command was requested or used for the acceptance workflow.

## Tool-flow evidence

The OpenAI-hosted client called the production server and received successful
results for:

1. `configuration_status` — authoritative configuration revision `1`, writes
   enabled.
2. `host_status` — real isolated host running and reachable through the
   production relay.
3. `begin_configuration_draft` — draft
   `361daaa5-87bb-47a0-9561-474d66aa1023`, revision `1`.
4. `edit_configuration_draft` — corrected typed operation
   `profile.rename` with canonical `profileID`, changed the active profile name
   to **OpenAI MCP Acceptance**, draft revision `2`.
5. `validate_configuration_draft` — valid, zero errors, validator
   `rust-structural-v1`.
6. `preview_configuration_draft` — returned the renamed profile and complete
   bounded controller preview at draft revision `2`.
7. `save_configuration_draft` — commit
   `304437ec-f813-4061-8c0c-b8cc3ce828c5`, changed `true`, authoritative
   configuration revision `2`.

Two initial edit attempts intentionally demonstrated schema fail-closed
behavior: noncanonical `renameProfile` and `profileId` were rejected with
bounded schema errors; the model read those errors and retried with
`profile.rename` and `profileID`.

The isolated acceptance host was intentionally unpaired, so the live save
reported `phoneSyncQueued: false`. The in-process gateway e2e separately covers
the paired-phone boundary and asserts `phoneSyncQueued: true`.

## Independent authoritative verification

After Codex completed, direct host commands confirmed:

- `configurationRevision`: `2`
- Active profile ID: `70602144-2889-47BE-92A6-2D103DD7C138`
- Active profile name: **OpenAI MCP Acceptance**

The relay was then revoked through the production `/tunnel/revoke` path; the
device token was removed, the active relay stopped, the isolated host was
terminated, and production test rows were deleted.

## Acceptance conclusion

This is an actual OpenAI-hosted client acceptance through the ChatGPT.app
bundled Codex runtime, not a local mock: production TLS, OAuth, Streamable HTTP,
tool discovery, typed draft mutation, preview, save, and revoke all completed
end to end.

## Click-to-connect rollout and tool-discovery recovery

The native click-to-connect implementation was deployed on 2026-08-27 as Fly
release v15 with the matching release relay binary. The ChatGPT desktop flow
then completed **Connect → Mac Allow → automatic OAuth return** twice. Those
attempts exposed refresh-token reuse from an older, independent grant, so Fly
release v16 isolated every authorization in its own token family and made the
authorization-code exchange transactional. The pre-v16 database backup is
`/data/backups/thumble-gateway-20260827T195842Z.db.gz`; v16 runs image
`deployment-01M12CVNDBNJWVJ8VR6YH1SNT9`.

The production timeline also showed the gateway closing the control channel at
20:09 UTC while the relay retained a silent half-open TCP socket. The relay's
one-second token check had been cancelling and recreating its 30-second read
timeout, starving the intended dead-peer detector. The release relay now uses
an independent application-level keepalive interval, rejects WebSocket
Ping/Pong payloads as control messages, and has a silent → deceptive protocol
noise → healthy reconnect regression. The installed binary SHA-256 is
`79d46f87341a83ed602701f96f12d47e00eca1e32216841cbe857ef8454c7d70`.

After v16, OpenAI reported the Thumble link as `ACTIVE` with the requested
`thumble.read`, `thumble.draft`, `thumble.config`, and `offline_access` scopes,
but both its connector and link records still had an empty action catalog.
That stale OpenAI-side catalog—not OAuth or the gateway—was why the installed
plugin exposed no tools. Running the same **Refresh actions** operation used by
ChatGPT settings populated all 17 remotely allowed actions.

A post-repair acceptance probe used ChatGPT.app's bundled
`codex-cli 0.150.0-alpha.8` and the normal user configuration. It verified:

- the private Thumble plugin is installed and enabled;
- `app/installed` reports Thumble `callable: true`;
- `app/list` reports it accessible;
- `app/read` exposes 17 tool summaries;
- the hosted `codex_apps` runtime exposes 17 `thumble.*` tools; and
- a real `thumble.host_status` call completed through OpenAI, the production
  gateway, the patched Mac background relay, and `thumble-host`, returning
  `running: true` and authoritative configuration revision `5`.

A separate normal `codex exec --json` model turn, with no in-memory config
overrides, selected `codex_apps` → `thumble.host_status` exactly once and
returned `running: true` plus `configurationRevision: 5`. This confirms normal
model-level plugin discovery in addition to the direct app-server probe.

The redundant standalone `[mcp_servers.thumble]` registration was disabled
without deleting it because its separate OAuth credential was stale; the
plugin path is now the sole active Thumble registration. A fresh visible
ChatGPT conversation should still confirm the repaired UI surface before the
human UI acceptance is marked complete. The backend/plugin invocation above is
verified, but it is not being substituted for that final visible-chat check.
