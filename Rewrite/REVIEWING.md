# Reviewing the headless rewrite

This is a coexistence implementation under `Rewrite/`. Review process ownership, durable transactions and native input safety before product cutover. The current runtime records reports; a controller can be exercised without emitting OS input. The draft PR tracks outstanding acceptance gaps and source-specific CI results.

## Review map

| Area                       | Start here                                                                                                                                                                | Invariants to check                                                                                                        |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| Process ownership          | `apps/service/src/service.ts`, `configuration-owner.ts`, `configuration-owner-process.ts`                                                                                 | Configuration IO runs outside the parent heartbeat loop; shutdown confirms child exit; one SQLite writer owns an authority |
| Configuration and receipts | `packages/contracts/src/configuration.ts`, `packages/application/src/configuration-catalog.ts`, `configuration-import.ts`, `packages/storage/src/configuration-sqlite.ts` | Explicit stable identities, CAS conflicts, original receipt on retry, changed payload under an operation ID rejected       |
| Exact source and assets    | `packages/contracts/src/lossless-json.ts`, `packages/domain/src/owned-authority.ts`, `packages/storage/src/asset-files.ts`                                                | Numeric lexemes and opaque metadata survive; asset bytes precede authority publication; interrupted staging recovers       |
| Native trust and transport | `native/receiver/src/phone_trust.rs`, `authenticated_control.rs`, `input_broker.rs`                                                                                       | Credential/epoch/clock checks, bounded work, no secrets exposed to JavaScript, acknowledged revocation/release             |
| Independent receiver       | `native/receiver/src/native_ingress.rs`, `runtime.rs`, `packet_runtime.rs`                                                                                                | Stale generation/replay rejection, independent owner/input expiry, restart neutral, no indefinite hold                     |
| Native phone ownership     | `native/mobile-input/ios/Sources/`, `native/mobile-input/android/src/main/`, `apps/mobile/modules/thumble-input/`                                                         | Touch/sample ownership stays native, bounded bridge metadata, cancellation and neutral reconnect, safe grant handoff       |
| Distribution               | `tooling/build.ts`, `tests/package.test.ts`, `.github/workflows/typescript-rewrite*.yml`                                                                                  | Standalone sibling binaries, notices, no checkout/Bun required at runtime, actual Windows runner evidence                  |

Reviewed-file import replaces saved configuration through a bounded background job. Inspect [the import contract](../docs/rewrite-configuration-import-v1.md) and its lost-reply/restart, changed-file, large-document and input-isolation tests. Structural saved-data admission does not establish activation or image compatibility.

The source paths above are relative to `Rewrite/`, except the root workflow directory. The retained product remains in place while these seams are implemented.

## Reproduce the host checks

From `Rewrite/`, with the pinned toolchains installed:

```sh
bun install --frozen-lockfile
bun run native:build
bun run verify
bun run native:test
bun run build
bun run test:package:ci
```

`verify` checks generation, dependency boundaries, dependency notices, formatting, strict types and source tests. Standalone packaging is an explicit separate check. Packaging copies binaries outside the checkout, removes Bun/Node from the server PATH and exercises real service/receiver/CLI/MCP behavior. Independent Node SDK clients are test clients, not product runtime dependencies.

Native Swift/Kotlin tests, iPhone/simulator SDK compilation, Keychain/Keystore provider cases and bundled phone-app witnesses run in the native/mobile workflows. Retained shared Swift changes also require `scripts/verify-stack-safety.sh` from the repository root.

## Review evidence and current limits

Use the workflow run's head SHA when comparing results. The PR distinguishes full matrix runs from narrow witnesses and records unresolved failures. Windows input expiry under slow IO and hosted iOS bundled-app connectivity remain reliability investigations. The minimal iOS HTTP probe and temporary native debug counters only help locate those failures; they are not acceptance replacements.

The local 75-second held-input tests cover two native grant renewals, release and neutral reconnect with recording output. They do not prove gameplay or physical output. Windows driver behavior, signed helper authorization, clean installation, ergonomics and beta tester acceptance remain separate gates.

## Before release

The full requested product includes rich profile/design tools and previews, import/export with validated assets, phone editing and durable journals, discovery/QR, haptics, migration and both WoW experiences with mandatory optical live sync. Physical macOS/Windows output and signed distribution must be enabled and verified before this is presented as a usable gameplay beta. The protocol contracts under `docs/rewrite-*.md` document current behavior. Review of this foundation does not close the remaining product or launch gates.
