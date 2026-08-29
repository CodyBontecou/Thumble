# Phase 5 paired adoption — local acceptance

Status: **locally implemented and verified; physical iPhone-to-Mac acceptance remains pending.**

This receipt covers the explicit authority-transfer portion of hosted-builder Phase 5. It does not claim production gateway availability, universal-link acceptance on a physical device, or any Phase 6 desktop share/file UX.

## Authority boundary

A pending builder artifact remains quarantined, pre-adoption state on iPhone. The user must choose **Adopt on Paired Mac**. The iPhone sends the original validated bytes to the currently authenticated paired Mac and never mutates its authoritative profile snapshot. The Mac revalidates both the raw SHA-256 and the portable artifact semantic hash, imports with `appendAsCopies`, persists the normal authority state, publishes an authoritative profile snapshot, and then returns destination profile IDs. The phone deletes the quarantined artifact only after both a successful result and a snapshot containing every echoed destination ID.

The equivalent non-phone adoption path remains:

```sh
thumble profile import --append ARTIFACT.json
```

No new CLI operation is needed: paired-phone upload is a transport for the same explicit append-as-copies authority import.

## Protocol and limits

Capability: `profile-artifact-adoption-v1`.

Dedicated reliable messages:

1. `profile_artifact_adoption_begin`
2. `profile_artifact_adoption_chunk`
3. `profile_artifact_adoption_commit`
4. `profile_artifact_adoption_cancel`
5. `profile_artifact_adoption_result`

Limits and invariants:

- artifact maximum: 8 MiB;
- chunk size: 256 KiB, at most 32 chunks;
- one ordered reference-backed assembler per Mac server;
- 30-second upload expiry;
- authenticated current paired connection only; unpaired messages are ignored without changing the paired upload;
- intended Mac server ID is nonempty, at most 128 Unicode scalars, and contains no control characters;
- raw SHA-256 and semantic artifact hash are independently verified;
- conflict policy is fixed to `append_as_copies`;
- a commit gate prevents duplicate begins/commits from crossing the network-to-authority queue twice;
- a persisted UserDefaults ledger retains at most 64 terminal operations for seven days, replays exact metadata, and rejects operation-ID conflicts;
- successful/replayed results contain 1–256 unique destination IDs;
- quarantine metadata binds a retry operation ID to its intended Mac, so uncertain same-Mac retries remain idempotent while selecting another Mac creates a new operation.

## Failure behavior

Disconnects, malformed chunks, timeout, hash mismatch, semantic validation failure, and import failure retain the artifact for explicit retry. Interrupted `adopting` records recover as failed after app restart. A Mac disconnect/re-pair clears only the bounded upload assembler; a commit already crossing the authority queue remains protected by the commit gate and is persisted to the replay ledger. Import exceptions restore the pre-import editor snapshot.

Practice preview remains isolated and practice-only throughout. Adoption does not install locally on iPhone and successful adoption closes a matching preview only after snapshot confirmation.

## Automated evidence

The local gate is `scripts/verify-profile-artifact-adoption.sh`. It regenerates the Xcode project, runs focused codec/quarantine/pickup/practice/adoption/stack tests, builds iOS Simulator and macOS app targets, runs the stack-safety verifier, and checks CLI parity/capability contracts.

Core test coverage includes strict envelope decoding, maximum frame bounds, chunk order/size/hash/timeout/cancel behavior, full-retry begin semantics, commit-in-progress exactly-once decisions, replay/conflict/pruning/restart behavior, hostile server IDs, duplicate/oversized destination lists, result-before-snapshot and snapshot-before-result ordering, authority-bound operation retry, and quarantine deletion only after confirmed success.

## Manual acceptance still pending

- physical iPhone paired with a Mac: upload, authoritative append, snapshot confirmation, and reconnect replay;
- physical-device universal-link/AASA routing;
- production Fly deployment and visible ChatGPT developer-mode prompt-to-artifact flow.

Those pending checks prevent any production-availability claim.
