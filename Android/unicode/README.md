# Portable native skin text

Android API 26's regular-expression grapheme handling truncates joined emoji
differently from the native Swift model. `SkinText` uses compact generated tables
and an extended-grapheme state machine so model limits behave consistently across
Android versions. Grapheme counting and character categories do not depend on the device's ICU data.

The property tables come from the actual Swift `String` and Foundation
`CharacterSet` behavior, using public APIs. The native generator classifies every
valid scalar using String probes plus fixed Hangul, regional-indicator and joiner
ranges. It records grapheme, emoji and Indic behavior, along with exact
alphanumeric/control/whitespace membership. JVM and device tests verify those
three sets over the entire Unicode scalar domain, using native membership hashes.

The regression inputs are the official [Unicode 16 tests](https://www.unicode.org/Public/16.0.0/ucd/auxiliary/GraphemeBreakTest.txt)
and [Unicode 17 tests](https://www.unicode.org/Public/17.0.0/ucd/auxiliary/GraphemeBreakTest.txt).
The current Swift runtime differs from their standard expectations in one and
eight cases respectively. The oracle preserves native results for all 1,859
inputs. This is compatibility with the tested native runtime; it is not a claim
of strict conformance to either complete Unicode version. The state machine
follows the extended-grapheme rules in [UAX #29](https://www.unicode.org/reports/tr29/),
using the native property tables.

Regenerate from the repository root on the reference Mac:

```sh
xcodebuild test -project Thumble.xcodeproj -scheme ThumbleTests -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/StackSafetyDerivedData \
  -only-testing:ThumbleCLITests/ThumbleSkinResolverTests/testEmitAndroidSkinTextOracle \
  CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO
cp build/AndroidSkinResolver/native-text-oracle.json Host/fixtures/unicode/native-text-oracle.json
python3 Android/scripts/generate-unicode-tables.py
./Android/gradlew -p Android testDebugUnitTest assembleDebug assembleDebugAndroidTest lintDebug
```

Review native rule changes before updating the pinned fixture. `sources.json`
records conformance input hashes, native oracle hash, table codes and generated
source hash. The generator only fetches conformance files if missing and checks
their pinned hashes. It retains the [Unicode license](LICENSE.txt). Raw test
inputs and the native oracle are test-only resources; the production APK contains
only the generated tables (about 33 KB of Kotlin source) and the text helper.

Canonical-key comparisons additionally use NFC normalization for Swift-equivalent
JSON keys and contract identities. Native composed/decomposed-key fixtures run on
both the JVM and API 26. Broader normalization-version coverage remains part of
the release/runtime matrix.
