# Reviewing the headless rewrite

This is a coexistence implementation under `Rewrite/`. Review process ownership, durable transactions and native input safety before product cutover. The current runtime records reports; a controller can be exercised without emitting OS input. The draft PR tracks outstanding acceptance gaps and source-specific CI results.

## Review map

| Area                       | Start here                                                                                                                                                                                           | Invariants to check                                                                                                        |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| Process ownership          | `apps/service/src/service.ts`, `configuration-owner.ts`, `configuration-owner-process.ts`                                                                                                            | Configuration IO runs outside the parent heartbeat loop; shutdown confirms child exit; one SQLite writer owns an authority |
| Configuration and receipts | `packages/contracts/src/configuration.ts`, `packages/application/src/configuration-catalog.ts`, `configuration-import.ts`, `configuration-export.ts`, `packages/storage/src/configuration-sqlite.ts` | Explicit stable identities, CAS conflicts, original receipt on retry, changed payload under an operation ID rejected       |
| Exact source and assets    | `packages/contracts/src/lossless-json.ts`, `packages/domain/src/owned-authority.ts`, `packages/storage/src/asset-files.ts`                                                                           | Numeric lexemes and opaque metadata survive; asset bytes precede authority publication; interrupted staging recovers       |
| Native trust and transport | `native/receiver/src/phone_trust.rs`, `authenticated_control.rs`, `input_broker.rs`                                                                                                                  | Credential/epoch/clock checks, bounded work, no secrets exposed to JavaScript, acknowledged revocation/release             |
| Independent receiver       | `native/receiver/src/native_ingress.rs`, `runtime.rs`, `packet_runtime.rs`                                                                                                                           | Stale generation/replay rejection, independent owner/input expiry, restart neutral, no indefinite hold                     |
| Native phone ownership     | `native/mobile-input/ios/Sources/`, `native/mobile-input/android/src/main/`, `apps/mobile/modules/thumble-input/`                                                                                    | Touch/sample ownership stays native, bounded bridge metadata, cancellation and neutral reconnect, safe grant handoff       |
| Distribution               | `tooling/build.ts`, `tests/package.test.ts`, `.github/workflows/typescript-rewrite*.yml`                                                                                                             | Standalone sibling binaries, notices, no checkout/Bun required at runtime, actual Windows runner evidence                  |

Reviewed-file import replaces saved configuration through a bounded background job. Inspect [the import contract](../docs/rewrite-configuration-import-v1.md) and its lost-reply/restart, changed-file, large-document and input-isolation tests. Structural saved-data admission does not establish activation or image compatibility. [Pinned saved export](../docs/rewrite-configuration-export-v1.md) verifies resource bytes and publishes an explicit local file without replacing a destination; export jobs are ephemeral and never mutate authority.

The [portable optical core](../docs/rewrite-wow-live-v1.md) preserves the retained page/schema protocol with bounded assembly and monotonic observation freshness. It does not implement OS capture, authenticate game observations or publish phone state. Review scalar field types as well as enum values. The [pending observer](../docs/rewrite-wow-observer-v1.md) invalidates superseded/stale intents and accepts a matching receipt only after the authority adapter reports a committed transaction.

The [native clock reservation design](../docs/rewrite-native-clock-reservations-v2.md) removes packet-time durable trust writes while preserving epoch invalidation, rollback and fail-closed expiry. Review its bounded restart cooldown and latched storage-failure recovery.

[Saved selection](../docs/rewrite-profile-selection-v1.md) atomically updates active/default identities and the selected binding mirrors. Inspect its disjoint-control, explicit-empty, independent fallback, source-preservation and export/re-import tests. Canonical v5 continues to reject retired orientation fields; legacy preservation belongs to migration.

[Saved duplication](../docs/rewrite-profile-duplication-v1.md) commits cloned source, independent binding maps and resource aliases atomically, with explicit selection and durable retries.

