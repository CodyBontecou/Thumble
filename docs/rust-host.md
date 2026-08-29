# Thumble Rust host

The Rust host is a standalone macOS receiver for Thumble. It is designed so the transport, pairing, profile, and input state machine can later be reused by Windows and Linux hosts while output injection and service management remain platform adapters.

## Architecture

```text
iPhone
  |  WebSocket control + reliable input
  |  _pocketpad._tcp mDNS discovery
  v
thumble-host
  |- thumble-protocol: wire-compatible messages and codecs
  |- thumble-core: pairing, sessions, profiles, bindings, held-input safety
  |- transport: WebSocket receiver and discovery
  |- control: local CLI IPC and process lifecycle
  `- platform/macos: Accessibility and CGEvent keyboard/pointer output

thumble-mcp (local stdio MCP adapter)
  `- user-only host control socket

thumble-bridge (same-directory constrained Swift helper)
  `- one bounded JSON transform; no state, paths, argv, credentials, or persistence

thumble CLI
  `- exact-sibling thumble-cli-bridge -> live control socket or offline authority lock

Thumble Mac UI
  `- legacy writable backend holds the same authority lock and refuses Rust coexistence
```

The long-running receiver runs in the logged-in user's session. It must not run as root or as a system daemon because macOS Accessibility approval and input delivery belong to the active GUI session. Future Windows and Linux implementations should follow the same per-user-agent model.

The host owns its portable state under `~/Library/Application Support/ThumbleHost`. On first run it imports the existing Thumble Mac server identity, trusted clients, profiles, standalone customization, and keyboard/output bindings without writing back to the legacy defaults domain. Preserving the server ID and trusted tokens allows an already-paired iPhone to Smart Connect to the Rust host. Migration fails closed and leaves the legacy defaults untouched if a stored critical record cannot be decoded; it never installs a fresh identity over a detected but unreadable store. If a pre-rename Rust-host state directory already exists and the canonical directory does not, Thumble continues using that directory to avoid creating a second server identity.

## MVP scope

The macOS MVP includes:

- the existing unencrypted local WebSocket protocol and 8 MiB payload limit;
- `_pocketpad._tcp` Bonjour publication with server identity TXT data;
- six-digit pairing, persisted trusted reconnect tokens, and one active iPhone;
- profile/customization delivery compatible with the current iOS app;
- protocol-v2 input over the reliable WebSocket path;
- keyboard shortcuts, sequences, pointer movement, scrolling, and pointer buttons through CGEvent;
- reference-counted held outputs, visible rapid/overlapping key pulses, and release-on-disconnect/shutdown safety;
- a local CLI for foreground/background lifecycle, status, pairing, and Accessibility setup;
- a local stdio MCP adapter for Claude, OpenAI Codex, and other MCP clients.

Authenticated UDP, virtual gamepad output, skin mutation, launch targets, and Windows/Linux platform backends are intentionally subsequent milestones. The iOS client already falls back to reliable WebSocket input when a pairing response does not advertise a realtime UDP token.

## Developer workflow

From the repository root:

```bash
cargo fmt --manifest-path Host/Cargo.toml --all --check
cargo clippy --locked --manifest-path Host/Cargo.toml --workspace --all-targets -- -D warnings
cargo test --locked --manifest-path Host/Cargo.toml --workspace
cargo install --locked --path Host/crates/thumble-host
cargo install --locked --path Host/crates/thumble-mcp
cargo install --locked --path Host/crates/thumble-cli-bridge
xcodebuild -project Thumble.xcodeproj -scheme ThumbleBridge -configuration Release -sdk macosx CODE_SIGNING_ALLOWED=NO build
```

The installed binary exposes:

```bash
# No arguments also runs the receiver in the foreground.
thumble-host run
thumble-host start
thumble-host stop
thumble-host restart
thumble-host status --json
thumble-host pairing-code
thumble-host pairing-code --rotate
thumble-host accessibility status
thumble-host accessibility prompt
thumble-host accessibility open
thumble-host profiles --json
thumble-host controls --json
thumble-host select-profile <profile-id>
thumble-host press-control <opaque-control-id>
thumble-host release-all
```

Use `run --port 0 --no-bonjour --no-input` for an isolated development receiver. `start` launches the per-user receiver in the background; the other commands use its user-only Unix control socket. Quit Thumble Mac before using the default port so only one process owns port 8765 and advertises the server identity.

## MCP adapter

`thumble-mcp` is a stateless adapter between a local MCP client and the running host's user-only control socket. It never reads `state.json`, owns the receiver lifecycle, accepts shell commands, or exposes authentication tokens and raw key codes. The single deliberate exception is `preview_skin_workspace`: it validates every parameter, then runs the locally installed `thumble` CLI (found via `THUMBLE_MCP_SKIN_CLI` or `PATH`) with a fixed argument vector to render one native controller-view frame of an arbitrary review package into a private temp directory, because the Swift skin engine is the single source of truth for native appearance. It accepts no caller-supplied command text, touches no host state, and is bounded by render size, output size, and a deadline. It uses the official Rust SDK and supports both the legacy MCP `2025-11-25` initialization lifecycle and modern MCP `2026-07-28` per-request discovery metadata; local stdio remains newline-framed.

Start `thumble-host` before the MCP client launches the adapter. The server currently exposes twenty-one tools:

| Tool | Behavior |
|---|---|
| `host_status` | Credential-free health, discovery, profile, and held-output summary |
| `accessibility_status` | Read-only macOS Accessibility state |
| `pairing_code` | Return the six-digit code; rotation requires `rotate: true` |
| `configuration_status` | Authoritative configuration revision and bounded draft capability status |
| `begin_configuration_draft` | Create a private 24-hour draft from an exact configuration revision |
| `get_configuration_draft` | Read bounded draft metadata without raw profiles or bindings |
| `edit_configuration_draft` | Apply one idempotent typed profile, theme, orientation, seven-kind layout repair, control-bar appearance, deterministic six-kind non-file element add/set, or semantic-binding operation |
| `rebase_configuration_draft` | Three-way merge a stale draft onto an exact authoritative revision or return bounded conflict paths |
| `validate_configuration_draft` | Validate an exact private draft revision |
| `preview_configuration_draft` | Render bounded draft geometry, message-free layout-quality diagnostics, and ordered safe layer targets without changing the phone |
| `export_controller_preview` | Return a bounded script-free SVG containing only draft geometry and labels |
| `save_configuration_draft` | Atomically compare-and-swap a draft into authoritative state |
| `discard_configuration_draft` | Delete unsaved work using its exact draft revision |
| `query_catalog` | Bounded built-in controller-template metadata or exact supported device-frame IDs and display geometry |
| `list_profiles` | Curated installed profile IDs and names plus configuration revision |
| `list_controls` | Active-profile opaque control IDs; no key codes |
| `render_controller` | Read-only active-controller geometry plus an interactive SVG MCP App |
| `preview_skin_workspace` | Read-only native controller-view render of an arbitrary `.pocketpad` review package or skin workspace as an inline image; never imports, applies, or changes configuration |
| `select_profile` | Select an exact ID returned by `list_profiles` |
| `press_control` | Automatically released tap of an exact ID returned by `list_controls` |
| `release_all` | Unrestricted emergency release of tracked keyboard/pointer state |

Schema-v1 host state is upgraded atomically to a monotonically revisioned schema-v2 state. Drafts are stored separately as user-only `0600` files beneath a `0700` directory, contain no server identity or trusted-client fields, are limited to eight live drafts, and expire after 24 hours. Beginning, editing, validating, previewing, or discarding a draft never changes the authoritative controller or paired phone. Saves require exact draft/configuration revisions and a durable commit UUID, persist before activating the candidate, release tracked input before executable changes, and queue a complete profile snapshot to a paired phone. Typed edits cover deterministic built-in game generation and template installation, profile rename/select/default/duplicate/delete/move/create/reset, safe scalar customization and color backgrounds, all/suggested or one of seven canonical deterministic layout repairs, catalog-only device selection, orientation preference/copy, typed control-bar collections/resets and safe rendering-effective item appearance patches, complete bounded non-file reusable-style creation/rename/assignment/detach/deletion with sanitized style reads, layer ordering and deterministic group creation/duplication/visibility/locking/catalog-canvas nudging/reordering, theme application, deterministic six-kind non-file element creation, complete safe element layout/appearance/behavior edits, semantic element/part outputs, semantic keyboard bindings, and keyboard/controller/custom output modes and resets. Layout repair accepts only the selected profile variant and one stored, checked-in frame, or bounded 240...1800 canvas; it respects locks unless explicitly included and never persists an override frame. Rich profile operations run through the packaged constrained Swift bridge while Rust continues to own documents, revisions, and commits. Rebase uses lossless three-way merging for disjoint and stable-ID collection changes; overlapping scalar edits, delete-versus-edit, and incompatible reorder changes leave the draft unchanged and return bounded conflict paths. Portable profile export/import is now Rust-authoritative through the bounded hashed artifact v1 codec; full package export and the remaining Swift operation families remain under active development and are tracked by the machine-readable parity contracts in [`docs/mcp`](mcp/README.md).

Configuration save is independently disabled by default at both layers. Enable it only after explicit user approval by starting the host with `--allow-config-write` and the adapter with either `--allow-config-write` or the exact environment value `THUMBLE_MCP_ALLOW_CONFIG_WRITE=1`. Draft creation/editing remains non-authoritative without this opt-in.

The standalone Swift CLI routes deterministic built-in Hollow Knight installation, bounded deterministic generation-spec planning plus artifact import, all 17 built-in template installs (including `profile create --template`), safe scalar/solid-background customization `set`, all/suggested and seven canonical deterministic customization repairs, sanitized style `list`/`show` plus all five non-file style mutations, sanitized variant-scoped element/layer listing plus layer move/forward/backward/front/back reorders, sanitized variant-scoped group listing plus create/rename/duplicate/ungroup/state/nudge/reorder edits, `profile list`, `select`/`use`, `default`/`set-default`, `rename`, `duplicate`/`copy`, `delete`/`rm`, `reset`, `move`/`reorder`, and bounded `export`/`import`; `orientation get`/`show`, `set`, `copy`, and `arrange`; every `binding` command; every `output` command; catalog-backed device `show` and `set`; control-bar collection `list`/`show`, `set`, `add`, `remove`, `move`, and `reset`; and rich non-file control-bar item `show`, `set`, and `reset` through `thumble-cli-bridge`. Its one-line schema-v8 request contains only a high-level typed command, a catalog template enum, booleans and a bounded optional name, typed profile/variant selectors, up to five bounded scalar/color customization edits, semantic key/modifier or gamepad values, a checked-in device-frame ID, canonical control-bar item IDs, bounded safe appearance changes, an optional exact read revision, one invocation UUID, bounded raw generation-spec JSON for read-only planning, and—only for profile import—bounded raw artifact JSON. Responses contain only a revision-tagged profile catalog, a bounded portable profile artifact for explicit export, a bounded read-only generation plan containing generated/artifact JSON and typed warnings/layout quality, orientation summary, bounded sanitized style definitions, layer records, and variant-scoped group records, bounded semantic binding/output projection, checked-in device-frame selection, bounded ordered control-bar collection projection, sanitized rendering-effective control-bar item appearance, deterministic draft/commit outcome IDs, or coded resume metadata. Legacy profiles that predate keyed binding maps use the independently reconstructed fixed standalone-CLI fallback until their first transaction materializes exact maps. Responses never contain raw key codes, modifier masks, unvalidated profile documents, paths, credentials, arbitrary device IDs, or raw control-bar appearance payloads; the only profile document response is the validated 8 MiB-bounded artifact v1 export. Legacy custom canvases are projected only as bounded typed dimensions and orientation; writes remain limited to the checked-in catalog. The helper relays one typed transaction to a reachable same-user host. If no host owns `runtime.lock`, it acquires that exact lock, loads or migrates state through Rust, runs the same begin/edit/validate/compare-and-swap preparation, atomically persists, and releases the lock. A held lock with an unreachable socket fails closed. Live hosts without configuration-write permission reject profile/template/generation/customization/orientation/binding/output/device/control-bar mutations with `configuration_write_disabled`; their bounded reads remain available, and the helper never substitutes an offline authority. Deterministic UUIDv5 IDs and a persisted request digest make same-invocation retries idempotent and conflicting reuse fail closed. Every migrated write uses one draft and one save. Rust independently reconstructs exact semantic binding/output maps, modes, active mirrors, synchronized element outputs, control-bar membership/order, orientation mirrors, and sparse default-frame behavior before accepting a Swift sibling delta. Orientation copy accepts an explicit saved source or the matching primary layout, copies source unknown fields, mirrors the destination into the primary layout, and is independently checked in Rust for exact frame, guide, visible-control rotation, and portrait control-bar collision behavior. Control-bar item writes preserve the standalone partial-edit semantics through the existing independently reconstructed `ControlBarItemChanges` operation; image fills and asset icons remain artifact-gated. Template and built-in generation installs derive destination/profile/element UUIDs inside Rust, use exact catalog revisions, and replay by invocation UUID. Safe customization writes independently reconstruct scalar, checked-in-frame, and solid-color deltas; rich fills and custom-size frames fail closed. Spec-based generation is Rust-planned and installs through the existing artifact-import CAS path; its hosted-builder tool is locally implemented at `partial` status and remains unavailable pending deployment/acceptance. Non-template profile creation, customization reads/resets and issue-code-specific repair aliases, theme and element writes, style import/export, app attachment, and skin/package families remain explicitly unmigrated, and legacy writes are rejected once Rust authority artifacts exist.

Input is disabled by default. Enable `press_control` only after explicit user approval with either `--allow-input` or the exact environment value `THUMBLE_MCP_ALLOW_INPUT=1`. The adapter and host enforce independent rate limits; the host also requires input mode and Accessibility permission. `release_all` remains callable when input is disabled or rate-limited.

`render_controller` attaches `ui://thumble/controller-builder-v1.html` through the standard `_meta.ui.resourceUri` field and serves it through `resources/read` as `text/html;profile=mcp-app`. The HTML is embedded in the Rust binary, performs the MCP Apps `2026-01-26` iframe handshake, and has no network, storage, input-injection, or mutation interface. Its structured result contains only bounded profile identity, orientation, color-scheme/accent/label preferences, sanitized canvas fills, element IDs/labels/kinds/shapes, canonical ordered control-bar item/target IDs and sanitized effective appearance, safe editable layout/appearance/behavior fields, allowlisted semantic outputs, resolved frames, ordered safe layer target/stable IDs, bounded group membership, and message-free layout-quality codes/severity/safe IDs/finite metrics/counts/canonical suggestions. The MCP App and draft editor resolve normal-state native fills, scheme variants, reusable/inline styles, foreground contrast, strokes, corners, shadows, joystick knobs, label visibility, and native polygon/star geometry from that snapshot instead of applying a fixed web palette. Unsupported raw keys/modifiers and asset/image/path-bearing content are omitted and explicitly flagged; launch targets, arbitrary profile fields, free-form diagnostic messages, and credentials never enter the snapshot. Artwork and image-backed fills remain omitted and are identified as such in the preview because local iPhone skin assets are not available to the MCP iframe. Layout diagnostics are pruned before editor targets to preserve the 48 KiB cap. Clients without MCP Apps support still receive structured JSON and a textual fallback.

