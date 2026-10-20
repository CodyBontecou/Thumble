# Thumble Rust host

The Rust host is a standalone macOS receiver for Thumble. Its transport, pairing, profile, and input state machine are shared with the Windows/Linux receiver, while output injection and service management remain platform adapters.

For native Windows/Linux keyboard and mouse control, use the separate [`thumble-receiver`](cross-platform-receiver.md) binary. It shares this host's protocol/core and has its own platform input and per-user CLI adapters.

Hosted shared-build pickup, preview and phone adoption are retired on Android and iOS. Both apps provide read-only local recovery exports. Receivers no longer advertise or accept adoption uploads; ordinary local CLI/profile import and paired profile synchronization remain. See [feature-removal-progress.md](feature-removal-progress.md).

## Architecture

```text
iOS / Android
  |  WebSocket control + reliable input
  |  _pocketpad._tcp mDNS discovery
  v
thumble-host
  |- thumble-protocol: wire-compatible messages and codecs
  |- thumble-core: pairing, sessions, profiles, bindings, held-input safety
  |- transport: WebSocket receiver and discovery
  |- control: local CLI IPC and process lifecycle
  `- platform/macos: CGEvent keyboard/pointer + receiver-owned virtual HID output

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

The host owns its portable state under `~/Library/Application Support/ThumbleHost`. On first run it may import the existing Thumble Mac server identity, trusted clients, and current UUID-based profiles/bindings without writing back to the defaults domain. Preserving the server ID and trusted tokens allows an already-paired current client to reconnect. Obsolete named-input configurations and binding storage are rejected without migration, aliases, or recovery. An unreadable critical record leaves the source untouched; the host never installs a fresh identity over a detected but unreadable store. If a pre-rename Rust-host state directory already exists and the canonical directory does not, Thumble continues using that directory to avoid creating a second server identity.

## MVP scope

The macOS MVP includes:

- the existing unencrypted local WebSocket protocol and 8 MiB payload limit;
- `_pocketpad._tcp` Bonjour publication with server identity TXT data;
- six-digit pairing, persisted trusted reconnect tokens, and one active iPhone;
- profile/customization delivery compatible with the current iOS and Android apps;
- authenticated profile orientation preference mutation with advertised capability, durable acknowledgement and input neutralization;
- protocol-v3 UUID/part input over authenticated UDP with reliable WebSocket mirroring/fallback; old slot-index input frames reject;
- keyboard shortcuts, sequences, pointer movement, scrolling, and pointer buttons through CGEvent;
- optional virtual gamepad buttons/D-pad/two sticks/independent triggers, with recording, honest HID readiness and managed signing gates;
- reference-counted held outputs, visible rapid/overlapping key pulses, and release-on-disconnect/shutdown safety;
- a local CLI for foreground/background lifecycle, status, pairing, and Accessibility setup;
- a local stdio MCP adapter for Claude, OpenAI Codex, and other MCP clients.

