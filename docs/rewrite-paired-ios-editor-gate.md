# Paired iOS editor gate

This opt-in simulator test uses the Release product entry point, its real native
module factory, production enrollment/TLS SDK, the default entitled Keychain
vault and protected disk journal, and a real Bun recording service/native SQLite
owner. It adds no product hooks or JavaScript capabilities. XCTest only performs
native enrollment, journal/receipt inspection and cleanup inside the product UID;
Argent performs every product launch, gesture and text entry.

The fixture is separate from `paired-editor-app-host.ts` (Android). Set
`THUMBLE_REWRITE_PAIRED_EDITOR_UI=1` and run
`bun Rewrite/tooling/paired-editor-ios-host.ts` from the repository root. Set
`THUMBLE_EDITOR_RECEIVER` to the compiled receiver binary when necessary. The
printed fixture port is public; `/fixture` returns private invitation material
only to the native bootstrap. Never log that response. The server is loopback
only and enforces a 4096-byte body limit before reading bodies. It opens the
pairing window lazily so a build cannot expire an already-open invitation.

Prepare an existing generated mobile iOS project, or run Expo prebuild using
Node, then from `Rewrite/apps/mobile` run
`ruby tests/prepare-ios-editor.rb <fixturePort>`. Run `pod install` with the
working directory `Rewrite/apps/mobile/ios`, so Expo resolves its dependencies
from that project. The script creates only a generated hosted test target,
resource and scheme; these generated outputs are excluded from the source
capsule. Its simulator entitlements reuse `tests/ios/Simulator.entitlements`.
Build from the repository root:

```sh
xcodebuild -workspace Rewrite/apps/mobile/ios/ThumbleRewrite.xcworkspace \
  -scheme EditorPairedAppTests -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$PWD/build/paired-ios-derived" \
  ONLY_ACTIVE_ARCH=YES ENABLE_TESTABILITY=YES build-for-testing
python3 Rewrite/apps/mobile/tests/ios/verify-editor-product.py \
  build/paired-ios-derived/Build/Products/Release-iphonesimulator/ThumbleRewrite.app \
  build/paired-ios-evidence/signed-product.json
```

The verifier checks the ad hoc app signature and the arm64 Mach-O embedded
simulator runtime entitlements, including the product application identifier and
default Keychain access group. Simulator runtime entitlements are embedded in
`__TEXT,__entitlements`; a CMS-entitlement dump alone can be empty. This is a
simulator test, with no hardware signing or physical-device claim.

Choose only an explicitly owned simulator through Argent `list-devices`.
Install the built Release app once with Argent, clearing prior fixture state.
For each native phase below, run `xcodebuild test-without-building` with the same
workspace, scheme, configuration, derived-data directory, the owned simulator
ID, `-parallel-testing-enabled NO`, and exactly one selector:

1. `-only-testing:EditorPairedAppTests/EditorPairedAppTests/testEnrollWithProductionSDKAndDefaultKeychain`
2. After the Argent queue/restart sequence:
   `-only-testing:EditorPairedAppTests/EditorPairedAppTests/testCaptureActualUIIntentAfterProcessRestart`
3. After the actual UI sends and refreshes:
   `-only-testing:EditorPairedAppTests/EditorPairedAppTests/testVerifyExactReceiptAndIdempotentReplayWithDefaultKeychain`
4. `-only-testing:EditorPairedAppTests/EditorPairedAppTests/testCleanupOwnCredentialAndDescriptor`

Between phases 1 and 2, restart the product through Argent, open **Edit labels**,
refresh profiles, open **Paired editor witness**, choose **Movement**, write the
custom label **PairedIOS** and queue it. Record the product PID, restart through
Argent without reinstalling, confirm a different PID, reopen **Edit labels** and
**Changes on this phone**. The original **Label: PairedIOS** must remain ready to
send. Phase 2 reads that actual protected disk journal and verifies the original
revision and cached source hash against the fixture's seed; the service is still
revision 1. Native test launches can themselves restart the product, so relaunch
through Argent afterward and return directly to the restored queue.

Between phases 2 and 3, use Argent **Send original change**. Require **Saved on
your Mac**, no pending changes, then open the saved profile and preserve a
screenshot of the exact **PairedIOS** control. Also return Home and reopen the
editor and cached profile in the same process, recording equal PIDs and the
retained label. Phase 3 independently checks the actual refreshed cache at
revision 2 and production RPC status → duplicate original write → status, with
identical operation, revision, hash and affected entities. It performs no
replacement/rebased mutation.

Phase 4 forgets only the fixture credential, requires default-vault readback to
be absent before reporting cleanup, removes its descriptor and private captured
intent, then reports cleanup. POST `{"version":1}` to the host fixture's `/finish`
and await the actual fixture process exit. The fixture gracefully stops its real
service and awaits `service.exited` before independently opening SQLite. It
recomputes the configuration source hash, projects the exact captured control,
checks its label, and compares the stored operation receipt and entity list to
the native exact receipt. It removes its owned private runtime/identity directory.
Never open SQLite independently while the exclusive live owner is running.

Observed final gate on the owned iPhone 17 Pro iOS 26.5 simulator: all four hosted
native phases passed, zero failures; Release queue survived PID 16119 → 16324;
Home/editor/cache reopen retained PairedIOS at PID 16754; exact receipt/duplicate,
cache revision 2, Keychain cleanup and independent post-exit SQLite oracle passed.
The bundled JavaScript SHA256 was
`c3c6ea866f4858e83435ab7b5f91889ce545cf05966ba174ec5f09303c00d15d`.
The product source was public `81c6d4b6` plus the frozen four-leaf queue-refresh
fix, now incorporated in public `c662`; the test-only harness was compiled
separately. Tightening the native harness's empty-journal/cleanup assertions to
throwing guards did not change product JavaScript or SDK code; the final native
receipt and cleanup phases ran that rebuilt harness.

Evidence is sanitized summaries, exact test-result counts, hashes, process IDs
and synthetic UI screenshots. Invitations, credentials, private identities,
protected journal files and unrestricted xcresult bundles are excluded. A draft
Argent recorder selected an incorrect role for one correctly executed AX-guided
tap; it is not a validated/replayed regression flow and is excluded. The actual
gate used Argent gestures with fresh accessibility frames. This gate proves
process restart and same-process navigation, not JavaScript bridge reload or
physical-device behavior. Scope Argent cleanup to the owned simulator; do not
stop another agent's Metro or device services.
