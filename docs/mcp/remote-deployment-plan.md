# Hosted MCP server for ChatGPT controller building — end-to-end plan

Status: the remote connector foundation and click-to-connect Mac approval are
**implemented and deployed** (see “Implementation state” below). Fly release
v16 and the local release relay are live as of 2026-08-27. Native Allow and
automatic OAuth return completed in ChatGPT; an OpenAI-side empty action catalog
was refreshed, and the hosted plugin then discovered and successfully invoked
`host_status`. A fresh visible ChatGPT conversation is still pending as the
final human UI receipt. The local stdio adapter's default behavior and
host-authority model are unchanged. The prior link-code release was also
accepted by the authenticated OpenAI-hosted Codex runtime bundled inside
ChatGPT.app.

## Goal

Let ChatGPT (developer-mode custom connector) build Thumble controller
setups through the same revision-safe, typed tool surface that local MCP
clients use today — without moving configuration authority off the user's
Mac and without exposing the host control socket directly to the network.

## Constraints that shape the design

1. `thumble-host` is the single configuration authority (drafts,
   revisions, commits, phone delivery). Rich operations require the
   macOS Swift bridge (`thumble-bridge`), which only runs on the user's
   Mac. See `docs/mcp/README.md` § Authority.
2. `docs/rust-host.md`: a remote deployment "requires a separately
   authenticated Streamable HTTP transport with TLS and per-tool
   authorization; do not expose this stdio process or the host control
   socket over the network."
3. ChatGPT connectors speak MCP over **Streamable HTTP** with
   **OAuth 2.1 authorization code + PKCE (S256)**, resource metadata
   (RFC 9728), **dynamic client registration** (RFC 7591), refresh
   tokens (`offline_access`), and bearer auth on every request. ChatGPT
   does **not** render MCP Apps UI, so remote sessions rely on the
   structured/JSON and textual/SVG fallbacks that `render_controller`
   and `export_controller_preview` already return.

## Architecture: authenticated relay (gateway + outbound tunnel)

```
ChatGPT ──HTTPS (Streamable HTTP, OAuth 2.1)──> thumble-gateway (cloud)
                                                   │  per-tool scope gate,
                                                   │  rate limits, session routing
                                                   │ WebSocket (outbound from Mac,
                                                   │ device-token auth, TLS)
                 thumble-mcp --relay <-----------┘
                   (on the user's Mac; serves the existing
                    ThumbleMcp 20-tool handler)
                       │ unix socket (unchanged, user-only)
                    thumble-host ── profile sync ──> iPhone
```

Decision: **the MCP handler stays on the Mac.** The gateway is an
authenticated router that terminates Streamable HTTP and proxies whole
JSON-RPC MCP sessions to the user's own `thumble-mcp` relay process over
an outbound WebSocket. Consequences:

- The gateway never receives host `ControlResponse` payloads directly —
  it relays already-sanitized MCP JSON (the same bytes ChatGPT sees).
- Tool schemas, sanitization, drafts, commits, phone delivery, and the
  Swift bridge all stay local; the parity contracts stay intact.
- Existing policy flags (`--allow-input`, `--allow-config-write`,
  `THUMBLE_MCP_ALLOW_INPUT`, `THUMBLE_MCP_ALLOW_CONFIG_WRITE`) keep
  working unchanged as the inner, fail-closed gate.
- The Mac must be online with `thumble-host` running while ChatGPT is
  used. That is acceptable for v1: building for your paired phone
  already requires your Mac.

Rejected alternative (deferred, not dropped): a stateless cloud builder
that runs host logic server-side and emits an importable package. It
contradicts host authority, needs a Linux-capable Swift bridge, and
needs full profile/package export+import — which the ledger still lists
as in active development. Revisit once export/import ships; it could
become a second, tunnel-free connector mode later.

## Components and changes

### 1. Transport seam refactor — `Host/crates/thumble-mcp`

- Extract the funnel at `ThumbleMcp::request` → `send_request(socket)`:
  introduce a `HostChannel` trait (`async fn request(&self, req:
  ControlRequest) -> Result<ControlResponse, String>`) with the current
  unix-socket implementation as the default. `ThumbleMcp::new` takes the
  channel. No behavior change for stdio.
