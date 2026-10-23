# Android store selected notices

This incremental packaging step includes 33 real, deduplicated license/NOTICE texts and their provenance inventory in the Android store-profile app. **Complete third-party attribution coverage remains a release blocker.** Presence in an AAB is not licensing, signing or store acceptance.

The selected text bundle is 91,352 bytes, SHA-256 `9448866c217eb6099a351ab3f5488b7f0b22bffbd706d635d15bda1e77149972`. Every individual original text has an exact offset, length and SHA-256 in `ThumbleAndroidNoticeInventory.json`. Origins identify actual npm package files, independently reviewed commit-pinned RN/Metro texts, selected runtime archive members and inspected AAB notice members. No text is synthesized from an SPDX declaration or a `package.json` license field.

The inventory pins the initial inspected unsigned AAB, final Hermes map, lock, runtime graph, resolved artifacts, package JSON hashes and native library hashes. It retains the full explicit **186 unresolved entries**, `completeCoverageVerified:false` and `distributionAccepted:false`. The graph contains 159 release runtime components and 148 transformed runtime artifacts. All 1,133 final-map entries are referenced; their third-party origins are 44 npm packages. Texts are matched for 42 of those packages. The 24 packaged arm64 native libraries have exact stripped-output matches; 11 also match selected release AAR JNI/Prefab members. Project build-copy matches and top-level AAR/module texts do not establish complete native or statically vendored dependency coverage.

The inspected ZIP also contains the existing JourneyApps/ZXing scanner notice, AndroidX's nested `META-INF` license and OkHttp's public-suffix NOTICE. JourneyApps `4.3.0` and ZXing core `3.4.1` match the existing scanner notice coordinates. That combined scanner asset remains unchanged. The selected bundle preserves its exact bytes rather than inventing a replacement attribution.

## Store-only helper

`apps/mobile/plugins/with-android-store-notices.cjs` is an isolated Expo helper. The shared store-profile entrypoint composes it separately. Default development configuration returns unchanged without reading legal resources. Store configuration must use `com.thumble.android`; the callback checks the current package again before copying.

Before copying, the helper checks the current lock, bundle hash/size, each nonoverlapping selected text range/hash, bounded origins and the explicit incomplete-coverage flags. Missing or changed inputs fail. Source/output symlinks and redirected generated asset directories are rejected. It writes only these fixed generated Android assets:

- `app/src/main/assets/ThumbleAndroidSelectedNotices.txt`
- `app/src/main/assets/ThumbleAndroidNoticeInventory.json`

The helper changes no native permission, signing identity, account, package version, build type, input behavior or dependency. It does not perform the provenance audit again during prebuild; the versioned inventory records the reviewed evidence. New dependency/source changes require a fresh artifact-specific audit. A final artifact audit must independently verify the packaged identity and exact resource bytes.

## Actual unsigned package proof

An owned disposable copy used offline installation, a fresh Node-based Expo Android store prebuild and `bundleRelease` with arm64 only. The illustrative version/build were `1.0.0`/`4`; they are not an approved release assignment. A Gradle preflight required the production package, absent release signing configuration and absent native QA build type. No signing keys, installation or upload were used.

The final unsigned AAB SHA-256 is `080efb4cc1aa098d6bccda22100d332e72ac201feb63b51c063411f896c30beb`. Both selected assets byte-match the source inside `base/assets/`. The existing read-only artifact auditor passes all eleven metadata checks. The final graph retains the same 159 components/dependency edges and 148 runtime artifacts; all mapped third-party source contents are identical to the original inspected build. The first-party generated router context differs between disposable build roots. The original unsigned AAB remains unchanged.

An earlier setup attempt produced an invalid generated Gradle wrapper. A known-valid same-version wrapper allowed the first private build; the final fresh Node prebuild generated a valid wrapper directly. The initial corruption's cause is unproven. No JAR, AAB, build log, local path or signing material is included in this source change.

## Remaining work

`expo-router@58.0.25` and `standard-navigation@0.0.5` remain explicit missing-text entries in this frozen inventory. Separately retained public-registry provenance now identifies the exact Expo Router source commit and a matching existing Expo license text; that finding needs a reviewed manifest-only follow-up and does not retroactively change this artifact's evidence. The C++ runtime matches NDK r27b bytes, but a complete runtime/vendor notice mapping is still open. Maven texts, generated code, native static dependencies and complete attribution remain unresolved. The bundled inventory must never be presented as full clearance.

Run the focused tests without a native build:

```sh
node --test Rewrite/tooling/test_android_store_notices.cjs
python3 -m unittest discover -s Rewrite/tooling -p test_android_release_notices.py
```

The eight packaging tests cover default no-op behavior, current identity, exact idempotent copies, lock/bundle corruption, selected text bounds, symlinked inputs/outputs/directories and attempts to turn incomplete coverage into acceptance. The ten inventory tests separately exercise the actual provenance and hostile-container boundary.
