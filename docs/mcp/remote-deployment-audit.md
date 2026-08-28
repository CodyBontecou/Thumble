# Remote MCP implementation completion audit

Audit date: 2026-08-23

## Objective restated as concrete deliverables

Implement and deploy the remote MCP plan end to end while preserving the
local Rust host as configuration authority:

1. Keep the local stdio adapter unchanged by extracting a transport seam.
2. Add a bounded, TLS-only outbound device relay with linking, reconnect,
   session multiplexing, revoke, manifest caching, and local permission gates.
3. Add a hosted Streamable HTTP MCP gateway with OAuth 2.1 authorization code
   + PKCE S256, DCR, refresh rotation/reuse detection, device linking, strict
   redirect validation, bearer auth on every MCP request, and RFC 9728
   discovery/challenges.
4. Enforce tool scopes, local-only tool exclusions, rate/session/frame/body
   limits, token/session/device binding, bounded audit logs, and encrypted
   transport without moving profile authority or raw host responses into the
   cloud.
5. Provide `thumble relay` CLI lifecycle commands, a launchd installer,
   deploy/health/backup artifacts, and operator/user documentation.
6. Prove the path with unit tests, a full-stack local integration test, live
   binary checks, and a production deployment smoke through a real isolated
   host and relay.
7. Perform final acceptance with an authenticated OpenAI-hosted client from
   ChatGPT.app, exercising discovery and the real mutation/save workflow.

## Prompt-to-artifact checklist

