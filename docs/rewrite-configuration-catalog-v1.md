# Rewrite configuration catalog operations v1

The rewrite service exposes bounded saved-profile metadata reads and one scoped rename operation over its protected SQLite ledger. CLI and MCP share the same application operation, expected-revision checks and durable receipt. The existing lossless version-5 catalog reader validates identities, selections, names and timestamps; it does not validate layout, bindings, resources or runtime semantics. No raw-source write, import, migration, format activation or receiver publication is exposed by these operations.

## Local commands

Run the rewrite service first. `configuration list --json` returns a version-1 `catalog` result: revision, source content hash, active/default saved identities, up to sixteen profile summaries and a nullable next offset. An uninitialized ledger reports revision `0`, null hash/selections and no profiles. Further pages require both `--offset` and `--expected-revision` from the first response. A changed revision returns a typed `conflict` result with `currentRevision`; clients must restart their read against that revision.

`configuration rename-profile --profile-id UUID --name NAME --operation-id ID --expected-revision REVISION --json` renames only that stable profile ID. UUID matching is case insensitive. Names retain their supplied spelling, contain 1–256 Unicode scalar values, must not be all whitespace and cannot contain lone surrogates. The owner updates the profile timestamp to the larger of its existing exact Int64 timestamp and the validated host clock. Active/default selection and unrelated profile/extension/binding/resource source values remain untouched, including numeric lexemes beyond JavaScript number precision.

A write returns `kind: committed`, `replayed`, and a receipt identifying the operation, resulting revision, source content hash and affected profile. An expected-revision mismatch returns `kind: conflict`; this is a typed operation outcome inside the successful transport envelope, not a committed receipt. CLI consumers must inspect `kind`. Missing profiles, invalid catalogs, reused IDs with different payloads and unavailable service/storage return bounded error codes.

An empty ledger cannot be seeded by rename. There is deliberately no catalog-only initialization/import operation: complete owned-document admission, migration and asset validation still need implementation. Integration tests install an explicitly synthetic internal fixture through the trusted repository port before starting the service. That fixture's opaque customization is intentionally unsuitable for runtime activation, proving metadata edits do not accidentally grant activation validity.

## MCP and authority

`configuration_list` accepts `{expectedRevision: string | null, offset: number}`. `configuration_rename_profile` accepts `{operationId, expectedRevision, profileId, name}` only when the user launches MCP with `--allow-configuration-write`. The write tool is absent and denied before SDK dispatch otherwise. Recording-input capability is independent; configuration permission does not expose input tools. No command can supply capabilities, replacement source, timestamp or a payload hash.

The authenticated same-user local service token admits local catalog operations. The service supplies application capabilities, SHA-256 and the clock. The portable application uses only contracts/domain/repository ports; the dependency checker now permits application → domain while continuing to reject reverse/platform imports.

The fingerprint is SHA-256 of the UTF-8 JSON tuple `["thumble-catalog-operation-v1", command, expectedRevision, canonicalLowercaseProfileID, exactName]`. Tuple order and namespace are fixed. The server-generated clock and current source are excluded. Authorization is checked before receipt lookup. A matching retry returns the original receipt before reading the current source or clock, including after subsequent edits and service/database restarts. The same ID with changed expected revision, identity or name is refused. Same-name operations preserve the original source bytes and still advance the ledger revision and persist a receipt. No-op writes therefore have the same durable retry contract as changed writes.

## Verification and remaining work

Tests use the real native file protector and SQLite adapter, exact source comparisons, stale-revision conflicts, capability denial, replay after reopen, same-name receipts and invalid command/response rejection. A sixteen-profile worst-case escaped-name page is sent through the actual bounded MCP transport, including both text and structured result encodings. Independent Node SDK clients exercise modern and legacy MCP against the running service, race equivalent CLI/MCP writes and verify one commit plus one replay. Source and standalone packaging tests cover both facades; service restart preserves the catalog and earlier receipts.

This implements the metadata transaction seam only. Full owned-document validation, profile creation/deletion/duplication, bindings/geometry/appearance/assets/haptics, typed import/export, undo, phone journals/conflict reconciliation, stopped-service edit startup and acknowledged runtime publication remain M4 work. The retained authority is not migrated and the desktop cutover gates remain open.
