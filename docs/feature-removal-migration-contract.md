# Feature removal migration contract

Implementation target for the plan in feature-removal-plan.md. Frozen source fixtures live in Host/fixtures/feature-removal/v1. The current configuration export is version 4; reserve version 5 for the final single-layout, package-independent format. Keep version 4 readable through an explicit legacy import path. Do not emit version 5 until the Mac, CLI, Rust authority, and retained phone clients can handle it.

## Conversion result

A conversion returns a new document, a versioned migration receipt, and any review/recovery items. It leaves its input untouched. The receipt records the original document digest, destination digest, migration version, source/destination profile IDs, and issues. It must not contain pairing credentials. A repeat with the same input and version yields the same document and receipt; do not inject wall-clock timestamps into deterministic conversion.

The destination has one landscape layout per profile and profile-owned appearance resources. Preserve profile and element identities, input parts, keyboard sequences, controller outputs, analog/pointer settings, names, active/default selection, launch targets, addon metadata, haptic configuration, styles, asset bytes, layers, group membership, and unknown fields. Preserve existing offline edits and their trusted-host identity until reconciliation is complete.

## Appearance conversion

Resolve through the pre-removal cascade before deleting package lookup. Enumerate light/dark and Base/LT/RT/LT+RT. Retain normal, pressed, active, and disabled control styling through the ordinary design model. Store scheme/action differences as profile-owned appearance data that contains no package identifier, package path, compatibility rule, or update subscription.

Edits to retained appearance must affect the rendered result immediately. Do not add a hidden overlay that permanently overrides the user's later edits. Keep state-specific appearance separate from control geometry and outputs. Any new aggregate model storage must preserve the existing inline-size limits and COW/immutable ownership rules.

Copy all required resources into the destination before dropping the skin reference and baselines. Verify both declared references and data-bearing image/icon fills. If a package is missing, mismatched, corrupt, or cannot provide a required resource, return recovery-required with the original profile preserved. Current detach-without-package fallback is not an acceptable migration.

### Native preparation representation

`GamepadAppearanceBank` currently provides the native staging representation: exactly eight scheme/action variants, a light/Base edit reference, consistent control identities, and validated resource references. `GamepadConfigurationProfile.appearanceBank` participates in native Codable/equality and landscape resolution. Typed three-way comparison applies subsequent ordinary edits without serializing JSON on the input/render path. State/content/pointing properties merge independently; style, asset and artwork entries match by identity. A new reusable-style selection discards unchanged inherited inline paint, while direct fill/icon overrides remain visible.

Phone geometry editing canonicalizes appearance before recording entry, undo, committed and offline snapshots. A rendered dark or held-trigger canvas must never become a new immutable appearance reference merely because a control moved or was restored by Undo.

Native profile encoding now uses `appearanceResourceVersion: 1` and a profile-level `appearanceResources` map from SHA-256 to canonical Base64. Binary fields contain exactly `{"resourceSHA256":"<digest>"}`; canonical layout and all states share those bytes. Native decoding returns shared COW Data, and the Rust/Android preparation readers use the same fixture. This context is separate from the bank schema; standalone snapshots/banks keep their expanded codecs. Launch metadata is pooled too: after removing local-only fields for portable export, prune unreachable blobs while preserving references from unknown metadata. See Host/fixtures/profile-resources/README.md.

Android now has a package-independent worker resolver for this bank representation. It validates the complete finite state set, canonical control IDs, appearance-only owners and available asset references; it applies three-way appearance edits while retaining canonical geometry/output data. Binary expansion is render-only: detached containers share one immutable Base64 string per resource, while saved profiles and phone geometry journals retain compact references. Explicit scheme/action requests are tested through the display repository. Android now prepares the four action frames for the selected scheme on a worker. The controller mirrors actual declared digital trigger outputs by element/part/press identity and analog trigger values strictly above 0.5; it swaps prepared paint while keeping canonical hit geometry, child views and gesture owners. Focus loss, cancel and profile/revision replacement reset that mirror. It never uses legends, default bindings or display hints to choose outputs, and transport callbacks run before display updates. API 26 native tests verify overlapping holds and releases, accessibility, state-specific asset aliases and stable view identities. Version-5 negotiation, authority migration and broader physical-device acceptance are still required before activation. Android's geometry-only editor already applies patches to canonical snapshots, and its undo/cancel/offline tests cover the new owned-resource profiles.

Rust now also has a package-independent owned-appearance resolver in `thumble-core::ProfileAppearanceBank`. It validates the complete finite state set, canonical control IDs, appearance owner allowlists, collection identity and pooled/inline resource references. Preparation applies the native three-way edit policy while preserving executable fields, geometry and opaque layout metadata; resources stay compact and binary lookups share immutable buffers. Its iterative compact-JSON byte counter enforces the existing per-document bound without serializing another complete image-bearing document. Shared native edit oracles cover 21 edits across all eight states and are consumed by Swift, Rust and Android. Native palette conversion permits only the documented `2e-7` normalized-color-channel tolerance; IDs, structure, assets, geometry and other values remain exact. Android also follows native artwork ordering and omits default bar paint when capturing comparison snapshots. See `Host/fixtures/appearance-edits/README.md`.