`preview_configuration_draft` attaches the separate `ui://thumble/controller-editor-v1.html` MCP App. It supports selecting and dragging controls, bounded label/center edits, explicit validation, explicit three-way rebase, explicit save, and discard. Every UI mutation calls the same typed MCP tools with an expected draft revision and fresh operation UUID; drag commits occur at pointer-up rather than every pointer event. Save is never triggered by teardown. The iframe contains no network requests, storage, raw profile JSON, raw key codes, filesystem access, or input-injection calls.

Canonical host overrides are `THUMBLE_HOST_STATE_DIR` and `THUMBLE_HOST_CONTROL_SOCKET`. Pre-rename environment names remain accepted as lower-priority migration aliases; if a canonical variable is present, it always wins.

A packaged local build can be registered with Claude Desktop in `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "thumble": {
      "command": "/Applications/Thumble Host.app/Contents/MacOS/thumble-mcp",
      "args": []
    }
  }
}
```

For an explicitly input-enabled configuration, use `"args": ["--allow-input"]`. OpenAI Codex can use the same stdio binary from its MCP configuration:

```toml
[mcp_servers.thumble]
command = "/Applications/Thumble Host.app/Contents/MacOS/thumble-mcp"
args = []
```

Codex desktop currently gates third-party MCP Apps UI behind an experimental feature. Add the setting to the existing `[features]` table in `~/.codex/config.toml`, then fully restart Codex:

