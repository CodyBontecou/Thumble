# Headless saved-configuration export v1

This seam exports the **entire saved configuration** as a standalone owned-v5
JSON file. It includes every saved profile, saved state, binding, resource,
active/default selection, and opaque field retained by the owned-v5 codec.
External resources are read through the immutable native asset store, checked
against their declared sizes and SHA-256 digests, and materialized as inline
base64. Existing pooled resource aliases remain aliases to the included pool.
Numeric lexemes, including integers beyond JavaScript's exact-number range,
remain lossless. JSON container whitespace and replaced resource-string escapes
can normalize; this is not an archive of the original import file's exact bytes.
Host identity, pairing/control credentials, trust records, and input sessions
live outside this configuration document and are not exported.

Export neither changes the saved authority revision nor publishes or activates
runtime output. The current structural owned-v5 codec remains the admission
boundary; export does not claim image, value-semantic, platform, or runtime
compatibility. Those acceptance gates remain open.

## Review, start, and poll

Run a normal local service first. `configuration list --json` supplies the
current revision and `contentHash`. For export, `--expected-source-hash` means
**that authority content hash**, not the hash returned by `validate-file` for an
unimported file. The authority envelope includes external asset references, so
its hash can differ from a materialized standalone document's hash.

```sh
thumble-rewrite configuration export-file --runtime-dir /absolute/runtime \
  --receiver /absolute/thumble-rewrite-receiver \
  --file /absolute/owned-output/saved.json \
  --operation-id export-review-1 --expected-revision 7 \
  --expected-source-hash AUTHORITY_CONTENT_HASH --json

thumble-rewrite configuration export-status --runtime-dir /absolute/runtime \
  --receiver /absolute/thumble-rewrite-receiver \
  --file /absolute/owned-output/saved.json \
  --operation-id export-review-1 --expected-revision 7 \
  --expected-source-hash AUTHORITY_CONTENT_HASH --json
```

Start returns `export-pending` immediately. Poll returns pending, `export-failed`
with a bounded error code, `conflict` with the actual revision, or `exported`:

```json
{
  "version": 1,
  "kind": "exported",
  "operationId": "export-review-1",
  "revision": "7",
  "sourceHash": "<reviewed authority SHA-256>",
  "artifactHash": "<SHA-256 of exact output-file bytes>",
  "byteCount": 12345,
  "replayed": false
}
```

The result contains no path, raw source, asset bytes, or credential. A revision
mismatch returns conflict before materialization or output IO; a hash mismatch
fails before output publication. The child rechecks the actual authority source
hash against the reviewed hash. No historical revision is silently substituted.

Both MCP protocol eras expose `configuration_export_file` and
`configuration_export_status` only with the launching user's
`--allow-configuration-write` flag. Writing an explicit user-selected local path
requires this capability even though export is read-only for saved authority.
Both tools require `operationId`, `expectedRevision`, `expectedSourceHash`, and
`path`. The destination is part of intent identity; status includes it only in
its request, never its result. Default MCP sessions expose neither tool.

## File publication and ownership

The native helper accepts an explicit absolute destination in an existing,
current-user-owned directory. It does not create or protect that directory.
Directory components cannot be symlinks or Windows reparse points. Unix output
directories must not be writable by group or other users; directory-relative
file descriptors anchor file creation and no-clobber publication. Windows holds
directory-component handles without delete sharing, checks the destination
owner, and refuses alternate streams, device names, and trailing-dot/space names.
An output directory inside an existing private user directory is suitable.

New files are written to a random exclusive sibling, protected to user-only
Unix permissions or user/SYSTEM Windows ACLs before data is written, and flushed
before publication. macOS/Linux use directory-relative exclusive rename and directory fsync;
Windows uses `MoveFileExW` with write-through and without replacement/copy flags.
Readers see a complete file at the final name, never a partially written file.
The standalone CLI retains its native sibling for this operation.

An existing regular, current-user-owned, single-link file is accepted only when
its bytes equal the proposed output exactly. This returns `replayed: true`
without changing its contents or permissions. Any other existing file is
refused. Symlinks, reparse points, directories, hard-linked files, malformed
UTF-8, and input larger than the unchanged 8 MiB document limit are refused.
Normal failure removes the temporary sibling. Process termination can leave a
private `.thumble-export-*` sibling; it is never treated as a completed export
and can be removed by its owner. The final destination is never overwritten.

## Jobs, deadlines, and retries

Import and export share one child-IO job at a time and a parent cache of at most
32 results. Operation IDs bind the complete operation kind and intent before
dispatch. Duplicate pending starts share work; a changed destination, revision,
hash, or operation kind under the same cached ID is rejected. Other child-bound
configuration operations return `configuration_owner_busy` while a bulk job
runs. Parent-local polling and input heartbeat IO remain responsive.

Bulk requests have a private 30-second owner deadline. The normal 2-second native
pipe budget, 3-second local-client deadline, 350 ms input TTL, and 750 ms owner
lease are unchanged. Unknown/malformed child replies or lost-owner deadlines
terminate the poisoned owner and fail closed. A later export start can verify an
already-published artifact safely.

Export job IDs and statuses are **ephemeral service-session records**. They are
not durable configuration mutation receipts. After restart or cache eviction,
resubmit the same intent. The owner reconstructs the same current pinned source
and verifies the destination bytes; an identical artifact returns replayed.
If authority advanced, export returns conflict and leaves the existing output
untouched. A new start after a previous completed export always rechecks the
current authority and file; cached success cannot hide file deletion or changes.
There is no historical export replay guarantee. Import's durable mutation
receipts remain unchanged.

## Verification

Focused native process tests cover complete/private output, exact-byte replay,
refusal without clobbering, malformed/link targets, concurrent publication, and
the full 8 MiB limit. Windows additionally exercises junctions, alternate streams,
and reserved destination names on GitHub Actions. Application/owner tests cover
resource reconstruction, lossless opaque numbers, legacy inline documents,
capability/CAS/hash rejection before IO, missing/corrupt assets, cross-operation
exclusion, responsive start/poll beyond the ordinary child deadline, file
reverification, restart replay, and changed-authority conflict. Independent Node
MCP SDK tests exercise modern and legacy protocols alongside the CLI in source
and copied standalone-package executions with a restricted product PATH.