- Add relay mode to the same binary: `thumble-mcp --relay wss://…/tunnel
  --relay-token-file …` (mutually exclusive with stdio transport). It
  dials out with TLS + backoff/reconnect, authenticates with the device
  token, and serves the same `ThumbleMcp` handler over the tunneled
  stream via an rmcp custom transport (one JSON-RPC message per frame,
  256 KiB cap, reusing `JsonRpcMessageCodec` bounds).
- Audit logging extended with relay connect/disconnect events (tool
  audit events unchanged).

### 2. Gateway crate — `Host/crates/thumble-gateway` (new workspace member)

Stack: axum + rmcp (streamable HTTP server/client features) + rusqlite
(SQLite on a persistent volume). No host, no Swift bridge, no phone
logic — routing and auth only.

- `POST/GET/DELETE /mcp` — Streamable HTTP endpoint for ChatGPT
  (`Mcp-Session-Id` handling, SSE responses, 256 KiB caps). Bearer token
  required on every request; `401` + RFC 9728 `WWW-Authenticate` on
  missing/expired tokens. Legacy `2025-11-25` requests remain stateful;
  modern `2026-07-28` `server/discover`, list, and call requests are
  stateless, carry required per-request metadata/headers and result/cache
  discriminators, and accept only the gateway and exact ChatGPT origins.
- OAuth 2.1 authorization server:
  - `/.well-known/oauth-protected-resource` and authorization-server
    metadata (PKCE `S256`, scopes, `registration_endpoint`).
  - `/register` — RFC 7591 dynamic client registration (ChatGPT uses it).
  - `/authorize` — login page implementing **device-link pairing** (see
    §3) and scope consent; strict redirect-URI validation.
  - `/token` — code exchange (PKCE), refresh tokens with rotation
    (`offline_access`), short-lived access tokens (JWT or opaque),
    hashed-at-rest storage.
- `/tunnel` — WebSocket endpoint for the Mac's relay client. Device
  token auth; registers the tunnel online; maps account ↔ tunnel.
- Session proxy core: for each ChatGPT MCP session, run an rmcp client
  bound to the account's tunnel and forward JSON-RPC. Per-tool scope
  gate **before** forwarding (defense in depth on top of the local
  gates). Cache each device's `tools/list` manifest so the connector
  still validates when the Mac is offline. The remote projection omits
  optional output schemas and replaces the large edit-operation union with
  a compact strict envelope plus all canonical operation discriminators to
  stay within ChatGPT's action-discovery budget; the Mac still validates the
  complete canonical schema before any edit. Tool calls fail fast with a
  friendly "start thumble-host and the relay" error.
- Rate limits and abuse controls: reuse the `PressRateLimiter` pattern
  for per-account tool-call limits; per-account concurrent MCP sessions
  (≤ 3), tunnel message caps, link-code attempt caps.
- `GET /healthz` for uptime checks.

### 3. Pairing / account linking

Primary UX is click-to-connect with device-side approval; the six-digit
pattern remains only as a headless fallback:

- `thumble-mcp --relay` opens a link window. It still prints the gateway
  `/link` URL plus a one-hour, 10-attempt, single-use six-digit fallback
  code; on macOS it copies the code to the clipboard without opening an
  extra browser tab (`THUMBLE_RELAY_NO_BROWSER=1` disables that assist).
- When the user clicks **Connect** for Thumble in ChatGPT, `/authorize`
  creates the server-bound OAuth request and pushes a bounded
  `ConnectorApprovalRequest` to an open link socket. If the device is
  already linked, a later authorization can use its authenticated control
  tunnel instead — no credential rotation is required.
- The relay renders a native macOS dialog. Clicking **Allow** sends a
  request-ID-bound decision while the relay continues pumping liveness
  frames. `/authorize/wait` polls the in-memory decision and returns the
  PKCE authorization callback automatically. Clicking **Deny** ends the
  browser wait without minting a code. The fallback link leaves polling for
  a stable `/authorize/code` form so refresh cannot discard typed digits.
  `THUMBLE_RELAY_NO_PROMPT=1` opts out for SSH/headless sessions.