| Requirement / plan item | Concrete artifact | Verification evidence | Status |
|---|---|---|---|
| Transport seam; stdio unchanged | `Host/crates/thumble-mcp/src/channel.rs`, `server.rs`, `main.rs` | `UnixHostChannel` tests; original official rmcp client tests remain green | Verified |
| Shared tunnel contract | `Host/crates/thumble-tunnel/src/protocol.rs` | protocol round trips, token/PKCE tests, 256 KiB constant | Verified |
| One JSON-RPC message per WS frame, bounded both ways | `thumble-tunnel/src/ws_rpc.rs`, gateway `http.rs` | real WS round-trip test; inbound/outbound size checks; `/mcp` 413 e2e assertion | Verified |
| TLS outside loopback and trusted session origin | `thumble-mcp/src/relay.rs` | URL/origin unit tests; live `wss://` Fly relay smoke | Verified |
| Click-to-connect approval, fallback link code, persistent 0600 token, reconnect | `thumble-mcp/src/relay.rs`, gateway `oauth.rs`/`tunnel.rs` | pending-link/already-online allow + terminal deny e2e; verified-callback/source/exact-connection tests; persistence acknowledgment + stale-control reconnect tests; Connect → Mac Allow → automatic return completed in production; Fly v16 and release relay production smoke | Deployed; hosted tool call verified, visible-chat confirmation pending |
| Anonymous link and separate active-safe revoke endpoints | gateway `http.rs`, `tunnel.rs`; relay `link_url`/`revoke_url` | gateway e2e active revoke; relay revoke WS test; live deployed revoke ended active relay and removed token | Verified |
| Gateway Streamable HTTP | `Host/crates/thumble-gateway/src/http.rs`, `proxy.rs` | rmcp 3.1.4 legacy and `2026-07-28` clients in `tests/e2e.rs`; raw modern `server/discover`/list/call with ChatGPT Origin; bounded sub-20-KiB remote action catalog; live raw legacy initialize/list/call | Verified |
| OAuth metadata + RFC 9728 | `oauth.rs`, `http.rs` | metadata e2e; live metadata; live 401 `resource_metadata` challenge | Verified |
| RFC 7591 DCR | `oauth.rs` | e2e requires 201 and registered metadata response | Verified |
| PKCE S256, RFC 9207 issuer identification, RFC 8707 resource binding, and opaque server-side consent request | `oauth.rs`, `store.rs` | exact success/error `iss`, resource mismatch, optional-resource compatibility, wrong challenge/verifier, burned code, hidden-field absence, request replay tests | Verified |
| Strict redirect URI validation/no open redirect | `store.rs`, `oauth.rs` | credentials/fragment/localhost.evil/duplicate URI tests | Verified |
| Refresh only with `offline_access`; atomic code exchange and refresh rotation; independent token-family isolation | `oauth.rs`, transactional `store.rs` | sequential + concurrent replay, stale-independent-grant isolation, legacy empty-family migration, failed-issuance rollback, normal/grace family propagation, and revoke-vs-rotation tests | Verified; deployed in v16 |
| Secrets hashed at rest; low-entropy links keyed | `store.rs`, required `THUMBLE_GATEWAY_TOKEN_SECRET` | SHA-256 opaque tokens; HMAC link digest DB test; production secret deployed | Verified |
| Link/OAuth/DCR brute-force and storage bounds | `rate_limit.rs`, store pruning/caps, tunnel pending cap | ten-attempt request, source/global endpoint limit tests, expired-record/client pruning, five-minute link window | Verified |
| Per-tool scopes and remote local-only tools | `scopes.rs`, `proxy.rs` | scope matrix tests; e2e filtered tools, denial, no `press_control` | Verified |
| Independent local `--allow-config-write` gate | relay creates same `ThumbleMcp` with local flags | e2e config save requires both OAuth config scope and local flag | Verified |
| MCP session identity binding | `proxy.rs` | raw HTTP replay with another valid token returns identity mismatch | Verified |
| Tunnel session device binding | `tunnel.rs`, `http.rs` | expected-device unit test and pre-upgrade check | Verified |
| Atomic max-three HTTP and device sessions and cleanup | `SessionLimiter`, `tunnel.rs`, `RelayProxy::drop`, relay `SessionTasks` | cap/release tests; e2e waits for zero; active-session revoke test proves socket termination | Verified |
| Offline manifest scan | `store.rs`, `proxy.rs` | e2e disconnects device, lists cached tools, then proves calls fail fast | Verified |
| Bounded content-free audit | `proxy.rs` | audit format logs only device/tool/outcome; live Fly logs inspected | Verified |
| Full draft workflow and phone boundary | gateway `tests/e2e.rs` | configuration status → begin → rename edit → validate → preview → save; asserts `phoneSyncQueued` | Verified |
| CLI lifecycle parity | `Sources/CLI/ThumbleCLI.swift` | `relay connect/link/rotate/status/revoke`; Xcode CLI build; live `status --json` smoke | Verified |
| launchd lifecycle | `scripts/install-relay-launch-agent.sh` | shell syntax validation; generated plist uses fixed binary and KeepAlive | Verified |
| Container and Fly config | gateway `Dockerfile`, `.dockerignore`, `fly.toml` | remote Docker build and deployment succeeded; image 33 MB | Verified |
| TLS/HSTS/security headers | gateway `http.rs`, Fly `force_https` | unit header test; live curl shows HSTS/no-sniff/no-store | Verified |
| Health check | `/healthz`, `fly.toml` HTTP check | Fly machine: `1 total, 1 passing`; live 200 JSON | Verified |
| Persistent encrypted data | `fly.toml` volume | Fly volume `vol_vly889ol26z0wpo4`, encrypted, attached in `iad` | Verified |
| Daily consistent backups and external snapshots | gateway `backup.sh`, `start.sh`; Fly snapshots | local `.backup` + checksum live smoke; Fly scheduled encrypted volume snapshots, retention 5 | Verified |
| Documentation | `docs/rust-host.md`, `docs/mcp/README.md`, deployment plan | live endpoint and commands documented | Verified |
| Ledger gate remains operation-only | `scripts/verify-mcp-cli-parity.py` | relay explicitly classified transport-only; 141-operation gate green | Verified |
| Rust quality gates | `scripts/verify-rust-host.sh` | final run: fmt, clippy `-D warnings`, 30 gateway unit tests, full gateway e2e, 20 MCP tests, and entire workspace green | Verified |
| Swift stack safety | `scripts/verify-stack-safety.sh` | final run: controller/iOS frame budgets and constrained-thread tests; build succeeded | Verified |
| Production endpoint | `https://thumble-mcp-gateway.fly.dev/mcp` | live OAuth/DCR/TLS/MCP host-status smoke; Fly machine started | Verified |
| OpenAI-hosted client acceptance | `docs/mcp/openai-client-acceptance.md` | ChatGPT.app bundled Codex completed OAuth-backed discovery and status/begin/edit/validate/preview/save against production | Verified |

## Live deployment receipt

- Fly app: `thumble-mcp-gateway` (personal org)
- Machine: `891e16eb0eded8`, process `app`, region `iad`, started
- Image: `deployment-01M0R9XQ1G1GQD46MHQQV3HPWG` (machine version 3)
- Health: one HTTP check, passing
- Volume: `vol_vly889ol26z0wpo4`, 1 GiB, encrypted, scheduled snapshots
- Endpoint: `https://thumble-mcp-gateway.fly.dev/mcp`
- Live smoke against version 2: real isolated `thumble-host` + one-shot
  `thumble relay connect` + long-lived `thumble-mcp --relay`; production OAuth
  issued config/offline access, `/device/status` reported online, raw MCP
  initialized and called `host_status`, then separate revoke stopped the active
  relay and removed its token.
