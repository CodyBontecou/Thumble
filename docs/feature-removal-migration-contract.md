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

This is not an activated upgrade path. Version-4 native configuration import/export and the current Rust authority reject non-null banks. Before accepting a bank into live authority, implement the retained peers and version-5 capability handshake, preserve raw unknown metadata, consolidate repeated resource bytes, enforce the final document byte limits, and complete the backup/compare-and-swap recovery transaction below. Do not advertise version 5 or enable automatic migration merely because native profile roundtrips pass.

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

Old phones that cannot represent the new appearance/layout contract must receive an explicit update-required result rather than an incomplete profile snapshot. Test this handshake alongside paired configuration synchronization. Ordinary local profile import/export, on-phone edits, and local CLI/MCP transactions remain supported independently of hosted artifact transport.

## Verification boundary

The frozen appearance, legacy-profile, and pending-edit fixtures establish pre-removal behavior. The action-set fixture specifies eight scheme/trigger combinations. Migration-case inputs include missing-package recovery, a portrait-only profile, a plain profile, and unknown profile metadata. Their expected dispositions are requirements for the forthcoming migration, not claims that conversion is already implemented.

Completion also requires native rendering review, physical haptic evidence, same-condition input latency comparison, retained WoW exporter/importer tests, meaningful live WoW acceptance where available, and the required stack-safety gate. Record unavailable device/client evidence as outstanding.