- Automatic prompts are enabled only for verified ChatGPT callback hosts,
  then routed only to pending/online relay connections whose
  gateway-observed source matches the authorization browser. Forwarded
  source headers are trusted only on Fly (or explicit operator opt-in), each
  exact connection gets at most one live prompt, and the dialog defaults to
  Deny. The first offered connection to decide wins; decisions from
  unoffered connections fail closed, while completion closes every offered
  prompt. The fallback form remains for unverified clients, source mismatch,
  unavailable native UI, or explicit headless use.
- On a first link, approval mints the revocable device token. The gateway
  withholds OAuth success until the relay acknowledges that the token was
  atomically persisted; explicit persistence failure fails closed. The
  completion page names the linked device (hostname by default —
  `--device-name` overrides). **Explicit rotation remains in place**:
  `thumble relay rotate` authenticates the link socket with the current
  token and replaces that device's credential — same identity, OAuth
  bindings, and cached manifest, with no dual-valid-token window. After the
  durable handoff, the gateway forces the previous authenticated control
  socket to reconnect with the stored token. Ambiguous mid-network failures
  surface as failed linking and are recoverable with `relay doctor` plus a
  fresh link/rotation; stale credentials fail closed.
- Scopes map to tool families (gateway outer gate; the local flags
  remain the inner gate and both must allow):

| Scope | Tools |
|---|---|
| `thumble.read` (default) | `host_status`, `accessibility_status`, `configuration_status`, `list_profiles`, `list_controls`, `render_controller`, `query_catalog` |
| `thumble.draft` | `begin/get/edit/rebase/validate/preview/export/discard_configuration_draft` (non-authoritative) |
| `thumble.config` | `save_configuration_draft`, `select_profile` (also requires host `--allow-config-write`) |
| `thumble.input` | `press_control` (also requires `--allow-input`; **not grantable in v1**) |

  `release_all`, `pairing_code` stay gateway-blocked remotely (pairing
  codes are for the local phone flow; emergency release has no meaning
  over a tunnel and the host releases held input on disconnect anyway).

### 4. CLI parity and lifecycle (AGENTS.md)

- New `thumble` CLI commands wrapping the relay:
  `thumble relay connect [--allow-config-write]` (one managed link-and-serve
  flow), `relay status` (including gateway liveness and manifest readiness),
  `relay rotate` (atomic in-place device-token rotation with live-relay
  reload), `relay revoke` (revokes the device token at the gateway), legacy
  `relay link` (link-only primitive), `relay doctor` (merged local + gateway
  readiness report with concrete fixes; non-zero exit when not ready), and
  `relay install` / `relay uninstall` (launch-agent background service, no
  terminal window required). No macOS app changes are required in v1; when
  an app "Remote connectors" pane lands later it must reuse these commands.
- Launchd-friendly: `relay connect`/the foreground `--relay` process can run
  under KeepAlive; token rotation is detected without a second manually
  managed relay process.

### 5. Deployment

- `Host/crates/thumble-gateway/Dockerfile` (multi-stage Rust build,
  Debian runtime with online SQLite backup tooling). Deployed to **Fly.io**
  as `thumble-mcp-gateway` in `iad`: native tokio/WebSocket support, TLS
  termination, health checks, an encrypted persistent SQLite volume, daily
  `.backup` archives, and Fly scheduled volume snapshots. (A $5 VPS + Caddy
  is an equivalent alternative; Cloudflare Workers is not — rmcp/tokio do
  not fit the WASM model.)
- Secrets: `THUMBLE_GATEWAY_BASE_URL`, `THUMBLE_GATEWAY_TOKEN_SECRET`
  (signing), SQLite path on volume. Domain suggestion:
  live hostname `thumble-mcp-gateway.fly.dev` and connector URL
  `https://thumble-mcp-gateway.fly.dev/mcp`. A custom `mcp.thumble.app`
  alias can be added later when DNS-write credentials are available.
- Backups: daily consistent SQLite `.backup` + checksum to the volume,
  optional authenticated off-platform PUT upload, plus Fly scheduled volume
  snapshots; token revocation data is included.

### 6. Contracts, docs, gates

- `docs/mcp/cli-capabilities-v1.json`: add remote-connector entries with
  honest `planned` status (never imply availability — ledger rule), and
  the new `gates` values (`remote-session`, `remote-scope:*`) if the
  verify script's gate vocabulary is extended deliberately.
