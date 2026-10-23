# Selected iOS store notices

The first actual unsigned store archive contained zero notice resources. This supplement supplies real, verified legal texts as an incremental packaging repair. **Complete third-party notice coverage remains a release blocker.** An artifact checker finding these files establishes presence only.

The two versioned assets contain 26 distinct verbatim texts (29,878 bundle bytes) with source origins, exact byte offsets and SHA-256 values. The inventory explicitly records unresolved work. Application and `@thumble` workspace sources are classified separately from third-party components. No license is synthesized from a `package.json` license field.

## Actual artifact evidence

A fresh unsigned generic-iOS store build used the reviewed source commit `9c0d42ef4f147a16421a449e35afb9d641b164ae`, illustrative version `1.0.0` / build `4`, and signing disabled. A second, separate archive emitted the composed Hermes source map:

- 1,142 source entries, all referenced by mappings; 44 actual npm package roots.
- Map SHA-256 `e7d906e352db412d463d63cc5a2447fce8704e801d8098b9b00b45ae914ad35a`.
- Matching Hermes bundle SHA-256 `ba65ac439f9c5e34cd52fecd832b3bac744d881f187e1f83d1374c5ab9641c8c`.
- Eight embedded frameworks, with exact executable hashes in the inventory.
- Generated CocoaPods acknowledgements supplied 11 named library entries. They were not shipped by the original build; heading/footer entries are not libraries.

Emitting a source map changed the Hermes bytes. This graph therefore belongs to the separate with-map artifact; it does not retroactively certify the original archive, future imports, actual runtime execution, or all installed dependencies. The installed dependency tree is a superset and is not the shipping inventory.

A third unsigned archive included the selected resources. Its 172 files total 161,604,310 bytes; both notice resources match the then-frozen selected source bytes exactly (inventory SHA-256 `076fd43b193ccab28c9ad499f401e9693c34a82b11b1543c20ce8eea289dee6d`). The later Expo Router origin update changes the inventory bytes and has focused helper verification; it has not been rebuilt into that archive. The artifact auditor passes all 11 metadata checks, including notice presence. Signing stays unverified, distribution stays unaccepted, and complete notice coverage remains unverified. Its Hermes bundle hash is `8e305b270c8fb8c197e71660bccc0190126df35551bd8fa09d2cff3c5da130b0`; the same build independently emitted `store-notices.jsbundle.map`, byte-identical to the second archive’s composed map (SHA-256 `e7d906e352db412d463d63cc5a2447fce8704e801d8098b9b00b45ae914ad35a`). The build log records both the Metro map output and final Hermes map composition for this third archive. This establishes its own matching map/bytecode provenance and the same 1,142-source graph, rather than assuming an older graph covers changed bytes. It still does not certify future builds or complete notice coverage.

For the four missing-root-text `@react-native` packages, npm release metadata identifies commit `5c35c82cf7dd322bf94d47501508c3de975c077b`. Its upstream root LICENSE matches the selected React Native text. Metro runtime release metadata identifies commit `c7597f88c3e5b2a0d5e5915dfed2413aadcdfcce`, whose root LICENSE was fetched and hashed independently. Public exact-version metadata URLs and package JSON hashes are recorded for local npm texts; a metadata URL alone is not an assertion that its tarball integrity was fetched or independently verified.

Expo Router `58.0.25` is additionally matched through the public npm attestation payload: both subjects match the exact tarball SHA-512, which also matches registry integrity and the pinned lock. The installed package JSON and all 384 mapped iOS files are byte-identical to that tarball. The SLSA resolved-dependency payload identifies source commit `a248d78e3b9260e6f39b320ed25ae65e90acff7d`; its root LICENSE hashes to `fb3ca4a837f5779e83cef89b78253a8949cfb9429c340309f62d0465ec6610b4`, already present in the selected bundle. The inventory now records this additional origin without changing bundle bytes. Attestation cryptographic signatures were **not** verified; this content/provenance match is not a supply-chain or distribution-clearance claim.

The cached Hermes Release tarball and ReactNativeDependencies Release tarball contain byte-identical executables to the archived frameworks. The pinned Hermes podspec selects version `260318099.0.4` from `version.properties` for prebuilt downloads; `.hermesv1version` tag `.0.2` is source-build fallback metadata, not evidence of a bad cached build. The compiler npm git commit does not by itself establish the runtime's vendored source provenance.

## Store-only helper

`apps/mobile/plugins/with-ios-store-notices.cjs` is composed by the store-profile plugin. A fresh native-project prebuild through the normal store configuration registered both exact assets in the Thumble application resource phase. It returns the development configuration unchanged and requires the production iOS identity before store registration.

Before registering two Xcode resources, it checks the actual bundle bytes, every selected text range/hash, the inventory bounds, the current `bun.lock` hash and the explicit incomplete-coverage flag. Missing files, symlinked files, changed lock/bundle/text bytes and unsupported inventory changes fail before registration. The helper copies the verified assets into the generated iOS project's `StoreNotices` resources. It does not download dependencies, select signing identities or modify privacy declarations.

Run its focused checks with:

```sh
node --test tooling/test_ios_store_notices.cjs
```

The lock check protects the selected-text snapshot; it cannot establish that a future Metro graph, native link result or source import graph is unchanged. Rebuild and audit actual artifacts after source/dependency changes. A full notice inventory/generator remains needed before final release clearance.

## Remaining gates

The asset inventory lists six unresolved entries: a missing exact-release text for `standard-navigation`; ReactNativeDependencies vendored attribution; Hermes runtime vendored attribution; Metro's mapped vendored EventEmitter implementation; complete static/native link attribution; and overall notice coverage. ReactNativeDependencies facade podspecs declaring MIT do not resolve Boost, Folly, glog, SocketRocket, fmt, fast_float or DoubleConversion obligations. Top-level React/Hermes texts do not establish complete LLVM/Unicode/regex or other vendored coverage.

These assets do not approve a release version, signing/provisioning, App Store privacy labels, export classification, gameplay/live sync, or distribution. Original archives, phones and the running receiver remain untouched.
