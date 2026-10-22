# Revisioned saved-profile selection v1

`configuration select-profiles` atomically changes the saved active and default
profile selectors and synchronizes the selected profile's saved binding mirrors. It does not publish a runtime configuration, change an input
session, enable receiver input, or establish activation compatibility. Existing
owned-v5 structural and activation acceptance gates remain separate.

The command requires **both** selectors explicitly. Read `configuration list`
first, preserve the selector you do not intend to change, and use that catalog's
revision as the compare-and-swap precondition. A null default is supported; the
active selector must name an existing profile.

```sh
thumble-rewrite configuration select-profiles \
  --runtime-dir /absolute/runtime --receiver /absolute/thumble-rewrite-receiver \
  --operation-id selection-1 --expected-revision 7 \
  --active-profile-id aaaaaaaa-0000-0000-0000-000000000001 \
  --default-profile-id bbbbbbbb-0000-0000-0000-000000000002 --json

# Clear only the saved default while explicitly retaining the active selector.
thumble-rewrite configuration select-profiles \
  --runtime-dir /absolute/runtime --receiver /absolute/thumble-rewrite-receiver \
  --operation-id selection-2 --expected-revision 8 \
  --active-profile-id aaaaaaaa-0000-0000-0000-000000000001 \
  --default-profile-id none --json
```

The equivalent MCP tool is `configuration_select_profiles`, available only when
the launching user supplies `--allow-configuration-write`. Its strict arguments
are `operationId`, `expectedRevision`, `activeProfileId`, and `defaultProfileId`.
Use JSON null to clear the default. Both modern and legacy MCP protocols use the
same contract, capability guard, service authority, and durable receipts.

IDs use case-insensitive UUID lookup. Command identity normalizes UUID case for
retry equivalence, while changed source selectors reuse the selected profile's
exact stored ID spelling and escaping. Neither profile records nor their
IDs/timestamps are rewritten. Selection additionally updates the known root
`keyBindings` and `outputBindings` mirrors and the selected entries in
`profileKeyBindings` and `profileOutputBindings`. All unrelated per-profile map
entries, opaque members, saved states, appearance data, external resource
references, and authority resource manifests are preserved. JSON container
whitespace may normalize during the lossless source edit.

The key and output maps resolve independently. A present selected per-profile
entry, including an empty or sparse map, wins verbatim with its unknown source
members intact. A missing key map falls back to keyboard bindings projected from
that selected profile's initial primary outputs; a missing output map falls back
to those initial outputs. Each control's configured `output` overrides its
`defaultOutput`, including explicitly empty configured output; absent/null
configured output uses its default. Keyboard sequences use their effective first
stroke and retain multi-stroke sequence data. Text/decoration configured outputs
follow retained normalization. Fallback does not filter by output mode, merge
part outputs, inspect labels, borrow prior root mirrors or another profile, or
derive a missing key map from a stored output map.

Only absent selected entries are installed from fallback. The selected profile's
map-key case alias is normalized to its exact stored profile ID, without changing
any unrelated map entry. The chosen maps are copied to the root mirrors even
when the selected active ID is unchanged. This combined command always performs
an explicit active selection before setting the default; a separate default-only
command is not part of this seam. Missing canonical control declarations,
ambiguous profile-map aliases, or bindings to undeclared selected controls fail
closed before commit. Verification uses the same structural selected-control
reader as owned-v5 admission, without reading or materializing resource files.
Canonical owned-v5 explicitly rejects retired `landscapeCustomization` and
`portraitCustomization` fields before this phase; the fallback therefore uses
its canonical primary layout, rather than silently dropping accepted secondary
layouts. This agrees with retained owned-v5 admission. Legacy alternate-layout
inventory/migration remains separate work and is not enabled by this operation.
This is saved-data consistency, not a full activation validator.

The sole configuration child derives the payload fingerprint from the scoped
command and commits through the existing SQLite authority. Named profiles must
exist before a new receipt can be written. Capability denial precedes reads or
writes. A stale expected revision returns a typed conflict; missing profile IDs
fail without a commit. Selecting an uninitialized authority cannot seed it.

A successful result is the existing `committed` reply with a durable operation
receipt, one resulting revision, content hash, and
`affectedEntities: ["configuration"]`, because the edit affects root selectors
rather than profile contents. Even unchanged selectors persist one receipt and
revision; that operation can repair missing maps or stale binding mirrors. An
already-consistent selection retains the source content hash. Selection never consults a wall clock or changes profile timestamps.

Retry the same operation ID and complete intent to recover the original receipt,
including after restart or intervening edits. Receipt replay precedes current
source decoding and CAS. Reusing an already committed ID with another revision,
active selector, or default selector is rejected. Import/export jobs retain
exclusive child IO; selection returns `configuration_owner_busy` while one of
those bounded background jobs runs. Native input leases and ordinary request
deadlines are unchanged.

Focused domain/application tests verify named-profile checks, selected mirror
synchronization, case-preserving ID selection, opaque data/resources, no clock access,
capability/CAS failures, no-op receipts, restart replay, and payload binding.
Disjoint-control fixtures reproduce selector-only read/materialization/export
failure, then verify repaired selection through export and re-import. Same-active
repair, independent empty/missing maps, configured/default/sequence precedence,
and unsupported metadata-only sources are covered. Independent Node MCP SDK
probes race CLI and MCP submissions for one operation,
exercise default clearing and stale/missing/reused operations, and recover the
original receipt after service restart. The same probes run against copied
standalone binaries with a restricted product PATH and assert receiver input
stays disabled throughout.
