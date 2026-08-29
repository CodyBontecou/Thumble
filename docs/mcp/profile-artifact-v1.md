# Portable profile artifact v1

Thumble profile export/import uses a versioned, bounded JSON artifact that can
be built before a Mac becomes the configuration authority. The canonical
implementation is `Host/crates/thumble-core/src/profile_artifact.rs`.

## Envelope

The artifact is an additive extension of the existing keypad export envelope,
so legacy Swift readers still recognize its profile fields:

```json
{
  "schema": "com.codybontecou.pocketpad.keypad-configuration",
  "version": 4,
  "artifactVersion": 1,
  "exportedAt": 1787900000000,
  "profiles": [],
  "activeProfileID": "UUID",
  "defaultProfileID": null,
  "profileKeyBindings": {},
  "profileOutputBindings": {},
  "catalogRevision": {
    "controllerTemplates": 1,
    "deviceFrames": 1,
    "generationSpec": 1
  },
  "contentHash": {
    "algorithm": "sha256",
    "canonicalization": "rfc8785",
    "value": "64-lowercase-hex-characters"
  }
}
```

`profiles` is ordered and may contain one or multiple profiles. Profile IDs
must be UUIDs. `activeProfileID` is required and must identify an included
profile. `defaultProfileID` may be null for either one or multiple profiles;
adoption falls back to the first included profile only for that null default.
Single-profile exports most commonly use the null form when the selected
profile was not the source authority's default.

The artifact carries per-profile keyboard/output maps. Authority-global
`keyBindings` and `outputBindings` are forbidden because they are not part of a
portable profile.

## Integrity and forward compatibility

The content hash is SHA-256 over RFC 8785 canonical JSON containing all
semantic envelope fields and safe unknown extension fields. Only `exportedAt`
and `contentHash` itself are excluded. Profile order is significant.

Rust retains profiles, binding maps, and safe top-level extensions as raw JSON,
so decode/re-encode preserves future portable fields. Known binding subsets are
parsed only when validating or adopting the artifact. A hash mismatch,
unsupported artifact/catalog version, invalid profile reference, or malformed
binding map fails closed.

Checked-in cross-language vectors:

- `Host/fixtures/profile-artifact/v1.json`
- `Host/fixtures/profile-artifact/v1.canonical.json`
- `Host/fixtures/profile-artifact/v1.sha256`

## Portability boundary

Artifact v1 contains no authority credentials, server/device identity,
embedded binary data, local filesystem paths, bookmarks, or executable launch
targets. Export removes `launchTarget`; validation rejects non-null local,
binary, credential, token, URL/path, and authority fields recursively. Safe
unknown JSON is bounded by depth, key/string length, container entry counts,
and the complete 8 MiB artifact cap.

Profile-local binary asset libraries are therefore not portable in v1. Skin
packages remain a separate `.pocketpad` workflow.

## Import behavior

`thumble profile import` sends raw bounded UTF-8 JSON to the exact-sibling Rust
bridge; Swift does not decode or normalize current artifacts. Rust validates
and imports through one deterministic draft/CAS/atomic-save transaction:

- source profiles are processed in order;
- default mode matches the first unclaimed destination by UUID, then
  case-insensitive name;
- `--append` creates deterministic UUIDv5 copies and unique names;
- replacement keeps the destination UUID;
- supplied binding maps replace destination maps; absent maps preserve an
  existing destination or use canonical defaults for a new profile;
- `--no-select` preserves the active profile;
- `--default` maps the imported default, otherwise imported active/first;
- identical invocation ID + semantic artifact/options replays; changed content
  or options with the same invocation ID fails with `commit_id_conflict`.

Legacy keypad envelopes with schema versions 1–4 are upgraded to hashed artifact
v1 in Rust. Schema-less generated-profile, raw-profile, profile-array, and
customization JSON are adapted by Swift into a legacy envelope, then enter the
same Rust authority path. A current artifact carrying `artifactVersion` never
falls back after hash/version failure.

## Bounds and verification

- artifact JSON: 8 MiB maximum;
- inner CLI bridge frame: 18 MiB, newline-inclusive;
- wrapped same-user control frame: inner limit plus 4 KiB envelope headroom;
- large control frames: at most two admitted concurrently.

Run:

```bash
python3 scripts/verify-mcp-cli-parity.py
python3 scripts/verify-hosted-builder-capabilities.py
./scripts/verify-rust-host.sh
./scripts/verify-profile-artifact-flow.sh /path/to/directory-containing-thumble-and-thumble-cli-bridge
./scripts/verify-stack-safety.sh
```

The CLI-to-MCP ledger marks profile export/import `host-cli-only`: the
Rust-authoritative CLI operations are shipped, while their intended general MCP
tools have not shipped. Hosted builder artifact emission is a separate
`partial` surface in `hosted-builder-capabilities-v1.json`: implemented and
locally verified, but not production-available.
