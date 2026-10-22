# Thumble rewrite workspace

Isolated M2 implementation under coexistence. Bun **1.4.3**, TypeScript **6.0.3** and Rust **1.88.0** are pinned. This development seam uses a **recording backend**: it emits no OS input and does not activate a retained profile catalog.

Development requires Node 20+ for independent MCP SDK and TLS protocol checks. The standalone user runtime consists of the CLI and native helper binaries.

```sh
bun install --frozen-lockfile
bun run native:build
bun run verify
bun run build
bun run test:package:ci
```

`bun run generate` updates TypeScript, Swift, Kotlin and Rust bindings from the semantic gamepad schema; `bun run check:generated` detects drift. The pure TypeScript and native encoders match all 34 retained v2 report vectors in `Host/fixtures/gamepad/v2.json`. Generated DTOs alone do not provide mobile input modules or authenticated phone transport. The compatibility descriptor's MIT notice remains in `ThirdParty/SteamControllerBridge-LICENSE.txt` and is copied into development packages.

Contracts, domain, application and the default client entry compile without Bun/Node/DOM globals. AST checks enforce package boundaries. `@thumble/client/local` is the explicit host adapter for the same-user control channel; mobile code must use the portable client interface.

## Headless receiver seam

The CLI starts a detached local service. The service owns ephemeral activation configuration, serializes operations, and talks to a separate Rust receiver over bounded NDJSON pipes. The receiver owns generation/sequence validation, held-state expiry, owner leases and neutralization. It never imports the profile catalog. On Windows the receiver has a detached process lifetime so it can perform cleanup after abrupt service termination. Stopping the service releases first; owner pipe closure or a stalled JavaScript runtime independently expires the native session.

The control channel binds only to loopback and authenticates each request with a random credential in a user-restricted runtime directory. Unix modes are 0700/0600; the native helper applies Windows owner/SYSTEM ACLs and rejects reparse paths. Credentials are never returned in CLI JSON or recorded controller reports. Native exclusive locking prevents two receivers from owning one directory. Nonempty directories belonging to another owner are refused before permission changes.

Configuration revisions and profile generations are canonical decimal u64 strings. Activation requires the current revision; every sample requires the active generation and a strictly increasing sequence. Native acknowledgment commits the service's session. Restart begins neutral with a new service identity and no active profile. This is an ephemeral runtime seam, not durable profile transactions or migration.

```sh
bun run cli service start --runtime-dir /absolute/private/runtime --json
bun run cli receiver activate --runtime-dir /absolute/private/runtime --expected-revision 0 --profile-id example --json
bun run cli receiver status --runtime-dir /absolute/private/runtime --json
bun run cli service stop --runtime-dir /absolute/private/runtime --json
```

The runtime directory's parent must exist. Omit `--runtime-dir` for `~/.thumble-rewrite-runtime`. The source CLI locates the debug receiver; compiled packages locate a sibling receiver. `receiver sample` takes `--expected-generation`, `--sequence`, `--state-file` and explicit `--allow-recorded-input`. Full-state samples must keep arriving within the input TTL; heartbeat renewal cannot preserve stale held input. Status reports the recording backend, disabled OS input, and unevaluated permissions/game recognition separately.

`bun run build` creates standalone sibling CLI/receiver binaries and the notice in `dist/`. The package integration test copies them outside the checkout, removes Bun from PATH, and checks start/status/stop and endpoint cleanup. These are unsigned development artifacts, not release installers.

GitHub Actions runs native tests, format/Clippy, strict/generated/boundary checks, real service fault tests and package tests on Windows, macOS and Linux, plus Swift DTO typechecking on macOS. Windows uses hosted runners throughout. Missing hardware never counts as gameplay success.

## Remaining gates

Native mobile input-module skeletons now live in `native/mobile-input/`: both native engines pass the shared fixtures locally, the UIKit modules compile for iPhone/Simulator, and Android builds an AAR with passing tests/lint. The separate native CI workflow verifies shared native fixtures and iPhone/Simulator SDK and Android library builds. React Native application/bridge wiring and authenticated phone transport remain M3 work. Signed-helper invocation and physical native/gameplay acceptance remain M2 release gates. Pairing, phone transport, durable authority, mobile controls/editing, WoW integrations and required optical live sync follow in later milestones. Windows, iOS and Android remain launch requirements. No retained desktop/native authority is retired or automatically migrated by this workspace.

## Pairing window groundwork

The service now owns a single short-lived pairing window through shared portable application operations. `pairing open --reveal-secret --json` explicitly returns one 256-bit bootstrap secret; `pairing status --json` omits it and `pairing cancel --json` invalidates it. These commands use the same `--runtime-dir` and authenticated same-user IPC as receiver commands. Windows expire after 120 seconds, permit five failed proofs, and close on replacement, restart, cancellation or clock rollback. Only a domain-separated verifier stays in memory.

This is bootstrap material for the future native pinned TLS enrollment path. Replies explicitly report `networkEnabled: false`. There is no LAN pairing listener, phone trust enrollment or new input session yet. A complete network invitation must bind the host pin and address before a phone can use it. See the protocol decision in `../docs/adr/0001-rewrite-pairing-and-input-transport.md`. The portable pairing client validates authority identity and refuses a secret-bearing status response. Pairing alone never enables production input.
