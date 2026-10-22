# Thumble rewrite workspace

Thumble's CLI/MCP authority, phone controller and headless receiver are being implemented here alongside the retained product. Bun **1.4.3**, TypeScript **6.0.3** and Rust **1.88.0** are pinned. The receiver currently records input; it emits **no OS input**. This workspace is ready for implementation review, with launch gates still open.

Start with [the review guide](REVIEWING.md) for a code map, runnable checks and the remaining product work.

## Build and verify

Run from `Rewrite/`:

```sh
bun install --frozen-lockfile
bun run native:build
bun run verify
bun run build
bun run test:package:ci
```

Development checks use Node for independent MCP SDK and TLS protocol clients. The compiled user runtime needs only the sibling CLI and receiver binaries. Build output in `dist/` includes dependency notices and the review guide. GitHub Actions builds and tests Windows, macOS and Linux packages; Windows work is headless throughout.

## Implemented paths

| Path              | Current behavior                                                                                                                                                                                                     |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| CLI and stdio MCP | Shared local service operations, explicit configuration-write and recording-input capabilities, bounded typed replies                                                                                                |
| Configuration     | Separate SQLite owner process; durable CAS receipts; lossless owned-v5 inspection; profile catalog listing/rename/selection; reviewed-file import/export jobs; immutable content-addressed assets and crash recovery |
| Pairing and trust | Explicit native host identity, manual listener/invitation, pinned TLS enrollment, native Keychain/Keystore credential storage and revocation                                                                         |
| Phone input       | Native iOS/Android touch ownership outside the React root; encrypted UDP with TLS fallback; neutral reconnect; lifecycle release; bounded grant renewal                                                              |
| Receiver          | Independent generation/sequence checks, owner leases, input expiry and release acknowledgment; recording backend only                                                                                                |

Structural file inspection does not establish image decoding, platform output support or activation compatibility. Saved configuration is separate from ephemeral recording activation. No retained authority is automatically migrated or retired.

## Local review commands

For macOS/Linux shell examples, replace the absolute paths with your chosen private locations. Their parent directory must exist.

```sh
bun run cli service start --runtime-dir /absolute/private/runtime --json
bun run cli receiver status --runtime-dir /absolute/private/runtime --json
bun run cli configuration list --runtime-dir /absolute/private/runtime --json
bun run cli service stop --runtime-dir /absolute/private/runtime --json
```

Owned-v5 file inspection works offline, without a service or receiver:

```sh
bun run cli configuration validate-file --file /absolute/path/configuration.json --json
```

To initialize or replace saved configuration, inspect a local owned-v5 file first, then use the revision/hash-bound `configuration import-file` job and poll `configuration import-status`. See [the import contract](../docs/rewrite-configuration-import-v1.md). This admits saved data structurally and does not activate input or establish image/runtime compatibility.

Saved active/default selection uses `configuration select-profiles` with both selectors and an expected revision. It synchronizes saved binding mirrors and leaves input activation separate. See [the selection contract](../docs/rewrite-profile-selection-v1.md).

Export the pinned current saved configuration with `configuration export-file` and poll `configuration export-status`; the destination is never overwritten, and external resources are verified before materialization. See [the export contract](../docs/rewrite-configuration-export-v1.md). The portable [optical observation core](../docs/rewrite-wow-live-v1.md) decodes bounded pages and tracks observation freshness; capture and phone delivery remain open.

Configure an agent to launch `dist/thumble-rewrite mcp serve --runtime-dir /absolute/private/runtime` (use `.exe` on Windows). Read-only tools are the default. Add `--allow-configuration-write` for saved configuration mutations or `--allow-recorded-input` for recording-input tools. Neither flag enables OS input. MCP stdout contains protocol messages only.

A persistent host identity is initialized explicitly with `identity initialize --identity-dir /absolute/private/identity --json`. Start the service with that same `--identity-dir` before configuring a network pairing listener. Pairing commands that return an invitation require `--reveal-secret`; status/list responses omit secrets. See [headless pairing](../docs/rewrite-headless-pairing.md) and [native enrollment](../docs/rewrite-enrollment-v1.md) for the manual listener and trust flow. Do not put invitations in review artifacts.

## Mobile development

See [the mobile README](apps/mobile/README.md). Expo native development/Release builds link the shared Swift/Kotlin modules; Expo Go is not the acceptance environment. Practice runs locally; the connection flow uses native enrollment and input transport. Native sampling and feedback continue independently of the JavaScript queue.

## Remaining product and release gates

Complete configuration import/export and rich editing, phone journals/reconciliation, discovery/QR, haptics, migration, WoW Classic Era + ConsolePort and WoW Forever integration, and mandatory optical live sync. Implement and verify macOS/Windows physical output, helper/driver signing, clean installation and gameplay. Hosted iOS bundled-app reliability and intermittent Windows slow-IO input expiry are still under investigation; a green focused run is not a root-cause fix.

The [review guide](REVIEWING.md) summarizes the implementation and remaining product gates. Protocol contracts in the repository's `docs/rewrite-*.md` describe the implemented seams; workflow results must be matched to their exact source commit.