Authenticated protocol-v3 UDP input is available on the same port as WebSocket. Pairing over WebSocket issues an ephemeral realtime token; a UDP hello binds that token to a datagram endpoint for the active connection. Disconnect, replacement, suspension, and shutdown retire UDP authentication. Both transports share generation checks and a bounded per-press sequence history, so reordered independent touches and reliable mirrored releases work without duplicate output. `thumble-host status --json` exposes token-free transport counters under `realtime`; if UDP cannot bind, the host omits the token and keeps WebSocket input available. Skin mutation and application attachment editing remain subsequent milestones for this Mac host. Attached-application launch is implemented in the Mac runtime (see application launching below). Windows/Linux keyboard and mouse adapters are provided by the separate `thumble-receiver`; virtual gamepad output there remains unsupported. Virtual HID is implemented but signed-device and GameController/SDL/Steam/game compatibility remain unverified; see [controller acceptance gates](virtual-controller-support.md). The iOS client already falls back to reliable WebSocket input when a pairing response does not advertise a realtime UDP token.

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
thumble-host gamepad status --json
thumble-host gamepad doctor
thumble-host gamepad retry
thumble-host gamepad test <opaque-control-id> tap
thumble-host gamepad test <opaque-control-id> down
thumble-host gamepad test <opaque-control-id> up
thumble-host release-all
```

`gamepad` commands are IPC clients, never separate HID creators. Holds expire after 30 seconds; retry neutralizes captured input first. HID-ready means initial neutral submission succeeded, not consumer recognition. A loose `cargo install` receiver does not supply a restricted-entitlement profile: live virtual HID requires the properly signed app-like receiver bundle described in the [acceptance guide](virtual-controller-support.md). CLI/MCP/helpers must not claim the managed HID entitlement.

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
| `preview_skin_workspace` | Read-only native controller-view render of an arbitrary `.pocketpad` review package or skin workspace as an inline image; optional `actionSet` selects base/left-trigger/right-trigger/both-triggers; never imports, applies, or changes configuration |
| `select_profile` | Select an exact ID returned by `list_profiles` |
| `press_control` | Automatically released tap of an exact ID returned by `list_controls` |
| `release_all` | Unrestricted emergency release of tracked keyboard/pointer/controller state |

Host state uses schema 3 with monotonic configuration revisions. Schemas 1/2 and obsolete named-slot bindings are rejected without rewriting or migrating them. Drafts are stored separately as user-only `0600` files beneath a `0700` directory, contain no server identity or trusted-client fields, are limited to eight live drafts, and expire after 24 hours. Beginning, editing, validating, previewing, or discarding a draft never changes the authoritative controller or paired phone. Saves require exact draft/configuration revisions and a durable commit UUID, persist before activating the candidate, release tracked input before executable changes, and queue a complete profile snapshot to a paired phone. Typed edits cover deterministic built-in game generation and template installation, profile rename/select/default/duplicate/delete/move/create/reset, safe scalar customization and color backgrounds, all/suggested or one of seven canonical deterministic layout repairs, catalog-only device selection, orientation preference/copy, typed control-bar collections/resets and safe rendering-effective item appearance patches, complete bounded non-file reusable-style creation/rename/assignment/detach/deletion with sanitized style reads, layer ordering and deterministic group creation/duplication/visibility/locking/catalog-canvas nudging/reordering, theme application, deterministic six-kind non-file element creation, complete safe element layout/appearance/behavior edits, semantic element/part outputs, semantic keyboard bindings, and keyboard/controller/custom output modes and resets. Layout repair accepts only the selected profile variant and one stored, checked-in frame, or bounded 240...1800 canvas; it respects locks unless explicitly included and never persists an override frame. Rich profile operations run through the packaged constrained Swift bridge while Rust continues to own documents, revisions, and commits. Rebase uses lossless three-way merging for disjoint and stable-ID collection changes; overlapping scalar edits, delete-versus-edit, and incompatible reorder changes leave the draft unchanged and return bounded conflict paths. Portable profile export/import is now Rust-authoritative through the bounded hashed artifact v1 codec; full package export and the remaining Swift operation families remain under active development and are tracked by the machine-readable parity contracts in [`docs/mcp`](mcp/README.md).

Configuration save is independently disabled by default at both layers. Enable it only after explicit user approval by starting the host with `--allow-config-write` and the adapter with either `--allow-config-write` or the exact environment value `THUMBLE_MCP_ALLOW_CONFIG_WRITE=1`. Draft creation/editing remains non-authoritative without this opt-in.

The standalone Swift CLI routes deterministic built-in Hollow Knight installation, bounded deterministic generation-spec planning plus artifact import, all 17 built-in template installs (including `profile create --template`), safe scalar/solid-background customization `set`, all/suggested and seven canonical deterministic customization repairs, sanitized style `list`/`show` plus all five non-file style mutations, sanitized variant-scoped element/layer listing plus layer move/forward/backward/front/back reorders, sanitized variant-scoped group listing plus create/rename/duplicate/ungroup/state/nudge/reorder edits, `profile list`, `select`/`use`, `default`/`set-default`, `rename`, `duplicate`/`copy`, `delete`/`rm`, `reset`, `move`/`reorder`, and bounded `export`/`import`; `orientation get`/`show`, `set`, `copy`, and `arrange`; every `binding` command; every `output` command; catalog-backed device `show` and `set`; control-bar collection `list`/`show`, `set`, `add`, `remove`, `move`, and `reset`; and rich non-file control-bar item `show`, `set`, and `reset` through `thumble-cli-bridge`. Its one-line schema-v8 request contains only a high-level typed command, a catalog template enum, booleans and a bounded optional name, typed profile/variant selectors, up to five bounded scalar/color customization edits, semantic key/modifier or gamepad values, a checked-in device-frame ID, canonical control-bar item IDs, bounded safe appearance changes, an optional exact read revision, one invocation UUID, bounded raw generation-spec JSON for read-only planning, and—only for profile import—bounded raw artifact JSON. Responses contain only a revision-tagged profile catalog, a bounded portable profile artifact for explicit export, a bounded read-only generation plan containing generated/artifact JSON and typed warnings/layout quality, orientation summary, bounded sanitized style definitions, layer records, and variant-scoped group records, bounded semantic binding/output projection, checked-in device-frame selection, bounded ordered control-bar collection projection, sanitized rendering-effective control-bar item appearance, deterministic draft/commit outcome IDs, or coded resume metadata. Missing maps derive only from that profile's declared controls and owned outputs; explicit empty outputs remain clears. No fixed input-slot map or previous-profile fallback is used. Responses never contain raw key codes, modifier masks, unvalidated profile documents, paths, credentials, arbitrary device IDs, or raw control-bar appearance payloads; the only profile document response is the validated 8 MiB-bounded artifact v1 export. Legacy custom canvases are projected only as bounded typed dimensions and orientation; writes remain limited to the checked-in catalog. The helper relays one typed transaction to a reachable same-user host. If no host owns `runtime.lock`, it acquires that exact lock, validates current state through Rust, runs the same begin/edit/validate/compare-and-swap preparation, atomically persists, and releases the lock. A held lock with an unreachable socket fails closed. Live hosts without configuration-write permission reject profile/template/generation/customization/orientation/binding/output/device/control-bar mutations with `configuration_write_disabled`; their bounded reads remain available, and the helper never substitutes an offline authority. Deterministic UUIDv5 IDs and a persisted request digest make same-invocation retries idempotent and conflicting reuse fail closed. Every migrated write uses one draft and one save. Rust independently reconstructs exact semantic binding/output maps, modes, active mirrors, synchronized element outputs, control-bar membership/order, orientation mirrors, and sparse default-frame behavior before accepting a Swift sibling delta. Orientation copy accepts an explicit saved source or the matching primary layout, copies source unknown fields, mirrors the destination into the primary layout, and is independently checked in Rust for exact frame, guide, visible-control rotation, and portrait control-bar collision behavior. Control-bar item writes preserve the standalone partial-edit semantics through the existing independently reconstructed `ControlBarItemChanges` operation; image fills and asset icons remain artifact-gated. Template and built-in generation installs derive destination/profile/element UUIDs inside Rust, use exact catalog revisions, and replay by invocation UUID. Safe customization writes independently reconstruct scalar, checked-in-frame, and solid-color deltas; rich fills and custom-size frames fail closed. Spec-based generation is Rust-planned and installs through the existing artifact-import CAS path; hosted generation endpoints are retired. Runtime skin library list/import/export/apply/detach/remove commands route through the live Rust owner, as described under Runtime skin library and phone synchronization below. Non-template profile creation, customization reads/resets and issue-code-specific repair aliases, theme and element writes, style import/export, and app attachment remain explicitly unmigrated, and legacy writes are rejected once Rust authority artifacts exist.

### Native editor authority

When the native Mac editor holds `runtime.lock`, `thumble-cli-bridge` routes to its secured same-user configuration endpoint before attempting Rust-host or offline routing. The editor supplies a complete validated, credential-free snapshot. Rust evaluates typed commands in a disposable private directory, then submits writes using the editor instance ID, configuration revision, and content hash for compare-and-swap. CLI operations implemented only in Swift likewise load a native snapshot and commit through that endpoint, rather than directly overwriting the running editor’s preferences. Applicable Rust-authority unmigrated-operation guards remain in place; this branch does not permit a native editor to run alongside a Rust authority.

Changed, insecure, or unreachable native authority fails closed; it cannot authorize a competing canonical Rust store. The editor validates/encodes and persists the complete configuration before releasing inputs or installing it. Failed persistence rejects the commit. Preferences restoration after a failed synchronization is best effort, not a guarantee against physical filesystem failures.

Native acknowledged-request replay is limited to the current editor instance and its bounded in-memory cache (16 records, at most 256 KiB per replay response). Eviction or restart provides no durable exactly-once guarantee; do not confuse this with Rust’s persisted transaction replay. Cached replay still requires current-state, candidate, instance, and request-content validation. Input messages carry UUID/part identities, not orientation; layout copy/selection descriptions above do not establish orientation-specific execution.

Input is disabled by default. Enable `press_control` only after explicit user approval with either `--allow-input` or the exact environment value `THUMBLE_MCP_ALLOW_INPUT=1`. The adapter and host enforce independent rate limits; the host also requires input mode, Accessibility for keyboard-bearing controls, and HID readiness for controller output. `host_status.output.virtualGamepadStatus` distinguishes recording/unavailable/HID-ready without certifying games. MCP supports controller-only installed taps, but recovery and held down/up tests remain local CLI-only as recorded in the capability ledger. `release_all` remains callable when input is disabled or rate-limited.

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

The tool remains useful as structured/text output if that experimental renderer is unavailable. Use an absolute binary path because GUI clients often have a restricted `PATH`. The stdio adapter is local only: never expose the stdio process or the host control socket over the network. Hosted connector deployments are retired.

## Retired hosted connections

The hosted gateway, cloud builder, remote relay, OAuth flows, and relay installer are removed from the build. Local stdio MCP and CLI design/generation tools remain. `thumble relay uninstall` is a cleanup-only compatibility command for an old local background relay; no command creates or connects a new relay. Service data and live deployment retirement require the inventory in [hosted service retirement](hosted-service-retirement.md).

## Retired shared-build uploads

The Mac and Rust receivers no longer advertise `profile_artifact_adoption_v1`, assemble uploads, invoke native validation for adoption, or import uploaded artifacts. Paired legacy requests receive a fixed retirement error. Legacy socket adoption/status/cancel requests return `hosted_builds_retired` without consulting the old ledger or decoding artifact bytes. The Rust host CLI hides its compatibility-only `shared-build` entry and immediately rejects all arguments; the public `thumble` CLI likewise reports retirement. Use `thumble profile import file.json` or the Mac's Import Setup file picker.

Previously adopted local profiles remain ordinary profiles. Old receipt data is preserved: Rust continues to decode/store its bounded legacy field, while the Mac leaves the obsolete defaults entry untouched and no longer loads, prunes or writes it. Phones export valid original pending profile bytes or raw recovery archives without consuming source files. This does not recover gateway-only builds; deployed-service backup and shutdown remain separate operational work.

`retired_hosted_builds` runs real paired WebSocket and local socket rejection checks, verifies byte-identical authority/receipt storage, and then exercises Ping and profile synchronization on the same connection. It also checks hidden CLI rejection without creating state or reading a file. `local_profile_compatibility` retains native legacy-output/unknown-metadata coverage previously located in the old adoption test suite; its native bridge test uses `THUMBLE_TEST_ARTIFACT_RUNTIME_BIN` and remains a separate packaged test. Ordinary local artifact import is covered by the retained profile-flow checks.

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

## Profile orientation preferences

The receiver advertises `gamepad_profile_orientation_preference_mutation` in pairing
and full profile snapshots. Authenticated WebSocket requests must name an installed
profile and an automatic/portrait/landscape preference. A stale profile ID receives
authoritative state; malformed envelopes are rejected. Changes preserve the saved
layouts, bindings, selection, default and unknown profile fields while stamping
`updatedAt` and advancing the configuration revision once. Repeating the same
preference acknowledges without another write.

An active-profile change retires input generation and releases held output. A change
to an inactive profile preserves the active holds. Remote orientation changes commit
atomically before the new state is acknowledged. Failed persistence restores the old
profile configuration and releases input without advertising an unsaved preference.
Configuration mutations remain unavailable over UDP.

The CLI's existing `orientation.set` typed authoring command supports all three
preferences through its revision-checked configuration path. Its existing write
policy remains intact; no duplicate CLI command is needed.

Android/Rust acceptance can run against a private input-disabled receiver:

```sh
python3 Android/scripts/verify-profile-actions.py \
  --host Host/target/debug/thumble-host \
  --serial emulator-5554 \
  --adb "$ANDROID_SDK_ROOT/platform-tools/adb"
