# Hosted builder session v1

`thumble-builder` is the pure, credential-free state machine beneath the
planned tunnel-free MCP connector. It owns no filesystem, sockets, clocks,
randomness, pairing, phone delivery, process execution, or input APIs. The
gateway supplies opaque IDs/timestamps and persists sessions per authenticated
builder principal.

## Lifecycle and authority

A session starts from the canonical minimal `ConfigurationDocument` at revision
1. Caller-supplied timestamps are nonnegative I-JSON-safe integers; TTL is at
most 24 hours. The serialized session contains no owner/account/device identity.
Gateway storage keys ownership externally.

Every mutation carries:

- canonical UUID operation ID;
- expected session revision;
- typed operation descriptor;
- caller-supplied timestamp.

The session stores RFC 8785/SHA-256 descriptor and document digests. Identical
operation ID + descriptor + base revision replays; changed content conflicts.
Revision increments only when a fully validated, portable candidate changes the
document. At most 256 operation records are retained.

Custom deserialization revalidates the complete revision chain, descriptors,
document digest, timestamps, receipt history, profile references, and portable
artifact safety. Public APIs expose immutable accessors and bounded projections,
not the raw document.

## Operations

Session v1 supports:

- profile rename;
- control layout/visibility/lock edits and removal;
- semantic keyboard binding set/clear with element-output synchronization;
- output-mode selection;
- deterministic `generate_from_spec` replacement using generation spec v1;
- catalog-bounded installation of all 17 controller templates;
- validation, sanitized controller preview, artifact emission, emission-deletion
  handoff, and discard.

Builder generation and template installation replace the single working profile
and invalidate prior emission. Later phases may extract more host edit
operations into `thumble-core`; arbitrary JSON patching is intentionally absent.

## Preview, validation, and artifact emission

Validation uses `ConfigurationDocument::validate` plus the core layout-quality
evaluator. Preview creates a temporary credential-empty state and returns the
bounded `ControllerSnapshot`: safe geometry, appearance, labels, semantic
outputs, layers/groups/styles, and layout issues only.

Explicit emission creates profile artifact v1 with `exportedAt: 0`, caches its
bytes/hash by revision, and returns a receipt. Repeated emission at the same
revision is byte-identical. Changes invalidate the receipt. After downstream
share storage succeeds, `mark_emitted` returns `deleteSession: true`; the Phase
4 gateway performs actual deletion.

## Template fixtures

Swift remains the canonical template designer. To avoid a Swift runtime in the
cloud, Phase 3 checks in one portable post-materialization fixture per template
revision under:

```text
Host/fixtures/controller-templates/v1/
```

Fixtures include profile JSON and canonical keyboard/output maps with all
`updatedAt` values zeroed. A SHA-256 manifest, strict Rust loader, recursive
profile/custom-ID replacement, and real three-sibling verification preserve
semantic parity for all 17 templates.

```bash
scripts/verify-controller-template-fixtures.sh /path/to/bin-directory
```

Default mode regenerates into a temporary directory and byte-compares. Explicit
`--update` stages and validates a complete replacement directory before atomic
exchange; interruption or failure leaves the previous canonical fixture set.

## Bounds and security

- session JSON: 18 MiB;
- configuration/artifact: 8 MiB;
- operations: 256;
- TTL: 24 hours;
- status profiles projected: 64 plus omitted count;
- changed paths: 16;
- generation controls/warnings/layout issues retain their core bounds.

Every candidate passes profile-artifact portability before commit. Launch
targets, paths, URLs, embedded data, credentials, device/server/pairing identity,
process fields, and unsafe numeric/string content fail closed. Generation errors
are stable structured codes with bounded paths and never echo raw attacker
input.

The crate directly depends only on exact-pinned serialization/hash/UUID crates,
`thumble-core`, and `thumble-protocol`; it has no `thumble-host`, Tokio, network,
filesystem, or subprocess dependency.

## Capability status

The connector, nine builder tools, and share endpoint are `partial`, not
available: authenticated gateway storage, MCP routing, OAuth, and fragment-token
share delivery are locally implemented and verified, while reviewed production
deployment and visible ChatGPT acceptance remain pending.
