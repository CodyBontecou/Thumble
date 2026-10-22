# Revisioned saved-profile duplication v1

`configuration duplicate-profile` clones one explicit saved profile into a
caller-selected fresh UUID and name. Both API and CLI require an explicit
selection choice. The operation commits the copy, its known binding maps, and
any requested saved selection as one revision and durable receipt.

```sh
# Keep the current saved active/default selection and root binding mirrors.
thumble-rewrite configuration duplicate-profile \
  --runtime-dir /absolute/runtime --receiver /absolute/thumble-rewrite-receiver \
  --operation-id copy-1 --expected-revision 7 \
  --profile-id aaaaaaaa-0000-0000-0000-000000000001 \
  --new-profile-id f0000000-0000-0000-0000-000000000001 \
  --name 'Controller copy' --keep-selection --json

# Select the copy and synchronize its saved active binding mirrors atomically.
thumble-rewrite configuration duplicate-profile \
  --runtime-dir /absolute/runtime --receiver /absolute/thumble-rewrite-receiver \
  --operation-id copy-2 --expected-revision 8 \
  --profile-id aaaaaaaa-0000-0000-0000-000000000001 \
  --new-profile-id f0000000-0000-0000-0000-000000000002 \
  --name 'Selected copy' --select --json
```

Supply exactly one of `--select` and `--keep-selection`; omission or both flags
are rejected. The MCP equivalent is `configuration_duplicate_profile`, exposed
only with the launching user's `--allow-configuration-write`. Strict arguments
are `operationId`, `expectedRevision`, `profileId`, `newProfileId`, `name`, and a
required boolean `select`. Both modern and legacy MCP eras use the same owner,
contract, capability guard, and receipts.

The new UUID must not match any existing profile, including the source, under
case-insensitive lookup. The source must exist. UUID command identity and the
new stored ID are canonical lowercase. New names are trimmed and validated using
the existing bounded Unicode profile-name contract. Only the cloned record's
`id`, `name`, and `updatedAt` change; its fresh timestamp comes from the trusted
bounded host clock. The source record's timestamp and all existing profiles are
unchanged. Durably replaying an operation never consults that clock again.

## Clone semantics and source preservation

The retained bridge's `profileDuplicate` copies the complete raw source record,
changes those three metadata fields, and clones or installs the two known
per-profile binding maps. This implementation preserves that data behavior and
makes its formerly implicit selection explicit through `select`.

Internal element/control IDs are unique within their owning profile. They,
design/group IDs, appearance-control IDs, all eight saved appearance states,
labels, geometry, outputs, haptics, resource references, and opaque future
metadata are copied as saved. Duplicate profiles may therefore share the same
control IDs in different profile scopes. UUID-looking values and paths inside
opaque metadata are never blanket rewritten or inferred to be profile links.

The only known root per-profile binding maps are `profileKeyBindings` and
`profileOutputBindings`. Each resolves independently for the source UUID,
case-insensitively. A present sparse or empty source entry is copied verbatim,
including unknown members. A missing entry uses the same verified primary-control
initial-output fallback as saved active selection. Configured outputs override
defaults, including explicit empty outputs; keyboard fallback is independent
from stored output maps. No prior root or another profile supplies a fallback.
Source aliases and unrelated map entries remain unchanged. Opaque root extension
maps are retained without guessing that they should be cloned.

With `select: false`, `activeProfileID`, `defaultProfileID`, `keyBindings`, and
`outputBindings` remain exact source values. With `select: true`, the copy becomes
the saved active profile, and its cloned maps supply the saved root mirrors in
the same transaction. The saved default remains unchanged in both modes. This
never publishes runtime configuration, enables receiver input, or establishes
activation compatibility.

Inline saved documents retain complete profile data. Canonical authority
profiles reuse immutable asset hashes/files. Every resource descriptor belonging
to the exact source-profile index gains a corresponding descriptor at the new
profile's appended index. Existing descriptor source and numeric lexemes remain
intact, resource paths remain sorted, and their alias coverage is validated by
the authority reader. No asset bytes are copied, changed, or read by duplication.
Container whitespace may normalize; this operation is not a byte archive.

Canonical v5 continues rejecting retired secondary-layout aliases. Legacy
alternate-layout migration and full image/value/platform/runtime validation
remain separate gates. Metadata-only records without safely decoded canonical
controls cannot be duplicated.

## Transactions, bounds, and retry

The sole configuration child derives the operation fingerprint from the scoped
command, normalized UUIDs/name, expected revision, and explicit selection choice.
The generic source-commit/fingerprint ports are not exposed to CLI/MCP.
Capabilities and compare-and-swap are checked before mutation. Stale revisions
return a typed conflict. Unknown sources, existing new IDs, invalid clocks or
names, malformed controls/maps, or exceeded bounds fail before committing.

Existing limits remain unchanged: at most 256 saved profiles, an 8 MiB source
and materialized export document, bounded resource slots, and the existing
unique-asset/graph/control limits. Shared assets still count toward the projected
materialized size at each reference; sharing cannot amplify a small authority
into an oversized exported document. Failed candidates leave authority and
receipts unchanged.

Success returns `committed` with a durable receipt containing the new revision,
content hash, and `affectedEntities: ["configuration", "<new profile UUID>"]`.
Retrying the same ID and complete intent returns the original receipt before
current-source decoding, CAS, or clock access, including after intervening edits
and restart. It never creates a second copy. Changing the source, new UUID,
normalized name, expected revision, or selection choice under a committed ID is
rejected. A fresh operation targeting an existing UUID is refused rather than
replacing its profile. Input leases and normal request deadlines are unchanged;
selection/import/export owner exclusion remains in force.

Focused tests exercise both selection modes and stored/fallback maps with rich
owned resources, exact opaque/numeric preservation, unchanged asset files,
manifest aliasing and multi-digit indices, profile/document/materialized-size
bounds, capabilities/CAS/clock/collision failures, and durable retry after restart.
Independent Node MCP SDK probes race the CLI for both modes in modern and legacy
protocols, require explicit selection, recover receipts after restart, and verify
the exported copies retain their source's supported state. The same probes run
against copied standalone binaries with a restricted product PATH and confirm
receiver input remains disabled.