```toml
[features]
enable_mcp_apps = true
```

The tool remains useful as structured/text output if that experimental renderer is unavailable. Use an absolute binary path because GUI clients often have a restricted `PATH`. The stdio adapter is local only: never expose the stdio process or the host control socket over the network. Remote connector deployments use the authenticated relay below instead.

## Remote MCP connector relay (ChatGPT)

Remote platforms such as ChatGPT's developer-mode connectors speak MCP over
Streamable HTTP with OAuth 2.1 (PKCE S256, RFC 8414 metadata, RFC 7591 dynamic
client registration, RFC 9207 authorization-response issuer identification,
RFC 8707 MCP resource binding, and refresh-token rotation). The `thumble-gateway` crate is
a hosted, authenticated router for that surface. It is a pure relay:

```
ChatGPT ─HTTPS (Streamable HTTP, OAuth 2.1)→ thumble-gateway (cloud)
                                              │ scope gate + rate + audit
                                              │ WebSocket (outbound from Mac)
                 thumble-mcp --relay ←─────────┘
                   (serves the same ThumbleMcp tool surface)
                       │ unix control socket (unchanged, user-only)
                    thumble-host ── profile sync ──→ iPhone
```

- The gateway never receives host `ControlResponse` payloads directly; it
  forwards already-sanitized MCP JSON and enforces per-tool scopes before
  forwarding. It holds no profiles, bindings, pairing data, or credentials,
  and never becomes a configuration authority.
