# Stored owned authority v1

The protected SQLite source can now hold a versioned owned document with external asset references. This is a private storage representation; the owned-v5 file codec remains interchange. Neither reading a catalog nor preparing storage grants render or execution compatibility. Full import operations, image decoding/value validation, phone editing/sync and runtime publication remain open.

## Representation

The exact outer fields are `schema: "com.codybontecou.thumble.owned-authority"`, `version: 1`, `document` and `resources`. The inner document retains owned-v5 layouts, bindings, stable IDs, all eight appearance variants, original resource aliases and opaque metadata. Known binary fields are replaced by `{assetSHA256, byteCount}`. Sorted resource rows are `{path, sha256, byteCount}`, with JSON pointers relative to the inner document. The stored document hash is the existing versioned lossless-JSON source hash over this whole envelope.

Inventory covers profile resource pools and known inline asset/image fields in canonical customization and appearance variants, including hidden artwork and mirrored control layouts. Resource pools retain their original hash keys; their descriptor hash must match that key. Existing `{resourceSHA256}` aliases continue to reference the profile pool. Unknown root/profile/customization metadata is preserved as source rather than interpreted as resources simply because a field is named `data`.

The portable preparer first validates the owned-v5 structural document and resource digests, then copies, hashes and deduplicates assets across profiles. It emits immutable source and defensive asset copies for the trusted storage transaction. The existing asset preparation/SQLite receipt barrier installs those bytes before committing references. Callers must derive complete semantic operation fingerprints and validate capabilities; the generic storage port is not a public import operation.

The independently constructed [format vector](../Rewrite/packages/fixtures/owned-authority-v1/vector.json) fixes descriptor/path/manifest shape, SHA-256 and preservation of full-width integer and exponent lexemes. Its synthetic bytes are not an image or a claim of render validity. The exact fixture is excluded from formatting that would normalize number tokens.

## Read and materialize

Stored admission verifies exact envelope/manifest fields, known resource paths, complete coverage, strict path order, matching descriptors, pool identities, unique byte counts and limits. It admits catalog metadata without loading binary data. This projection never proves all owned/render semantics.

Materialization reads each unique hash once through a trusted asset reader, copies bytes, verifies size and SHA-256 and reconstructs canonical Base64. It then validates the entire owned-v5 document, including pooled references and bindings. Missing/corrupt bytes never become empty data or rewritten objects. The reader and digest callbacks are host-established ports, not imported document fields. Materialization preserves raw number lexemes and untouched opaque subtrees; whitespace around transformed known fields is not an interchange byte-identity promise.

Catalog list and rename work with this envelope as well as earlier development v5 source rows. Rename changes only the explicitly addressed profile's name/timestamp inside the wrapper; the resource manifest and unrelated data remain unchanged. Durable receipts, conflicts, replay and the configuration child remain the same authority. No automatic wholesale migration of existing rows occurs on open.

## Bounds and verification

The stored envelope and reconstructed interchange each fit the lossless codec's 8 MiB, depth-64 and 131,072-node limits. At most 256 unique assets, 8 MiB of unique bytes and 8,192 resource locations are admitted. JSON pointers use the codec's 4 KiB/depth bounds. A pre-IO expansion calculation counts every reference occurrence, so repeated references cannot amplify a small unique-byte manifest into an oversized interchange document. Reconstructed JSON values are cached by digest rather than parsed separately for every alias.

Lossless JSON now supports an atomic batch replacement of nonoverlapping existing values. It traverses the source once, preserves untouched source spans, refuses insertion/removal/overlapping paths and rechecks the full output's byte/graph/depth limits. Output accumulation is bounded before joining strings. This avoids repeated whole-document reparsing for thousands of asset fields. The portable Base64 encoder uses bounded chunks and constant stack, without platform libraries.

Tests exercise inline/pooled/hidden assets, cross-profile deduplication, the independent vector, malformed and expanding manifests, wrong hashes/sizes, defensive copying, a 1 MiB resource and atomic batch failure. Real SQLite tests commit external bytes, reopen, rename with receipts and rematerialize. Standalone CLI/MCP checks seed an owned fixture through the trusted repository, run modern/legacy agent mutations, restart, replay the original receipt and verify all retained asset references and inactive profile data. This is not a public rich import/export gate or physical render/gameplay evidence.