[Phone catalog reads](../docs/rewrite-phone-catalog-v1.md) use a separate management-only TLS role and the sole saved authority. Check flat metadata projection, one underlying read, phone abandonment without child poisoning, and deferred invalidation delivery after global store/policy locks are released. The independent TLS peer exercises real service reads and stale revision conflicts.

[Output inspection](../docs/rewrite-output-doctor-v1.md) is available through offline CLI `output doctor` and read-only MCP `output_doctor`. It distinguishes compiled capabilities and signed claims from OS authorization. Review child execution bounds, exact contracts and the default dependency graph; inspection must never create a virtual device. The [dormant output core](../docs/rewrite-native-output-core-v1.md) owns bounded native work, generation/deadline checks and acknowledged retirement. Its optional macOS adapter and pure Windows mapping are not wired into the receiver. The [Windows compile experiment](../docs/rewrite-windows-candidate-build-only.md) verifies pinned source and toolchain archives, compiles unsigned files and uploads bounded evidence; it never installs or executes the compiled driver/helper.

[Saved control projection](../docs/rewrite-saved-controller-map-v1.md) supports a strict subset of saved rectangular buttons, standard analog sticks and continuous triggers. The [analog contract](../docs/rewrite-saved-controller-analog-v1.md) preserves the supported retained deadzones, independent axes and logical geometry; custom settings and unsupported capture shapes fail admission. Check selected binding precedence, source identity, logical viewport geometry and rejection of unsupported semantics. [Saved activation](../docs/rewrite-saved-runtime-binding-v1.md) explicitly binds a source revision/hash/profile to a new native generation. Inspect the separate source-read CAS and native CAS, uncertain-reply status, pin retirement and the ordinary activation path clearing the binding. [Saved-map delivery](../docs/rewrite-saved-controller-delivery-v1.md) installs the supported saved subset on both native phone views after a separate bounded management read and a final input grant check. Unsupported layouts fail admission; connected mode has no template fallback. Activated snapshots remain immutable across later storage-only edits until explicit reactivation.

The [real-service phone witness](tooling/real-service-phone-probe.md) runs the actual CLI/service, persistent host identity, saved authority and native receiver. Swift/Kotlin catalog and five-mode input tests run against it as additional CI gates, including both 75-second renewal holds. The additional saved-map cases exercise actual saved activation, map installation, recorded button input and immutable snapshot behavior after a storage edit. The earlier five-mode cases retain their separate transport and renewal coverage. Raw offers and endpoint data stay private to owned test processes; uploaded outcomes are sanitized. `NativeController.test.tsx` exercises the actual React component through substituted native host boundaries and verifies summary reset on reconnect. OS native-to-JavaScript delivery and visual layout need separate evidence.

[Native touch haptics](../docs/rewrite-native-haptics-v1.md) run only for accepted native touches, with bounded schedules, local opt-out and lifecycle cancellation. Platform strength/sharpness approximations and physical acceptance remain explicit.

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

Use the workflow run's head SHA when comparing results. The PR distinguishes full matrix runs from narrow witnesses and records unresolved failures. Windows malformed catalog-child reliability and the iOS app renewal witness remain under investigation. The import-isolation witness now continues both owner renewal and input samples while resumed disk work finishes; an owner heartbeat correctly cannot refresh input TTL. Native aggregate timings and fixed-code pipe diagnostics distinguish transport, owner work and cleanup without exposing payloads or changing product deadlines. Hosted bundled-app connectivity also requires source-specific results; diagnostic probes do not replace those gates.

The local 75-second held-input tests cover two native grant renewals, release and neutral reconnect with recording output. They do not prove gameplay or physical output. Windows driver behavior, signed helper authorization, clean installation, ergonomics and beta tester acceptance remain separate gates.

## Before release

The full requested product includes rich profile/design tools and previews, import/export with validated assets, phone editing and durable journals, discovery/QR, physical haptic acceptance, migration and both WoW experiences with mandatory optical live sync. Physical macOS/Windows output and signed distribution must be enabled and verified before this is presented as a usable gameplay beta. The protocol contracts under `docs/rewrite-*.md` document current behavior. Review of this foundation does not close the remaining product or launch gates.