- `docs/rust-host.md`: replace the "intentionally local stdio only"
  paragraph with the remote section (transport, auth, scopes, tunnel,
  CLI, and the unchanged inner gates). Keep the warning that the stdio
  process and control socket must never be exposed directly.
- `docs/mcp/README.md`: remote deployment notes; state that the gateway
  is a router and never an authority.
- No Swift/shared-model changes → `Tests/StackSafetyRegressionTests` and
  `./scripts/verify-stack-safety.sh` are unaffected (still run in CI).

## Security checklist (ship blockers)

- TLS everywhere; HSTS on the gateway.
- Bearer token on every `/mcp` request; `401` + RFC 9728 metadata; exact
  redirect-URI matching; PKCE S256 enforced.
- Refresh-token rotation with reuse detection, plus a bounded 60-second
  grace window for concurrent refreshes: multi-window clients such as the
  ChatGPT desktop app share one token cache across chat runtimes, so a
  just-rotated token may be exchanged again within the window (at most four
  live successors per credential, active devices only). Every independent
  authorization receives its own random token family, propagated through
  normal and grace rotations. Replays after the window, past the budget, or
  on revoked devices revoke only the matching device/client/family; explicit
  device revocation remains device-wide. Legacy empty-family rows remain
  rollback-compatible. Override or disable the grace window via
  `THUMBLE_GATEWAY_REFRESH_GRACE_SECONDS` (0 = strict replay revocation).
  Authorization-code consumption and access/refresh issuance are one SQLite
  transaction. All tokens/keys are hashed at rest; device tokens are
  revocable via `thumble relay revoke`.
- Push approvals: verified ChatGPT callback hosts, five-minute TTL, opaque
  server-side request IDs, exact offered-connection binding,
  first-decision-wins, trusted-proxy/same-source routing, and one active
  prompt per target. The dialog defaults to Deny and never blocks tunnel
  liveness; timeout/unavailable UI never auto-approves. Deny and timeout
  consume the authorization request. Link codes remain a 6-digit, 1-hour,
  10-attempt, single-use fallback and are claimed transactionally with the
  authorization request. Wrong/expired codes fail visibly without losing the
  request or overriding a denial.
- Per-tool scope enforcement at the gateway **and** unchanged local
  fail-closed flags; input injection stays ungrantable in v1.
- Gateway audit log records account id, tool name, outcome — never
  profile content, bindings, or key material (they never reach the
  gateway by design; add a regression test asserting tunneled frames are
  post-sanitization MCP JSON only).
- Rate limits at both layers; 256 KiB message caps end-to-end; session
  and connection caps; tunnel drops release nothing and change nothing
  (host already treats disconnect as its own boundary).
- Gateway holds no phone pairing data, no credentials, no profile state.

## Verification plan

1. `cargo test --workspace` after the seam refactor (existing 6k-line
   server.rs test suite must pass unchanged).
2. New unit tests: gateway OAuth flows (PKCE, rotation, DCR), scope gate
   matrix, offline-manifest caching, rate limits, link-code expiry.
3. New integration test harness: in-process gateway + real WebSocket tunnel
   + real unix control socket against a test `thumble-host`, driving a full
   ChatGPT-like MCP client. It covers pending-link click approval without a
   code, already-online re-authorization, explicit denial, source/target
   binding, fallback-code consent, PKCE exchange, list/call, the complete
   draft workflow, and phone-boundary/error semantics.
4. `python3 scripts/verify-mcp-cli-parity.py` and
   `./scripts/verify-rust-host.sh` stay green; add gateway build to the
   Rust host script.
5. Manual: ChatGPT developer-mode connector end-to-end (OAuth consent,
  tool scan, offline-Mac behavior, revoke, re-auth after token expiry).
6. `./scripts/verify-stack-safety.sh` (should be untouched; run anyway).

## Phased rollout

| Phase | Deliverable | Rough effort |
|---|---|---|
| 0 | Ledger + docs entries (`planned`), workspace scaffolding | small |
| 1 | `HostChannel` seam refactor, relay mode in `thumble-mcp`, reconnect/backoff | medium |
| 2 | Gateway: Streamable HTTP, OAuth 2.1 + DCR, SQLite store, tunnel, scope gates, rate limits | large (core of the project) |
| 3 | Push-approved linking + fallback codes, `thumble relay` CLI, revoke | small–medium |
| 4 | Dockerfile + Fly deploy, healthz, backups, secret handling | small |
| 5 | Integration harness, ChatGPT manual validation, docs finalize, alpha with own accounts; input scope stays off | medium |