- Production test rows were removed after the smoke; a clean consistent backup
  was created and its SHA-256 checksum verified.

## Click-to-connect production rollout receipt

Rollout date: 2026-08-27

- Fly release: v15, image
  `registry.fly.io/thumble-mcp-gateway:deployment-01M12BHXF3KQVBY550Z8WRZRG2`
- Machine: `891e16eb0eded8`, version 15, `iad`, one passing health check
- Pre-deploy SQLite backup:
  `/data/backups/thumble-gateway-20260827T193410Z.db.gz` (checksum verified)
- Local relay:
  `~/.cargo/bin/thumble-mcp`, SHA-256
  `1394b26b8166067a190b8606bbd92f8b23b51ee78c035972f59545f5e6748a8b`,
  running under `com.codybontecou.thumble.mcp-relay`
- Live probes: `/healthz` returned 200 with HSTS; OAuth metadata advertised DCR
  and PKCE S256; unauthenticated `/mcp` returned the RFC 9728 bearer challenge;
  `/device/status` reported linked, online, and manifest published
- Rollback image retained: v14,
  `registry.fly.io/thumble-mcp-gateway:deployment-01M11WPJZP3ZQS16G1G9AADRB2`

The production software rollout is complete. The ChatGPT desktop
**Connect → Mac Allow → automatic return** flow completed in production, but
tool discovery initially remained empty because OpenAI had not refreshed the
app's action catalog.

### v16 token-family and OpenAI action-catalog recovery

- Fly release: v16, image
  `deployment-01M12CVNDBNJWVJ8VR6YH1SNT9`
- Machine: `891e16eb0eded8`, version 16, `iad`, one passing health check
- Pre-v16 SQLite backup:
  `/data/backups/thumble-gateway-20260827T195842Z.db.gz` (checksum verified)
- Rollback image retained: v14,
  `deployment-01M11WPJZP3ZQS16G1G9AADRB2`
- Patched release relay SHA-256:
  `79d46f87341a83ed602701f96f12d47e00eca1e32216841cbe857ef8454c7d70`
- Gateway logs proved a 20:09 UTC control disconnect left the prior relay on a
  silent half-open socket. The relay now drives liveness from an independent
  application keepalive interval, never decodes WebSocket Ping/Pong payloads
  as control messages, and regression-tests silent, deceptive protocol-noise,
  and healthy reconnect phases.
- v16 gives every independent authorization a random token family, propagates
  it through normal and grace rotations, limits reuse revocation to that
  device/client/family, and exchanges authorization codes atomically.
- Two post-v16 plugin OAuth grants remained active despite the stale
  standalone client's revoked family.
- OpenAI's Thumble connector and link were OAuth `ACTIVE` but had zero actions.
  The ChatGPT Settings `refresh_actions` operation repopulated all 17 remotely
  allowed tools.
- With the redundant standalone Codex MCP registration disabled, the bundled
  `codex-cli 0.150.0-alpha.8` reported the private plugin installed, enabled,
  accessible, and callable; `app/read` and `codex_apps` both exposed all 17
  tools.
- After installing and restarting the patched launchd relay, a real hosted
  `thumble.host_status` invocation succeeded through production and returned
  `running: true` with configuration revision `5`.
- A normal default-configuration `codex exec --json` model turn selected
  `codex_apps` → `thumble.host_status` exactly once and returned the same
  values, proving model-level plugin discovery as well as direct RPC access.

A fresh visible ChatGPT conversation remains the final human confirmation; the
hosted plugin/runtime/tool path itself is now verified end to end.

## Boundaries and unrelated working-tree state

Pre-existing changes in `Sources/Mac/MacContentView.swift` and
`Sources/Shared/GamepadCustomization.swift`, plus pre-existing untracked build
directories, are outside this objective and were neither authored nor reverted
by this implementation.

## Acceptance conclusion

The authenticated OpenAI-hosted receipt covers the prior link-code release:
ChatGPT.app completed production OAuth/MCP status → draft → typed edit →
validation → preview → save, and the authoritative host confirmed revision
`2` plus the renamed profile. See `docs/mcp/openai-client-acceptance.md`.

The click-to-connect refactor and v16 token-family hotfix are deployed.
Production evidence covers native Allow, automatic OAuth return, OpenAI action
refresh, hosted plugin discovery, and a successful `host_status` call through
the Mac relay. The only remaining acceptance item is confirmation from a fresh
visible ChatGPT conversation; this audit does not infer that UI result from the
lower-level hosted invocation.