This is not an activated upgrade path. Version-4 native configuration import/export and the current Rust authority reject non-null banks; the authority also rejects resource markers on their own. Before accepting a bank into live authority, integrate the retained peers and version-5 capability handshake, preserve raw unknown metadata, enforce resource/document bounds across full configurations and pending phone edits, and complete the backup/compare-and-swap recovery transaction below. Do not advertise version 5 or enable automatic migration merely because native profile roundtrips pass.

## Layout conversion

Prefer an explicit landscape variant, then an existing landscape base layout. If only portrait exists, convert deterministically into the supported landscape canvas with unchanged control IDs, bindings, appearance, and groups; include a review item for manual inspection. Keep the exact portrait original in the backup. Geometry conversion must preserve all controls even when layout-quality warnings remain.

Reconcile pending edits in their source coordinate system first. Edits for a different or unknown Mac remain recoverable and must not be uploaded to the current host. Do not reinterpret portrait coordinates as landscape, drop pending edits because their orientation is retired, or apply edits twice after an interrupted migration.

## Persistence and recovery

1. Read and validate the source through its current authority and revision. Capture a complete backup of the original document and required resources before mutation. Keep credential storage separate.
2. Produce the new document/resources in a private staging location. Validate retained semantics, asset completeness, bounds, and the destination codec. Write the receipt only after destination validation.
3. Commit using the existing host/native compare-and-swap and atomic storage boundaries. Publish to the phone only after a successful authority commit. A changed revision requires rebuilding from the new authoritative source.
4. Mark the migration complete only when the committed digest matches the validated destination. On startup, inspect the receipt and committed data to finish or roll back an interrupted transaction; the mere presence of a staging file is not success.
5. Preserve the original backup and unresolved profiles for explicit recovery. Rollback restores document and resources together and clears the committed migration marker. Never overwrite a backup with an already migrated snapshot.

Tests must cover interruption before backup completion, after staging, before commit, and after commit but before receipt acknowledgement; concurrent edits; corrupt/missing resources; repeat invocation; and rollback. These checks belong to the real persistence/authority integration, beyond a pure-transform unit test.

## Protocol and compatibility

Keep pairing and real-time input protocol identities unchanged. Remove active advertisements for skin and orientation mutation when their product surfaces are gone. Unsupported legacy mutations return a clear error without profile changes. Retain only bounded decoding/conversion for old exports and supported upgrades; do not keep a user-accessible legacy feature mode.

Old phones that cannot represent the new appearance/layout contract must receive an explicit update-required result rather than an incomplete profile snapshot. Test this handshake alongside paired configuration synchronization. Ordinary local profile import/export, on-phone edits, and local CLI/MCP transactions remain supported independently of hosted artifact transport. Legacy hosted adoption wire identifiers remain reserved for decoding and explicit nonmutating retirement errors. They are no longer advertised. Existing bounded Rust receipt data and obsolete Mac defaults bytes are preserved without new writes or pruning; neither is used to replay an adoption.

## Verification boundary

The frozen appearance, legacy-profile, and pending-edit fixtures establish pre-removal behavior. The action-set fixture specifies eight scheme/trigger combinations. Migration-case inputs include missing-package recovery, a portrait-only profile, a plain profile, and unknown profile metadata. Their expected dispositions are requirements for the forthcoming migration, not claims that conversion is already implemented.

Completion also requires native rendering review, physical haptic evidence, same-condition input latency comparison, retained WoW exporter/importer tests, meaningful live WoW acceptance where available, and the required stack-safety gate. Record unavailable device/client evidence as outstanding.

## Profile-format negotiation preparation

`Host/fixtures/profile-formats/v1.json` defines the independent format offer and header checks consumed by Swift, Rust and Android. Reliable pairing sends `supportedProfileFormats`; profile snapshots send `profileFormatVersion`. Missing offers mean format 4. Offers are bounded to eight unique integers in 1...65535; the catalog's required version must be explicitly offered. These fields are optional JSON metadata, rather than new enum capabilities that old clients could fail to decode. Metadata-bearing frames cannot silently enter a compact codec that would discard these fields. Ordinary protocol-3 button frames remain unchanged.

Current phones advertise only `[4]`. A non-null bank/resource envelope requires reserved format 5 even if a frame claims 4; incompatible data is rejected before applying or saving a snapshot. Explicit unsupported stored profile versions fail before ordinary decoding can normalize the source. Mac/Rust receivers gate profile delivery before trust or snapshot generation; Rust also releases held inputs and retires the active session when an installed catalog becomes incompatible. The post-validation transition test deliberately bypasses the current authority gate to test this release behavior. It does not prove format-5 interchange or migration acceptance.

Activation still requires format-5 codecs, complete configuration and pending-edit/resource bounds, retained-peer integration, and the backed-up transactional migration described above. Existing unmarked owned banks are staging/test data; the version-4 authority gate remains closed.

