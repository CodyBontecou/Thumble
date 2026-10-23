# Phone editor DTO codec prerequisite

This slice defines a pure, unregistered codec and shared synthetic vectors. It
does not register a TLS role, enable a write, allocate a worker, access storage,
change trust, activate input or add a generic configuration-command tunnel.
Existing roles 7, 8, 10 and 11 are unchanged. The native integration test imports
the module by path; the production library does not register it.

All requests and replies contain `version: 1`, a lowercase 32-hex `connectionId`
and lowercase UUID `authorityInstanceId`, both matched against the authenticated
context supplied by the future caller. These fields are correlation checks, not
authentication provided by this codec. Commands have exact keys:

- `editor-profile`: `expectedRevision`, `expectedSourceHash`, `profileId`,
  `offset` (integer 0–120, in steps of eight).
- `configuration-set-control-label`: existing `operationId`, `expectedRevision`,
  `profileId`, `controlId`, `label` fields.
- `editor-label-status`: `intent`, containing exactly the existing label command
  and its five intent fields, without the phone header.

Counters are canonical decimal UInt64 strings; profile/control UUIDs are
lowercase canonical strings. Operation IDs contain 1–64 ASCII letters, digits or
hyphens. Labels preserve exact Unicode, whitespace and explicit empty strings,
with at most 128 UTF-8 bytes. JSON null clears an override. Invalid UTF-8 and
unpaired JSON surrogate escapes reject. No normalization or truncation occurs.

Responses use the exact request command plus `-result`. The profile result
contains the published host page DTO: exact revision/source/profile/offset echo,
name, total count, next offset and zero to eight controls. Controls contain only
ID, generated label and nullable override. The total is at most 128; the page
count and continuation are exact. Names contain at most 256 Unicode scalars and
1024 UTF-8 bytes and cannot be entirely ECMAScript whitespace. Opaque source,
assets, paths, output bindings, runtime generation and private owner correlation
fields are rejected rather than projected.

A write may return `editor-label-admitted` plus its exact operation ID only after
the future native bridge strongly retains and dispatches the exact owner request.
This codec cannot establish that condition. A definitive result may instead be
`committed` with the existing receipt and replay flag, or an explicit conflict.
Status returns `editor-label-pending` or `editor-label-receipt`. Admitted,
unavailable and pending are never proof of commit or known no-op; the original
journal intent must remain available for reconciliation. A receipt must match
the operation, exact expected revision plus one, SHA-256 and affected IDs in
profile/control order. UInt64 overflow cannot form a valid receipt.

Only these error codes are accepted: `editor_busy`, `editor_unavailable`,
`editor_invalid_request`, `editor_access_denied`, `editor_operation_reused`,
`editor_profile_not_found`, `editor_control_not_found`, `editor_source_changed`,
`editor_unsupported_profile` and `editor_response_too_large`. An error does not
establish a durable outcome. Arbitrary exception messages are rejected.

Requests are capped at 2048 bytes; complete replies including authentication
correlation headers are capped at 16384 bytes. Parsing rejects recursive duplicate
keys before conversion to JSON values, unknown fields at every typed layer,
floats, excessive depth (over four), over 128 nodes, arrays over eight entries
and oversized strings/keys. Bounds and validation run before any future
admission; malformed or oversized input must never reach a write dispatcher.

`Rewrite/packages/fixtures/phone-editor-control-v1.json` contains positive
request/reply pairs and raw hostile JSON strings reusable by native Swift and
Kotlin codecs. Its scope explicitly excludes role/write enablement. Tests cover
all three commands, all fixed errors, blank/clear/128-byte Unicode, UInt64
extrema, recursive duplicates, mismatched headers and pins, exact receipts,
private-field injection and the worst escaped eight-control page including its
full header. No SDK fixture generator is changed in this slice.

Run the portable prerequisite with:

```sh
cargo +1.88.0 test --locked --manifest-path Rewrite/native/receiver/Cargo.toml --test editor_codec
cargo +1.88.0 test --release --locked --manifest-path Rewrite/native/receiver/Cargo.toml --test editor_codec
cargo +1.88.0 clippy --locked --manifest-path Rewrite/native/receiver/Cargo.toml --test editor_codec -- -D warnings
```

Future role registration still requires retained owner dispatch, definitive
completion versus transport-loss handling, revocation/drain ordering, journal
reconciliation, SDK validation and cross-layer acceptance. This codec proves
none of those lifecycle or authorization gates.
