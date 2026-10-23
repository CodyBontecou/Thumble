# Headless Kotlin editor host witness

`PhoneEditorRealServiceTest` runs the production `ControlTLSClient`,
`PhoneEditorRPC`, `PhoneEditorSession` and journal coordinator against the actual
Bun service/native role12 host. Credentials are synthetic and injected in memory;
the journal uses an in-memory compare-and-replace store. The internal authority
resolver retains real pinned TLS/hello validation and omits only Android Looper
inspection on the JVM worker. This proves JVM SDK networking, not Android device
TLS-provider, UI, Keystore or vault behavior.

The helper reads the pinned profile, enqueues one exact label intent, submits and
reconciles it, proves the journal is empty while the cached revision stays pinned,
reads the original receipt, repeats the identical intent without another
revision, and reads the persisted label. The Bun driver independently verifies
that original receipt and persisted label through its pinned Python client.

The existing opt-in driver gains `THUMBLE_EDITOR_ANDROID_COMMAND`. It requires a
new summary file from an actually executed helper, so a skipped or cached Gradle
test cannot satisfy the gate. Its mode0600 credential fixture is removed after
the helper exits; no credential appears in reports or source capsules. The
Swift-only command and report remain unchanged. Kotlin alone advances revision3
to4; after Swift it advances revision4 to5.

From `Rewrite`, after building the native receiver and Swift test suite, use a
JDK17 and configured Android SDK35, plus a TLS1.3-capable Python:

```sh
THUMBLE_REWRITE_EDITOR_CROSS_LAYER=1 \
THUMBLE_EDITOR_PYTHON=python3 \
THUMBLE_EDITOR_SWIFT_COMMAND='["swift","test","--skip-build","--package-path","native/mobile-input/ios","--filter","realServiceEditorUsesPinnedTLSAndExactReceipt"]' \
THUMBLE_EDITOR_ANDROID_COMMAND='["./native/mobile-input/android/gradlew","-p","native/mobile-input/android","--no-daemon","--rerun-tasks","testDebugUnitTest","--tests","com.thumble.rewrite.input.PhoneEditorRealServiceTest"]' \
THUMBLE_EDITOR_EVIDENCE=/path/to/private/kotlin-editor-summary.json \
bun test tests/editor-cross-layer.test.ts
```

`JAVA_HOME` must select the configured JDK and `ANDROID_HOME` the configured SDK.
`--rerun-tasks` matters: fixture environment is deliberately private and is not a
public Gradle task input. The helper is skipped when its fixture is absent, and
the driver remains skipped unless `THUMBLE_REWRITE_EDITOR_CROSS_LAYER=1`.

Successful combined evidence contains one passing Bun test, one executed Kotlin
JUnit test with zero skips/failures, both SDK queue-empty summaries, revisions
`[1,2,2,3,4,5]`, and fixed Swift/Kotlin phase names. The driver retains the earlier
actual CLI-contention, slow-write and four-revoke-ACK checks. No production SDK,
native adapter or frozen v2 capsule is changed by this follow-up.