- The Mac keeps serving the ordinary twenty-one-tool `ThumbleMcp` handler over
  per-session tunnels; drafts, revisions, commits, the Swift bridge, and
  phone delivery remain entirely local.
- `pairing_code`, `press_control`, and `release_all` are never reachable
  remotely. Input injection is not grantable in v1 at any scope.
- Scopes: `thumble.read`, `thumble.draft`, `thumble.config`, plus OAuth's
  `offline_access` for refresh tokens. The RFC 9728 challenge requests all
  four on initial ChatGPT authorization so the connector can build and save;
  the consent page lists them explicitly. `thumble.draft` implies read;
  `thumble.config` implies draft and read.
  Configuration writes still require the device-side `--allow-config-write`
  opt-in — the gateway scope is the outer gate, the local flags remain the
  fail-closed inner gate.
- Linking is push-approved. When ChatGPT opens `/authorize`, the gateway
  sends `ConnectorApprovalRequest` over an open link socket, or over the
  already-authenticated control tunnel for later re-authorization. The relay
  shows a native macOS dialog; clicking **Allow** sends a target-bound,
  single-use decision, and `/authorize/wait` returns the OAuth callback
  automatically — no code entry. Push is restricted to verified ChatGPT
  callback hosts and pending/online relays whose gateway-observed source
  matches the browser authorization; each exact connection may have only one
  active prompt, and the dialog defaults to Deny. The dialog stays off with
  `THUMBLE_RELAY_NO_PROMPT=1` (SSH/headless use). OAuth success is withheld
  until the relay acknowledges atomic token persistence; an explicit token
  rotation also closes the previous authenticated control socket. A one-time six-digit code
  is still printed and copied to the clipboard as the fallback; its consent
  form retains the existing retry/error behavior. The completion page names
  the linked device (hostname by default, `--device-name` to override).
  `thumble relay rotate` still rotates an already-linked credential **in
  place** — same device identity and OAuth bindings, with no window where
  both tokens are valid.