```

The verifier uses separate temporary state/socket paths, checks all three
orientations plus default selection and opaque layout/binding preservation, then
stops its receiver. Pairing data is not saved in evidence. The current source build
has passed this acceptance; this milestone does not replace the normal installed
receiver. Application launch execution remains open work.


## Attached-application launching

The macOS Rust runtime now handles authenticated reliable `launch_profile_target`
requests using only the installed profile UUID (or active profile when omitted).
It ignores remote target metadata. The standalone core/portable receiver still
reports this platform-specific operation as unsupported; UDP cannot invoke it.

A single in-flight worker resolves the stored bookmark, existing file path, then
LaunchServices bundle identifier in native Mac order. It validates a local app
bundle and waits for the input runtime to release keyboard, pointer and gamepad
holds before activation. It invokes `/usr/bin/open` with separate arguments and a
five-second process deadline. Resolution runs off the input thread. Failures retain
the paired connection. Unresolvable targets leave active input unchanged, matching
the native Mac. No configuration revision or profile content changes.

The local Rust CLI exposes the same operation:

```sh
thumble-host launch-profile [PROFILE_UUID] --json
thumble-host status --json
```

The command acknowledges queueing, not application readiness. `applicationLaunch`
in status contains a launch UUID, installed profile UUID, phase (`resolving`,
`releasing-input`, `launched`, or `failed`) and optional coded failure. It contains
no path, bookmark, app name or platform diagnostic text. `launched` means the OS
accepted the activation request; consumer readiness is application-specific.
The standalone Swift `thumble profile launch [NAME|UUID|active|default] [--json]`
now routes through its exact sibling Rust CLI bridge. It accepts only a bounded
typed profile selector, resolves it inside the runtime lock via the safe catalog,
and returns the same launch acknowledgement. Unknown/ambiguous profiles and Rust
runtime failures fail closed without legacy fallback. Existing legacy routing
retains its authority gate. Application attachment editing is still open.

Security-scoped bookmarks require the creating code-signing identity, as described
in [Apple's bookmark documentation](https://developer.apple.com/documentation/Foundation/NSURL/bookmarkData%28options%3AincludingResourceValuesForKeys%3ArelativeTo%3A%29?language=obj_7).
A bookmark from another identity falls back to the saved path or bundle identifier,
as native resolution does. Tests cover both a same-process scoped bookmark and a
foreign-bookmark path fallback; they do not imply cross-identity scope transfer.

Build and run isolated Android acceptance (no normal receiver installation changes):

```sh
cargo build --locked --manifest-path Host/Cargo.toml -p thumble-host
cargo build --locked --manifest-path Host/Cargo.toml -p thumble-host --example application_launch_fixture
python3 Android/scripts/verify-application-launch.py --host Host/target/debug/thumble-host \
  --serial emulator-5554 --adb "$ANDROID_SDK_ROOT/platform-tools/adb"
