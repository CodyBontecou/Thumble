# Reload WoW → confirm phone labels — October 24, 2026

Packaged Thumble 0.1.2 with all six manifest-declared Lua files, including Sync.lua. Archive membership and every extracted file were compared with source; all match. The submitted 0.1.1 archive is unchanged. Release metadata and both SHA-256 checksums are in docs/releases/thumble-addon.

Onboarding adds a sync stage between addon preparation and the five gameplay checks. It explains keeping the updated receiver running, selecting ConsolePort controls, loading the character and typing /reload, comparing spell labels and held modifier layers, and recovering missing labels via the receiver settings/WoW folder and /thumble sync. The user either confirms labels or explicitly continues without sync. Both decisions persist separately and are scoped to receiver, controller revision and client. No gameplay milestone is completed by either choice. Existing completed setups remain ready. Revisiting labels is available from game and ready stages. Each stage starts at the top of its scroll view.

Verification:

- 227 repository tests pass, including persistence, confirmed/skipped distinction, stale context and legacy completion coverage.
- Lua addon core, discovery, runtime and sync tests pass.
- Mobile lint and typecheck pass.
- Release JavaScript bundle built with AI generation disabled and installed only in com.thumble.wowsetupqa on Thumble Rewrite QA (2C25402F-F87F-46EA-A615-A1A9C0689EC6), using the existing simulator native build. No native changes were required.
- Final .argent/e2e/wow-label-sync-onboarding.yaml fragment passed twice unchanged: 8 steps, zero failures/errors/skips and no idle warnings each time. Semantic scroll-to/tap targets replace recorder coordinates. AX-based identity checks remain raw await-ui-element calls. Its paired/input-discarding-receiver/sync-stage prerequisite must be restored before replay.
- Simulator inspection and the final replay filmstrip verify the portrait instructions, reachable skip and confirmation actions, fixed footer, and reset to the top of the gameplay stage with zero of five checks. The initial run revealed inherited scroll offset; keying Page by stage fixed it. Diagnostic takes are retained as .yaml.txt, not passing tests.
- Existing addon-instructions fragment heading was updated to match the new copy; that older fragment was not replayed in this pass.

Final replay video: .argent/recordings/screen-recording-2C25402F-F87F-46EA-A615-A1A9C0689EC6-1792888652174.mp4 (5.367 seconds, static sections trimmed). replay-filmstrip.png shows the complete sequence. This is visual/structural QA, not a measured 60fps result. Landscape, accessibility text sizes and Android UI were not revalidated in this pass.

No real WoW labels or gameplay confirmations were asserted in this fixture. The receiver linked GamepadStub.c and emitted no game input. Confirmed-label persistence and invalidation are covered by state tests; actual sync gameplay evidence remains in the ConsolePort auto-sync reports. The new addon has not been uploaded to CurseForge; phone stores and physical phone installs have not been updated.

## CurseForge and physical phone deployment — October 24, 2026

Uploaded the unchanged verified Thumble-0.1.2.zip to existing CurseForge project 1763832 as file 9316122. Release title is Thumble 0.1.2; type Release; game version 1.15.9; ConsolePort 91376 is an Optional Dependency. Automatic publication after approval is enabled. The file list showed Processing and the new-project moderator-approval notice. This is upload success, not public approval. Evidence: docs/releases/thumble-addon/curseforge-0.1.2-submitted.png.

Built the full signed iOS Release app with EXPO_PUBLIC_AI_CONTROLLER_GENERATOR_ENABLED=false using the existing workspace, scheme Thumble and Apple Development identity. xcodebuild succeeded. Installed com.thumble.ios in place on **Cody Bontecou’s iPhone (iPhone 17 Pro, 00008150-001405DA2188401C)** using devicectl; no uninstall or data reset. Build and installation logs: build/wow-label-sync-phone-build.log and build/wow-label-sync-phone-install.log. No TestFlight upload or iPhone 13 installation was performed.

Launched the installed app and opened Getting started. The physical AX tree and iphone17-onboarding.png show the new reload-WoW-to-check-labels wording, the updated addon description, previously paired progress and 1 of 3 milestones retained. The phone is offline from the Mac, so no live sync or gameplay confirmations were made; the new sync stage follows Mac reconnection and ConsolePort preparation. Left Getting started open on the phone.