- High-entropy tokens are opaque and stored as SHA-256 digests; six-digit
  link codes use HMAC-SHA256 with `THUMBLE_GATEWAY_TOKEN_SECRET`. OAuth
  request fields live server-side behind an opaque request ID rather than
  unsigned hidden fields. Refresh tokens require `offline_access`, rotate
  with reuse detection plus a bounded 60-second concurrent-refresh grace
  window (multi-window desktop clients share one token cache; replays
  outside the window or past the successor budget revoke the whole device
  family), and revoke the entire family on confirmed replay. Link
  codes live one hour, are single-use, and have per-request, per-source,
  and global attempt/connection limits.
- When the Mac is offline, connector tool scanning still works from the
  cached manifest; tool calls fail fast with an actionable error.

Run the device side (start `thumble-host` first):

```bash
# One managed foreground flow: links on first run, then serves MCP.
thumble relay connect --allow-config-write

# Check gateway liveness and MCP manifest readiness.
thumble relay status --json

# Diagnose every onboarding prerequisite with concrete fixes.
thumble relay doctor

# Explicitly rotate an existing device link in place; the running relay
# reconnects with the new credential automatically.
thumble relay rotate

# Install (or update) the background launch agent; uninstall removes it.
thumble relay install --allow-config-write
thumble relay uninstall

# Revoke the current device link.
thumble relay revoke

# Equivalent low-level long-lived binary.
thumble-mcp --relay wss://thumble-mcp-gateway.fly.dev/tunnel --allow-config-write
```