Sequencing note: phases 1–3 can be built and tested locally against an
in-process gateway before any real deployment exists.

## Implementation state

The remote connector foundation, deployment, prior link-code OpenAI-hosted
acceptance, click-to-connect production rollout, v16 token-family hotfix, and
OpenAI action-catalog recovery are complete. Native approval, automatic OAuth
return, hosted discovery, and a production `host_status` call are verified;
only a fresh visible ChatGPT conversation remains as the human UI receipt:

| Piece | Where | Evidence |
|---|---|---|
| `HostChannel` seam | `Host/crates/thumble-mcp/src/channel.rs` | unit tests; stdio suite unchanged |
| Tunnel wire protocol | `Host/crates/thumble-tunnel/src/protocol.rs` | round-trip, PKCE, token-shape, connector-approval-frame tests |
| WS ↔ rmcp framing | `Host/crates/thumble-tunnel/src/ws_rpc.rs` | real-WebSocket JSON-RPC round-trip test |
| Relay mode (`--relay`, `--relay-revoke`, `--relay-doctor`) | `Host/crates/thumble-mcp/src/relay.rs`, `main.rs` | native nonblocking approval + fallback link → token persist → manifest → session e2e; in-place rotation + doctor checks; independent application keepalive recovers from silent and protocol-noise-only half-open sockets |
| Gateway OAuth 2.1 + DCR + rotation | `Host/crates/thumble-gateway/src/oauth.rs`, `store.rs` | push allow/deny/wait, fallback-code, atomic code exchange, independent token-family migration/rotation/reuse-isolation tests + e2e; Fly v16 |
| Click-to-connect rollout | `oauth.rs`, `tunnel.rs`, relay `relay.rs` | verified-callback/source/exact-connection allow + terminal deny; durable-token ack; old-control reconnect; fallback transaction and already-online e2e pass; Connect → Allow → automatic return completed; Fly v16 + release relay deployed 2026-08-27 |
| Streamable HTTP proxy + scopes + audit | `proxy.rs`, `scopes.rs`, `http.rs` | e2e scope filtering/denial |
| Tunnel registry + session handoff | `tunnel.rs` | registry unit tests + e2e |
| Deploy artifacts | `Host/crates/thumble-gateway/Dockerfile`, `backup.sh`, `start.sh`, `fly.toml` | live Fly machine, passing health check, TLS/HSTS metadata + 401, encrypted volume + verified backup checksum |
| OpenAI client acceptance | `docs/mcp/openai-client-acceptance.md` | prior link-code workflow completed status/begin/edit/validate/preview/save; post-v16 action refresh made the private plugin callable with 17 tools; direct and normal model-level `host_status` calls succeeded; visible-chat confirmation pending |
| Docs | `docs/rust-host.md`, `docs/mcp/README.md`, this file | — |

Full-stack test: `Host/crates/thumble-gateway/tests/e2e.rs` drives DCR →
pending-link click approval (no code), already-online approval, denial and
fallback-code consent → PKCE exchange → rmcp Streamable HTTP client → gateway
scope gates → device tunnel → real `ThumbleMcp` → unix control socket →
fake host, plus source/target-bound prompt checks and in-place device-token
rotation while the relay is live
(same device identity, old token dead immediately, automatic relay
reconnect with the rotated credential, and a tool call through the new
link), refresh rotation/reuse-revocation, and 401 cases.

Ledger note: the capability ledger maps canonical CLI operations to MCP
tools and is deliberately untouched — the remote connector is a transport
over the same tool surface, not a new operation family. Remote scope rules
are documented in `docs/rust-host.md` and enforced in
`thumble-gateway/src/scopes.rs`.

Deferred (unchanged from the plan): a tunnel-free stateless cloud builder
(blocked on profile/package export+import), the `thumble.input` scope, a
custom-domain alias, and the macOS app pane. The standalone `thumble relay`
CLI surface is implemented; the CLI parity rule applies when an app pane
lands.