```

The private harness creates its scoped bookmark in the receiver process and calls
the production runtime. A disposable signed Mac app records actual launch and
activation, then exits. Its bundle lives in the repository build directory because
native LaunchServices lookup did not resolve the system-temporary-directory
fixture. The verifier unregisters the fixture and stops each private receiver.
The normal installed receiver and standalone Swift CLI have now been updated with
this support and orientation mutation. All five profiles, trust, input/Bonjour/
configuration-write settings and Accessibility access were preserved, with private
state and binary backups. The post-install real keyboard UDP-loss regression passes
on the API 26 emulator: exactly six AppKit key events, all releases recovered, and
no held input. See `Android/PARITY.md` for the broader incomplete Android inventory.

### Runtime skin library and phone synchronization

The Mac host opens a private archive store only when its sibling `thumble-bridge`
supports native skin operations. It then advertises `skin_packages` and
`gamepad_profile_skin_selection`. Initial pairing replays installed archives;
subsequent authenticated uploads and selections use a bounded worker independent
of the input lock. Swift owns package semantics and appearance transforms; Rust
owns archive persistence, revision checks, current connection checks and durable
profile commits. Embedded package profiles are never imported by these operations.

The primary Swift CLI routes runtime skin operations to the running Rust owner:

```sh
thumble skin import ./skin.pocketpad
thumble skin import ./skin.pocketpad --replace
thumble skin list --json
thumble skin apply com.example.skin@1.0.0 --profile active --appearance light
thumble skin detach --profile active
thumble skin export com.example.skin@1.0.0 -o exact.pocketpad
thumble skin remove com.example.skin@1.0.0
```

`--allow-downgrade` explicitly permits an older import. The native version
comparator enforces the same policy as the native store. Runtime references
currently require an explicit version; import a file before applying it. The
receiver JSON list exposes `packages` with canonical reference, digest, name and
opaque storage key. Removal rejects in-use references. Export preserves exact
archive bytes. Native authoring, compile and validation paths remain available.

Archives use owner-only files, no-follow opens, opaque hashed keys, atomic rename,
bounded library size and a filesystem lock. Native archive interpretation runs
outside the runtime input mutex. A profile change checks its original revision,
releases held input, persists, then broadcasts. Failed phone changes remain
unacknowledged for journal recovery; skin failure codes are recorded in the host
log without forcibly disconnecting the controller.

This first sync path bounds CLI archives to 3 MiB and total Base64 library replay
to 4 MiB; the transport retains its 8 MiB frame ceiling. There is no archive
chunking or automatic adoption of another legacy/bundled skin library. Physical
Pixel 7 acceptance covers both directions, CLI changes, held-capture release,
restart/reconnect, exact export and rejection without authority corruption through
`Android/scripts/verify-mac-skin-sync.py`. Its private receiver does not replace the
normal installation. Full skin library UI and renderer parity remain tracked in
`Android/PARITY.md`.

The packaged native `skin_sync` integration test also invokes the public Swift
`thumble skin` commands against its private receiver. It checks library listing,
byte-exact export, in-use removal rejection without state changes, detach/remove,
reimport and dark-appearance apply. The connected controller must receive the
committed profile changes; profile identity and paired-client trust are preserved.
The macOS packaging CI step runs this test with the actual packaged binaries.

With the native phone-layout bridge ready, complete phone customization updates
use the same bounded worker. They can replace active or inactive orientation
layouts and recover a deleted profile as `Recovered Phone Layout`, without
changing the active/default selection. The shared Swift model normalizes layouts,
preserves the other orientation, maintains primary mirrors, and dehydrates
installed skin assets. The bridge works independently of archive-store availability;
older bridge packages retain the scalar appearance compatibility path.

Each queued layout intent takes the current receiver-owned profile when native
preparation starts. Rust then rejects configuration changes during preparation,
rechecks the authenticated connection, reconciles only the target profile's
bindings, and persists before broadcasting acknowledgement. Profile metadata and
new pairing trust remain receiver-owned. Identical layouts do not increment the
revision. Queue pressure retains the connection so outstanding phone intents can
retry on subsequent authoritative snapshots. The native integration test covers a
twelve-layout burst exceeding the eight-slot queue, metadata/selection preservation,
recovery, no-op revision stability, receiver CLI reads and failed-save rejection.

`Android/scripts/verify-mac-layout-edits.py` verifies the complete Android round
trip against a private no-input receiver. `--without-skin-library` additionally
checks that an unavailable archive store does not disable layout synchronization.
The public Swift CLI's canonical-state policy is unchanged; private fixture profile
reads use `thumble-host profiles --json`.

Add `--editor-ui` to exercise visible Android move, resize, rotate, delete,
Undo/Cancel and offline Done/reconnect, followed by receiver restart and CLI
identity checks. Add `--template arcadeStick --custom-control` to exercise a
declared custom button and grouped-control reference pruning. Add
`--skin path/to/existing.pocketpad` to import/apply an unchanged package through
the receiver CLI and verify canonical asset references plus exact archive export.
These acceptance modes use private state, memory-only Android profiles and disabled
Mac input. They do not modify the normal receiver installation or approve artwork.


Android's Skins library now exposes outgoing archive sharing, document export and
guarded removal. Its client removal journal is bound to the paired Mac and remains
until queued local replay cleanup finishes. The existing `skin_package_removal`
message has no explicit receiver persistence acknowledgement; reconnect retries
and local-cleanup durability are verified with loopback peers. Native Android UI
removal acceptance against the Mac remains tracked in `Android/PARITY.md`. The
receiver and public CLI keep their existing in-use-reference checks.


## Installed Android adoption acceptance (2026-10-20)

The updated receiver and bridges were installed at the existing user installation
and tested on port 8765 with real input and configuration writes enabled. The
Android app was installed on the dedicated API 26 emulator and connected directly
to that normal receiver. `Android/scripts/verify-installed-artifact-adoption.py`
checks reviewed adoption, exact public CLI replay/status, late cancellation of a
committed operation, production Android cancellation with retained bytes, and
public CLI cancellation delivered to a pending Android WebSocket upload.

The run exposed two legacy configuration-bridge issues. Typed native decoding now
projects the host's inline keyboard `modifiers` spelling to `modifiersRawValue`
without changing stored profile JSON; portable artifact decoding stays strict.
Rust also preserves original integral-float representation when Swift returns an
exactly equal integer, matching profile/control identities across array moves.
Changed numeric values and rounded large integers still fail strict delta checks.
Regression tests cover raw-profile preservation, reordered metadata, invalid
modifier ranges, and constrained-thread decoding.

The test removes only its synthetic profile IDs through the public CLI and
restores the original selection. All five original profiles, global/per-profile
binding maps and the default were verified unchanged against the pre-install
backup. Evidence: `Android/app/build/evidence/installed-artifact-adoption/20261020T144933Z/verification.json`.
This checkpoint used the emulator; subsequent physical-phone checkpoints follow.


Physical Pixel 7 (API 37) acceptance now also passes against the normal receiver
through the phone's direct Wi-Fi route, including reviewed adoption, public CLI
replay/status, Android cancellation, CLI cancellation delivered to Android, and
restoration of original profiles/bindings/default/selection. The app was updated
in place and its existing saved Mac connection still works. Receipt and binary
hashes: `Android/app/build/evidence/installed-artifact-adoption/20261020T145409Z/verification.json`.


Physical Pixel 7 Wi-Fi interruption recovery also passes for an incomplete upload
and a committed operation whose result has not reached Android. A test-only
phone-local relay pauses the boundary, then USB disables the actual Wi-Fi radio;
its real upstream failure reaches the production Android client/coordinator.
Offline pending bytes and operation identity survive. Reconnect/retry and public
CLI replay create no duplicate profiles, including replay of the already committed
destination ID. Pending removal waits for authoritative snapshot confirmation.
Wi-Fi and the original five profiles, bindings, default and selection are restored;
the normal app reconnects with saved credentials. Repeatable harness:
`Android/scripts/verify-wifi-adoption-recovery.py`. Evidence:
`Android/app/build/evidence/wifi-adoption-recovery/20261020T150648Z/verification.json`.
Long outages and ungated router-failure timing remain separate cases; process-death
acceptance follows below.


Pixel 7 force-stop/relaunch acceptance passes during partial upload and after Mac
commit before Android confirmation. The actual app process is killed; while its
PID is absent the app-private pending metadata remains ADOPTING and artifact bytes
match the original SHA-256. A fresh process launches MainActivity using isolated
production disk stores, reloads encrypted Mac credentials, recovers the pending
record as retryable, and retries through Shared builds directly over Wi-Fi.
Operation/record/server/hashes survive. Each operation creates exactly one profile
copy; committed retry and public CLI replay return the original destination ID.
Pending cleanup waits for authoritative confirmation. Original profiles, bindings,
default and selection are restored, and the normal app reconnects afterward.
Harness: `Android/scripts/verify-process-death-adoption.py`. Evidence and UI captures:
`Android/app/build/evidence/process-death-adoption/20261020T151151Z/verification.json`.
The first attempt uses a test-only boundary relay; reboot acceptance follows below.
Arbitrary crash timing remains a separate case.


Pixel 7 physical reboot acceptance passes for partial upload and a committed result
not yet delivered to Android. Distinct boot IDs verify reboot; after manual unlock,
the pending metadata and artifact hash survive on disk before any app launch.
MainActivity reloads encrypted credentials and the pending record from isolated
production stores, then a UI retry reconnects directly over Wi-Fi. Each operation
creates exactly one profile copy; committed retry and CLI replay return the original
destination ID. Pending cleanup waits for authoritative confirmation. Original five
profiles, all binding maps, default and selection are restored; the normal app
reconnects afterward. Harness: `Android/scripts/verify-reboot-adoption.py`.
Receipt and screenshots:
`Android/app/build/evidence/reboot-adoption/20261020T152343Z/verification.json`.
An initial partial-upload reboot run preserved bytes but exceeded the 35-second
reconnect/recovery wait. The complete rerun passed without a production fix; the
subsequent discovery-race investigation below provides a reproducible failure and fix.
Its log is under `Android/app/build/evidence/reboot-adoption/20261020T151542Z/`.


Android trusted reconnect now preserves a healthy in-progress handshake when
Bonjour supplies additional addresses. The previous path canceled that attempt
and could stall on an unreachable alternative. A controlled regression failed
before the change and passes on the API 26 emulator and API 37 Pixel afterward;
normal socket-loss, discovery fallback and explicit-disconnect recovery tests pass.
Both fixed-app physical reboot adoption UI cases reconnect in under three seconds
with the original timeout. Per-operation CLI replay confirms one destination each.
The original timeout lacked a discovery trace, so its historical trigger cannot
be established conclusively from that run.

The global profile-count guard detected a concurrent Warband Command addition.
This run's two synthetic profiles were removed and the unrelated profile was
preserved. Audited operation receipts and timelines:
`Android/app/build/evidence/reboot-adoption/20261020T154758Z/operation-verification-reviewed.json`.
Regression evidence and stack-safety gate:
`Android/app/build/evidence/reconnect-startup-fix/20261020T154435Z/`.
The normal Host was then intentionally stopped in another chat for the Mac editor;
additional recovery reruns use a private recording-only receiver and child-process
home, preserving that requested ownership. No normal Host restart is performed.


Post-fix isolated recording-only Wi-Fi and force-stop recovery reruns both pass,
including retained bytes, UI retry, authoritative cleanup and public CLI replay.
Receipts: `Android/app/build/evidence/wifi-adoption-recovery/20261020T160550Z/verification.json`
and `Android/app/build/evidence/process-death-adoption/20261020T160615Z/verification.json`.
Repeatable isolated runner: `Android/scripts/verify-isolated-adoption-recovery.py`
with explicit serial, ADB, bin and receiver-host arguments. Combined verification:
`Android/app/build/evidence/reconnect-startup-fix/20261020T154435Z/verification.json`.
The driver-only instrumentation fixtures now skip when no external-driver arguments
are supplied. The normal Host remains intentionally stopped for the Mac editor.

### Controller binding display metadata

Profile snapshots now include `bindingPresentations` for Android and iOS: compact
output text plus a separate accessibility description, grouped by profile and
orientation. The receiver and `thumble binding display` share authoritative raw
binding resolution, including explicit part clears, legacy joystick mappings and
output-mode filtering. Display strings never choose or execute input bindings.