`thumble relay connect` is the supported onboarding path. With no token it
opens a link window and prints a fallback URL/code; the user clicks
**Connect** in ChatGPT and **Allow** in the native Mac prompt. The relay
persists the granted token atomically, publishes the MCP manifest, and keeps
serving the tunnel. On macOS the fallback code is copied to the clipboard,
but no extra browser tab is opened. With an existing token, the background
control tunnel can approve a later ChatGPT connection without token rotation. The legacy `thumble relay link` command remains a one-shot
link-only primitive for scripts; it does not start the tunnel. `thumble
relay rotate` authenticates the link socket with the current token so the
gateway replaces the same device's credential atomically; a running relay
detects the canonical `0600` token replacement and reconnects
automatically. `relay status` reports both gateway liveness and whether
the MCP manifest has been published. `relay doctor` merges local checks
(host, bridge, token hygiene, relay singleton lock, launch agent) with
gateway-side status and exits non-zero with fix instructions when
anything is not ready. A launchd `KeepAlive` job running the foreground
`--relay` command is the recommended lifecycle on macOS: install it with
`thumble relay install [--allow-config-write] [--binary PATH]` and remove
it with `thumble relay uninstall`. From a source checkout,
`./scripts/install-relay-launch-agent.sh [--allow-config-write]` is an
equivalent installer; packaged builds include the same installer at
`/Applications/Thumble Host.app/Contents/Resources/install-relay-launch-agent.sh`.
A macOS app pane (if added later) must drive these same relay commands per
the CLI-parity rule.

Run the hosted side (Dockerfile and `fly.toml` at the repository root;
secrets via `fly secrets set`):