## Pending owned-layout recovery preparation

Phone layout journals now optionally retain a local `recoveryProfile` snapshot for owned appearance profiles. Immutable native storage and Android compact JSON preserve the bank and resources independently of a subsequent authority snapshot. If the matching trusted authority no longer contains the profile, reconciliation starts with that recovery snapshot and applies the pending layout in its original orientation. A different/unknown host does not authorize recovery or upload. A recovery snapshot with another profile ID is rejected without consuming the stored record. Existing journal records without a recovery snapshot keep their legacy behavior. Android merges validated resource blobs referenced by pending layouts into replacement owned tables and prunes unreachable bytes; applying against an explicitly legacy profile expands only the layout references without adding an owned bank. Native recovery retains the latest profile/edit timestamp.

The recovery snapshot is local data and does not extend the old layout-edit wire payload. Pooled-resource transfer, complete document/journal budgets and transaction activation are still required before publishing format 5. Android raw snapshots preserve opaque metadata; native snapshots preserve the typed model. The migration itself must continue to preserve original raw authority bytes and unknown fields as described above.

## Complete JSON and outgoing-frame bounds

The Rust configuration validator counts the complete compact UTF-8 document, including every profile, binding map, resource table and opaque metadata field, against the existing 8 MiB limit. Counting streams into a bounded sink rather than allocating another complete encoded document. A size failure stops serialization and reports a proven lower bound; it never installs a truncated document.

Swift and Rust wire encoders now enforce the same existing 8 MiB limit as receiving peers. The limit applies to the final JSON frame, including envelopes, selected-layout copies, metadata and resources. Compact input frames keep their existing fast path and bytes. Rust stops encoding before producing an oversized result; Swift checks the completed Foundation encoding. Mac and Rust receivers reject an oversized response with a small error and retire the affected session, releasing its held output. A stale response for a different connection cannot release the active controller's holds. Phone pending records and saved authority remain available for recovery/retry.

These guards do not by themselves establish that every admitted configuration fits every decorated snapshot: the current wire can duplicate the selected customization and add presentation/package metadata. Migration activation must validate the actual retained format-5 transfer or use a bounded resource/document transfer, and finish combined pending-journal/resource limits and atomic commit/recovery. Rejecting an oversized send is not successful delivery or proof that version-5 migration can be enabled.

## Explicit version-5 destination reader

The first version-5 document codec is `thumble-core::OwnedConfigurationDocument`. It reads only the version-5 envelope and returns immutable original bytes plus raw validated profile views and declared active/default identities. Unknown root/profile metadata, full binding fields, local launch data, resource envelopes, unsigned integers and original formatting do not roundtrip through a normalized renderer. It shares the existing complete configuration/binding/identity limits, validates package-independent canonical/bank appearance, and rejects retired fields and reserved aliases. The only customization is a canonical landscape canvas. The original data is bounded to 8 MiB before parsing.

`Host/fixtures/owned-configuration/v1` contains a hand-assembled destination specimen and 39 mutation cases, with original native resource/template provenance. These are format requirements, not evidence that an actual user profile has been migrated. The nullable default identity remains in the retained raw envelope; the reader uses the active identity only as a temporary ownership-validation default when no default was declared, and does not publish that validation value.

The Rust reader's format-5 validation entry is crate-private and separate from normal `ConfigurationDocument::validate`/`install_into` and persistent-state startup. Reading a destination cannot enable the authority or change phone offers. Native/Android version-5 decoding, typed edit/write preservation, final portable-export policy, actual transfer admission and the backed-up migration transaction remain required before activating this schema.

## Native and Android owned-document readers

`ThumbleOwnedConfigurationDocument` and Android `OwnedConfigurationDocument` now implement the explicit version-5 read boundary and consume the same expanded 41-case matrix as Rust. The additional cases reject duplicate controls and unsupported control kinds instead of dropping controls during projection. Both retain exact original UTF-8 bytes for interchange while producing detached native/render preparation models. Native storage is immutable/COW and eight bytes inline. Android keeps immutable original/projection strings, rebuilds mutable containers for callers, and preserves valid names beyond its legacy 160-character display limit.

The temporary model projection omits the already-validated format marker and supplies the existing model's landscape preference. This does not retag or rewrite the retained source and does not authorize a version-4 export. Native typed normalization and Android's generic JSON number representation are therefore confined to projections; arbitrary source metadata and large numeric spellings remain in original bytes. Authority-global binding mirrors and per-profile maps are checked against declared owners using the retained binding validators. Android validates the resource-expanded canonical layout before preparing its bank so malformed kinds/mirrors cannot disappear silently.

These are explicit readers, not shipping file-import or synchronization activation. Version-4 startup/import guards and phone offers remain unchanged. Writers must use a lossless edit transaction rather than reconstruct a version-5 file from projected profiles. Portable export, actual transfer admission and backed-up migration/rollback still require integration.
