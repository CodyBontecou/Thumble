# Paired Android editor witness

This opt-in test uses an owned Android emulator, the actual Release product entry,
production app session factory, production enrollment and Android Keystore vault,
a disk journal, pinned TLS, and a real Bun recording service with child-owned
SQLite. It never connects input to a game. It adds no production test hooks.

Source basis tested: public d65e499459322af4c57028ea3508fc4ae145e939 plus the
38-leaf editor review candidate (source SHA256
2eba997824340aeeb523f18917502180f710ffd7fe75e91102a84635628272c5) and the
four-leaf refresh repair (source SHA256
32d77620d962ba0f1c55571895faa79f5d75756b7042d0aca09396d07d2593b0).
The repair is published as 6fe1213a8ee5eacb6e7c4aa876b8131a7689d9fd.

## Build before opening an invitation

From the repository root, use the existing native QA prebuild/plugin workflow
(`Rewrite/apps/mobile/plugins/with-native-qa.cjs`) to generate the Android project.
Keep the default `expo-router/entry`; do not use the synthetic preview entry.
Build the native receiver first, then build both APKs:

```sh
JAVA_HOME=/path/to/jdk17 ANDROID_HOME=/path/to/android-sdk \
  Rewrite/apps/mobile/android/gradlew -p Rewrite/apps/mobile/android --no-daemon \
  :app:assembleNativeQa :app:assembleNativeQaAndroidTest \
  -PreactNativeArchitectures=arm64-v8a
```

Install both APKs on the explicitly selected owned emulator using Argent. The
application ID is `com.codybontecou.thumble.rewrite.qa`; instrumentation package
is that ID plus `.test`. This is the release-derived nativeQa variant with an
embedded production JS bundle, an isolated app UID, and no Metro dependency.
Do not select an attached physical phone.

## Start the private recording fixture

From `Rewrite`, using Bun and workspace dependencies:

```sh
THUMBLE_REWRITE_PAIRED_EDITOR_UI=1 \
THUMBLE_EDITOR_RECEIVER=/absolute/path/to/thumble-rewrite-receiver \
  bun tooling/paired-editor-app-host.ts
```

The fixture prints only safe fixture/TLS ports and a synthetic profile UUID.
Reverse both emitted ports on the owned emulator with scoped `adb -s SERIAL
reverse tcp:PORT tcp:PORT`. The invitation remains in host memory and is handed
directly to target-UID instrumentation over loopback. Do not print or preserve
`GET /fixture`, raw credentials, private runtime directories, or the vault.
The fixture uses ephemeral identity/runtime directories and deletes them after
actual service exit. No production receiver or user identity is reused.

Run each instrumentation phase with the emitted fixture port, checking `OK (1
test)` rather than trusting the adb process exit code:

```sh
adb -s SERIAL shell am instrument -w \
  -e class com.thumble.rewrite.qa.EditorPairedAppTest \
  -e thumblePairedEditor 1 -e thumbleEditorFixturePort PORT \
  -e thumbleEditorPhase enroll \
  com.codybontecou.thumble.rewrite.qa.test/androidx.test.runner.AndroidJUnitRunner
```

`enroll` calls the production enrollment SDK in the target app UID, loads the
actual Keystore credential, and saves the existing production endpoint descriptor.
The same command later accepts phases `capture`, `verify`, and `cleanup`.
Without explicit opt-in, the instrumentation test skips.

## Actual UI sequence and oracle

1. Launch the product with Argent. Home → Edit labels → Refresh profiles →
   Paired editor witness → Movement. Write custom label `PairedAndroid` using
   the native keyboard, then Queue. Capture the phone-only notice.
2. Record app PID, use Argent restart, record a different PID. Open Edit labels
   and verify one waiting change and the cached profile. Run `capture`; this
   reopens the production disk journal and captures the exact original scope,
   operation, revision, profile/control IDs, label, and cached source hash.
3. Launch the product again after instrumentation. Open Edit labels → Review →
   Send original change. Verify Saved on your Mac and no pending changes. Back
   to editor home and open the cached profile: its exact first control must now
   show `PairedAndroid`, with generated label `Movement`.
4. Record PID. Hardware Back → editor home → Home → Edit labels → cached profile.
   Require the same PID, no journal-owner error, and the persisted custom label.
5. Run `verify`. The production pinned RPC checks status of the original intent,
   repeats the original write, and checks status again. All produce committed
   revision 2 and the same hash; the original receipt contains the exact original
   operation and affected profile/control IDs. The production journal is empty.
6. Run `cleanup` to forget the actual credential and clear the synthetic descriptor.
   POST `/finish` to the loopback fixture. Require its process exit success and
   `paired-host-summary.json` with every proof boolean true.

The live service checks revision through its actual IPC API. SQLite is opened
independently only after awaiting the actual service process exit because the
production owner uses exclusive locking. The final oracle parses the saved
configuration, recomputes its hash, finds the exact captured profile/control,
compares its label exactly, and checks the complete stored receipt and revision.
The idempotent replay leaves revision 2, so no second mutation is hidden by UI.
Remove only the test's own adb reverse mappings. Leave the owned emulator booted
when another agent needs it; stop only its scoped Argent services.

## Observed result and limits

On the owned API35 arm64 emulator, all four instrumentation phases passed. The
repaired gate observed process PID 5931 → 6270 for durability, then PID 6394
before and after ordinary provider close/reopen. The original save and duplicate
both resolved to revision 2; independent SQLite confirmed the exact label,
recomputed source hash, operation receipt, and affected entities after actual
service exit. Android nativeQa + instrumentation build completed with 599 tasks.
The host tool passed TypeScript checking.

The first run found a real UI bug: committing a restored queue while no profile
was selected claimed refresh but retained a stale cached profile. Preserve that
failure evidence separately. The four-leaf repair was applied, the release was
rebuilt/reinstalled, and the entire gate was repeated on fresh identity/vault
state. The second run proves the repaired cache behavior above.

This gate proves ordinary EditorProvider unmount/reopen and process-restart disk
journal recovery. It does not prove actual JS-context reload/module OnDestroy,
physical-device behavior, OS-vault behavior outside this emulator, camera QR
scanning, or timing-sensitive uncertain/conflict scenarios. Those remain separate
tests. Sanitized evidence contains screenshots, accessibility observations,
phase pass logs, safe synthetic receipts, and PID comparisons; no invitation,
credential, identity key, or SQLite database is published.

Cleanup proof v2 adds an actual production vault read after `forget`; it must
return null before acknowledging cleanup. A fresh enrollment/cleanup-only smoke
passed both phases after rebuilding instrumentation. The fixture permits cleanup
after enrollment for this narrower smoke, while `/finish` still requires capture
and verification and cannot report the full UI gate from cleanup alone. Its Bun
HTTP server also enforces a 4096-byte request-body limit before parsing. The
existing full repaired UI evidence is preserved separately from this narrower
smoke; no UI rerun is claimed for the cleanup-only assertion change.