```bash
THUMBLE_GATEWAY_BASE_URL=https://thumble-mcp-gateway.fly.dev \
THUMBLE_GATEWAY_TOKEN_SECRET='at-least-32-random-characters' \
THUMBLE_GATEWAY_BIND=0.0.0.0:8080 \
THUMBLE_GATEWAY_DB=/data/thumble-gateway.db \
thumble-gateway
```

Endpoints: `/mcp` (bearer-authenticated Streamable HTTP),
`/.well-known/oauth-protected-resource`, `/.well-known/oauth-authorization-server`,
`/register` (DCR), `/authorize` + `/authorize/wait` (push approval) plus
`/authorize/code` + `/authorize/confirm` (stable fallback-code consent),
`/token` (PKCE + refresh
rotation), `/link`, bearer-authenticated
`/device/status`, `/tunnel`, `/tunnel/link`, `/tunnel/revoke`, and
`/tunnel/session/{id}` (device WebSockets), `/healthz`.
TLS terminates at the Fly edge; the app also emits HSTS, CSP, no-store,
no-referrer, and no-sniff headers. Register the live connector URL
`https://thumble-mcp-gateway.fly.dev/mcp` in ChatGPT developer mode. The MCP
server advertises the distinct **Thumble MCP Controller** title, connector-only
description, website, and version-pinned 1024×1024 PNG through `serverInfo`.
ChatGPT owns the draft app's listing artwork separately: while the app remains
a developer-mode draft, use **Apps → Thumble MCP Controller → Manage**, upload
`Website/assets/app-icon.png` as its logo, and refresh the app to pull current
MCP metadata. ChatGPT does not render MCP Apps UI; remote sessions rely on the
structured/JSON and SVG textual outputs the tools already return.

End-to-end design and threat model: `docs/mcp/remote-deployment-plan.md`.
The gateway's own tests include a full-stack OAuth + Streamable HTTP +
tunnel + real `ThumbleMcp` session against a bound host control socket
(`Host/crates/thumble-gateway/tests/e2e.rs`). They exercise both legacy
initialize/list/call and current `2026-07-28` stateless `server/discover`,
`tools/list`, and `tools/call` flows, including the exact ChatGPT origin. The production deployment is
`thumble-mcp-gateway` in Fly region `iad`, with one passing `/healthz`
check, an encrypted 1 GiB volume, Fly scheduled volume snapshots, and daily
consistent SQLite `.backup` archives/checksums under `/data/backups`. When
backups are enabled and the database already exists, `start.sh` requires one
synchronous `.backup` + checksum to succeed before the gateway binary can run
its startup migration; periodic backup waits a full interval afterward so it
does not duplicate that immediate archive. A newly created database instead
gets its first backup after gateway initialization. The local existing/new/
failure harness is `scripts/test-gateway-start.sh`; the isolated restore
rehearsal (including explicit HMAC-secret preservation) is documented in
`docs/mcp/phase4-local-acceptance.md`.
Optional `THUMBLE_GATEWAY_BACKUP_UPLOAD_URL` (with `{filename}` placeholder)
and `THUMBLE_GATEWAY_BACKUP_TOKEN` upload each archive off-platform.

## Hosted builder (local integration; production pending)

The tunnel-free hosted builder is a second connector mode, not a replacement
for the relay and not a synchronized phone authority. Its sessions own only
bounded **pre-adoption workspace state**, run migrated `thumble-core`
operations server-side, and emit portable artifacts. Explicit import into
`thumble-host` is the adoption boundary; an iPhone may hold an artifact for
practice-mode preview but never becomes configuration authority.

