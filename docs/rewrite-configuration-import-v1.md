# Rewrite saved-configuration import

`configuration import-file` explicitly replaces the entire saved configuration from a reviewed local owned-v5 file. It can initialize an empty authority at revision `0`. It uses the same single-writer configuration child, durable SQLite receipts and immutable asset staging as existing catalog edits. It never activates input, migrates the retained authority, changes trust, publishes phone state or grants runtime/image compatibility. This remains structural saved-data admission; full image/value/platform validation and import/export acceptance remain open.

Inspect the file first to obtain its versioned lossless source hash:

```sh
thumble-rewrite configuration validate-file --file /absolute/path/owned.json --json
thumble-rewrite configuration import-file --file /absolute/path/owned.json --operation-id import-001 --expected-revision 0 --expected-source-hash HASH --json
thumble-rewrite configuration import-status --operation-id import-001 --expected-revision 0 --expected-source-hash HASH --json
```

Add the normal explicit `--runtime-dir`/`--receiver` options when using a development installation. A running rewrite service owns the database. `import-file` returns `import-pending` immediately; poll `import-status` with the exact operation ID, revision and reviewed source hash. Final results are `import-committed`, a typed revision conflict, or `import-failed` with a bounded error code. Committed results explicitly report `validation: owned-v5-structural` and `activationCompatibility: not-evaluated`. Receipts use `affectedEntities: ["configuration"]` because the operation replaces the whole catalog, including removed profiles; it is not a one-profile merge.

MCP exposes equivalent `configuration_import_file` and `configuration_import_status` tools only when launched with `--allow-configuration-write`. File inspection remains in the default read-only tool set. Both adapters use the same strict command/result codecs. No raw source, asset bytes, paths or caller-selected receipt fingerprints enter job status. The expected source hash is a precondition from review, not a caller-selected storage fingerprint. The owner derives a versioned operation fingerprint from replacement scope, expected revision and reviewed hash, then independently rereads the safe regular file and checks its actual source hash before preparing any first commit. The file reader retains its 8 MiB, descriptor identity, symlink and changed-file checks.

Imported stable IDs, active/default selection, bindings, eight appearance states and opaque number lexemes are retained through the existing owned-v5 reader and stored authority representation. Asset references are staged/published before the matching SQLite configuration/receipt transaction. The imported source's hash differs from the resulting private stored-wrapper hash; the receipt identifies the stored authority. Resource encoding may canonicalize during materialization, while opaque values and exact number lexemes are preserved.

## Responsiveness and recovery

The parent admits at most one bulk job. It caches at most 32 bounded job results, bound to exact intent. Concurrent duplicate starts share the same job; conflicting use of its operation ID fails. Other child-bound configuration requests return `configuration_owner_busy` while import runs. Polling reads parent-owned bounded state, so file parsing and filesystem/SQLite work stay entirely in the child and cannot delay parent input renewal.

The ordinary private request budget remains two seconds, client request budget three seconds, native owner lease 750 ms and input TTL 350 ms. Only the background import request has a 30-second budget. Expiry or malformed child replies fail closed and terminate that configuration child; service supervision and independent receiver expiry retain their normal behavior. A failed response does not prove that a commit did not happen. Resubmit the original operation ID, expected revision and reviewed hash to recover a matching durable receipt. Receipt lookup precedes rereading the file, so successful retries work after its file is removed or relocated. Changing payload under a committed operation ID is rejected.

The result cache is ephemeral. If a service restarts or retires an old cached result, `import-status` returns `configuration_import_unknown`; resubmit `import-file` with the original intent to recover its receipt. A failed uncommitted job can be retried with the same intent after repairing local file availability. Paths are locators, not intent identity, so a byte-equivalent reviewed file can move without changing the durable operation.
