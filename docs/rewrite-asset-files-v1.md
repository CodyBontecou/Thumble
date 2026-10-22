# Configuration asset files v1

The host stores immutable asset bytes under `assets-v1` beside its configuration database. TypeScript owns configuration validation, operation fingerprints, revisions and receipts. The native helper supplies filesystem protection, hashing, no-clobber publication, durability requests and a process lease. It has no editable catalog or configuration policy.

This is the storage prerequisite for rich imports. The public CLI/MCP currently exposes no binary asset write, bulk import or caller-supplied fingerprint. The owned-v5 file reader remains an interchange validator; its inline resource pool is not yet the canonical authority representation. Render/image validation, materialization, external reference admission, export and reachability garbage collection remain separate work.

## Private helper protocol

Every command takes an absolute runtime directory. `assets-prepare ROOT` reads stdin as a four-byte unsigned big-endian JSON-header byte count, exactly that many UTF-8 JSON bytes, then concatenated asset bytes. The strict header has `version: 1`, `operationId`, `payloadHash` and `assets: [{sha256, byteCount}]`. Hashes are lowercase SHA-256, entries strictly hash-sorted and unique. Operation IDs have 1–64 ASCII alphanumeric/hyphen characters. Unknown/duplicate header fields, trailing bytes, malformed lengths and digest mismatches fail before namespace creation.

The complete frame is bounded by 8 MiB of unique asset bytes plus 64 KiB of header and the four-byte prefix. At most 256 assets are accepted. Empty bytes are valid content. TypeScript copies input arrays, hashes, deduplicates and sorts before framing; neither resource keys nor original filenames become paths.

A successful prepare returns `{version, stageId, operationId, payloadHash, assets, totalBytes}` only after its preparation record and every object are durable. The stage ID is SHA-256 of UTF-8 `thumble-asset-stage-v1` + NUL + operation ID + NUL + payload hash. Repeating an identical preparation is idempotent; different manifests under the same identity fail.

`assets-read ROOT SHA` returns raw bytes only after complete digest verification. `assets-pending ROOT` returns bounded stage summaries, including incomplete preparations. `assets-manifest ROOT STAGE` verifies a preparation and every object before returning it. `assets-retire ROOT STAGE` idempotently deletes only the preparation metadata. It never deletes asset bytes.

The shared synthetic [vector](../Rewrite/packages/fixtures/asset-files-v1/vector.json) fixes framing, binary content, manifests and stage identity for both native process and TypeScript tests. Diagnostics use bounded static error codes; no object contents or filesystem paths are returned in errors.

## Publication and recovery

The sole SQLite owner checks receipt replay, expected revision and revision exhaustion before staging. Prepared bytes precede the single SQLite transaction containing both source references and the successful receipt. The transaction rechecks replay/revision. A receipt therefore cannot be published before its supplied asset batch is installed. The trusted application operation must include its source references and asset content in its semantic fingerprint and validate the complete reference graph; this storage port does not infer document semantics.

After commit, retirement is best effort: failure leaves a durable stage rather than changing an already confirmed receipt. On reopen and before the next write, the owner compares every stage with SQLite receipts. A matching receipt requires full manifest/object integrity before retirement. With no matching receipt, the stage is uncommitted and its metadata may be retired even if incomplete. Reuse of an operation ID with another fingerprint does not turn an old stage into a committed stage or reserve an uncommitted ID. Object bytes survive both paths. A corrupt committed stage blocks recovery and is retained for diagnosis; recovery never rewrites immutable completed objects.

Tests cover an actual SQLite-full rollback, stable receipt replay, revision conflict before staging, different-fingerprint recovery and owner-process termination before/after commit. The postcommit interruption case recreates the exact pending preparation before terminating the owner; it proves recovery from that durable state without adding production fault switches. These checks establish process-interruption behavior and OS durability requests, not a physical power-loss certification.

## Filesystem boundary and limits

The fixed private namespace contains a marker, an exclusive `asset-store.lock`, `obj-HASH.bin`, `tmp-HASH.bin`, `stage-HASH.json` and `journal-HASH.tmp`. Unix files/directories use current-user ownership and modes 0600/0700. Windows uses the existing current-user/SYSTEM ACL provider. Symlinks/reparse points and hard links are rejected before permission mutation. The only two-link exception is the exact private Unix temporary/destination inode pair left by interrupted publication.

New data and metadata are synced before publication. Unix publishes with a no-clobber hard link, syncs the directory, removes the temporary name and syncs again. Windows uses same-directory `MoveFileExW` with `MOVEFILE_WRITE_THROUGH`, without replace/copy flags. Existing completed objects are verified and never overwritten. Only an unreferenced private temporary may be replaced. The OS releases the exclusive per-command file lock on process exit.

Limits are 64 pending stages, 256 MiB of recognized stored data/metadata and 4,354 directory entries. Metadata files are at most 64 KiB; binary files are at most 8 MiB. New preparation space is checked before its journal is installed. Unknown names and oversized entries fail closed. There is deliberately no reset/delete-object command: future garbage collection must use committed reachability and preserve in-flight preparations.

Host calls have a five-second per-command timeout and bounded stdout. Asset preparation currently uses synchronous host operations. Before exposing bulk import through the live service, move configuration authority and asset IO to a dedicated worker/child so filesystem stalls cannot starve input-owner heartbeats. Do not extend input leases or weaken expiry to hide that scheduling requirement.