Phases 0–3 are implemented: the independent hosted-builder capability contract
exists; portable profile artifact v1 has a Rust-authoritative codec plus CLI
export/import through deterministic draft/CAS transactions; generation spec v1
has deterministic Rust planning plus CLI artifact-import installation; and the
pure `thumble-builder` session state machine now supplies replay-safe edits,
generation, all-template fixtures, preview/validation, and deterministic
emission. The hosted gateway session runtime, builder-principal OAuth, isolated nine-tool
MCP endpoint, principal-scoped persistence, and fragment-token share delivery
are locally implemented and verified. Their contracts remain `partial` and
unavailable pending explicit production deployment approval and visible
ChatGPT acceptance. The local surface is `/builder/mcp`, builder protected-resource
metadata at `/.well-known/oauth-protected-resource/builder/mcp`, resource-bound
consent through `/authorize` + `/authorize/builder/confirm`, and
`/share/{artifactID}` requiring `Authorization: ThumbleShare <token>` (the URL
fragment carries the token to the iOS importer without sending it in
ordinary navigation).

iPhone pickup and desktop adoption are locally implemented and remain
`partial`/unavailable pending production and physical-device receipts. The
iPhone parses share links strictly, downloads through a header-authorized,
redirect-free, size-bounded fetcher, validates the portable codec (RFC 8785
semantic hash), quarantines artifacts in a bounded expiring store, renders
practice-mode-only previews, and uploads to the paired Mac through the
explicit `profile_artifact_adoption_v1` protocol (chunked, hash-verified,
append-as-copies, idempotent with authoritative-snapshot confirmation; see
`docs/mcp/phase5-adoption-local-acceptance.md`). On the desktop, the Mac app
offers "Import Shared Keypad…" accepting the share link or a saved `.json`
file through the same authority import as `thumble profile import`; the
shared bounded fetcher and parser live in `Sources/Shared` so Mac, iPhone,
and tests consume one implementation. Production gateway deployment,
universal-link acceptance on a physical iPhone, and the visible ChatGPT
prompt-to-artifact alpha remain pending. See
`docs/mcp/hosted-builder-plan.md`,
`docs/mcp/hosted-builder-capabilities-v1.json`, and
`docs/mcp/profile-artifact-v1.md`, `docs/mcp/generation-spec-v1.md`, and
`docs/mcp/builder-session-v1.md`.

## Security and permissions

The current iOS-compatible transport is unencrypted `ws://` on the local network. Pairing and trusted reconnect authentication prevent unauthenticated input, but the host should only run on networks you trust. Auth tokens are stored in the host state file with per-user permissions and are never included in status output or logs.

Keyboard and pointer injection requires macOS Accessibility approval for the installed, signed host. Check or request it with the `accessibility` commands above. A stable bundle identifier, signing identity, and install path are important because macOS associates approval with code identity. The release script emits an ad-hoc-signed local development bundle by default; pass a Developer ID identity and notary profile for a distributable build with stable Accessibility identity.

The control socket accepts only same-user peers, limits connections and frame sizes, serializes side effects, and lives in a user-owned `0700` directory with a `0600` socket. A custom `THUMBLE_HOST_CONTROL_SOCKET` parent that is symlinked, owned by another user, or group/world accessible is rejected rather than silently weakened.

## Compatibility rules

Thumble is the product and source/API brand. The old name remains only inside stable compatibility identifiers: existing App Store bundle IDs, defaults and notification keys, `_pocketpad._tcp`, the `pocketpad-pair` payload type, `.pocketpad` skin archives and schemas, legacy environment aliases, and previously created state paths. Changing those values in place would break installed apps, pairing, saved profiles, automation, or published packages.

`Sources/Shared/ControllerProtocol.swift`, `Sources/iOS/ControllerClient.swift`, and `Sources/Mac/MacControllerServer.swift` remain the compatibility reference until the protocol fixtures are authoritative across both languages.

- Keep Swift Codable field names and enum raw values unchanged.
- Treat profile/customization objects as lossless JSON until portable typed models exist.
- Never log pairing or realtime tokens.
- Do not advertise a capability until the host implements its full mutation semantics.
- Release every held key and pointer button on disconnect, replacement, timeout, generation transition, stop, or process termination.
- Keep the core free of AppKit/CoreGraphics dependencies. Platform code implements output and permission traits.

Before merging shared-model or startup changes, continue running `./scripts/verify-stack-safety.sh`; the Rust host does not replace the Swift stack-safety gate.
