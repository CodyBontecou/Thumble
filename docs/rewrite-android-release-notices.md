# Android release notice inventory

`tooling/android-release-notices.py` inventories an actual unsigned AAB, its final Hermes source map, the exact resolved release graph, and matching build intermediates. It does not change the app, install a package, sign an artifact, contact a repository, or approve distribution.

Run the capture task in the **same disposable store-profile prebuild** used for `bundleRelease`. Keep the raw graph private: it contains local artifact paths. Use the existing pinned Java, Android SDK and Bun environment and the same Gradle properties as the release build.

```sh
bash ./gradlew --offline --no-daemon --max-workers=2 \
  --init-script "$REWRITE/tooling/capture-android-release-notices.gradle" \
  -PthumbleNoticeGraphOutput="$PRIVATE/new-release-graph.json" \
  :app:thumbleNoticeGraph

python3 "$REWRITE/tooling/android-release-notices.py" \
  --root "$REWRITE" \
  --aab "$ANDROID/app/build/outputs/bundle/release/app-release.aab" \
  --source-map "$ANDROID/app/build/generated/sourcemaps/react/release/index.android.bundle.map" \
  --graph "$PRIVATE/new-release-graph.json" \
  --maven-cache "$GRADLE_CACHE/modules-2/files-2.1" \
  --output "$PRIVATE/new-notice-inventory.json" \
  --texts-directory "$PRIVATE/new-candidate-texts"
```

The output paths must be new. Use a private directory for build evidence. The sanitized inventory contains component coordinates, relative build-copy members and hashes; it omits absolute input paths and JavaScript source text. The separate text directory contains exact UTF-8 LICENSE, COPYING, COPYRIGHT and NOTICE bytes named by SHA-256. These are candidate attribution texts, **not a complete notice bundle**. No Expo plugin or packaged app resource is changed by this tool.

The inventory decodes source-map VLQ references and identifies the nearest actual npm package with a name and version. An installed package is not counted merely because it exists. A `package.json` license declaration never substitutes for a license text. Generated virtual sources and packages without local texts remain explicit. The final Hermes bundle must match the AAB member exactly; the source-map and lock hashes are recorded. The build process associates the map with the bundle; this is not a cryptographic map-to-bytecode provenance proof or execution-coverage claim.

The release graph is a pre-shrinker runtime dependency superset. Original AARs are selected through the resolved **release** artifact view, preventing a cached debug AAR with the same coordinate from being silently attributed to release. Available original JARs are pinned by hash. The raw graph and resolved transformed runtime artifacts are also hashed. Missing archive texts, project components and statically vendored dependencies remain unresolved. POM declarations and license URLs are not treated as verified license content.

For each packaged arm64 library, the stripped output must match the AAB bytes. The unstripped merged SHA is compared with exact JNI **and Prefab** members of selected AARs. Matching project `obj/arm64-v8a` copies are recorded separately; they can be linker input copies, so they do not establish original compilation provenance. Neither a matching AAR nor a module's root license proves coverage of every embedded native dependency. Source-level license/NOTICE mapping is still required, including generated app/codegen libraries and the C++ runtime. Other ABI packages require a corresponding audit; this first inspection supports arm64 only.

All ZIP notice paths are considered, including `base/root/META-INF` and other `base/root` locations. The existing JourneyApps/ZXing notice is reconciled lexically against actual resolved coordinates. The tool does not reauthenticate the upstream content of that existing combined asset. Exact text hashes support a subsequent reviewed bundle and prevent substituting placeholders. The output always reports `complete:false` and `distributionAccepted:false`.

## Initial unsigned artifact evidence

The illustrative store-profile build used Android version `1.0.0`, build `4`, production package ID and no release signing configuration. It was not installed or uploaded. Its arm64 AAB contains 24 native libraries; the graph contains 159 components and 148 transformed runtime artifacts. The final Hermes map references 1,133 source entries owned by 44 npm packages, plus first-party/generated entries. This is an artifact-specific inventory, not a claim that all installed packages ship.

The actual ZIP includes `base/assets/thumble-qr-notices.txt`, `base/root/META-INF/androidx/annotation/annotation/LICENSE.txt`, and `base/root/okhttp3/internal/publicsuffix/NOTICE`. JourneyApps `4.3.0` and ZXing core `3.4.1` match the existing scanner asset. An optional independently reviewed upstream inventory/bundle may supply missing monorepo root texts via `--upstream-inventory` and `--upstream-bundle`. The tool verifies the whole bundle, exact byte slices, content hashes, actual package JSON hashes, version/component and commit-pinned upstream URL before adding those texts. It does not fetch or independently reauthenticate the external audit. The reviewed RN/Metro supplement matches five missing package texts, leaving `expo-router@58.0.25` and `standard-navigation@0.0.5` unresolved. Eleven of the 24 libraries match exact selected JNI/Prefab AAR members; the remaining 13 have matching project build copies without complete original-source attribution.

Missing npm root texts, incomplete Maven texts, native vendored dependencies and generated-library provenance prevent full clearance. Private reports retain the exact artifact and evidence hashes; real build logs and absolute paths are not source artifacts.

Run the focused synthetic regressions with:

```sh
python3 -m unittest discover -s Rewrite/tooling -p test_android_release_notices.py
```

The tests cover exact release-native hash chains, nested packaged notices, missing text despite an SPDX declaration, referenced-source filtering, virtual origins, release/debug selection, malformed maps/JSON/ZIPs, traversal and symlink rejection. Limits bound entries, archive/member/text sizes and project build scanning; archives are never extracted. Treat all build and cache roots as trusted, owned disposable inputs. This is a provenance assistant, not a general hostile-filesystem sandbox or legal clearance system.
