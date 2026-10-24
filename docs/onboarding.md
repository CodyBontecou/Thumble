# Onboarding: pair, verify, enter WoW

This is the implementation specification. The current app implements QR/manual pairing, a controller-only play view with a Thumble options menu, native HID acknowledgements and resumable setup with an agent connection check and first-layout request flow. Physical Android and iPhone gameplay and optical QR pairing have been verified on installed Classic with ConsolePort. Clean-install onboarding and Forever-specific verification remain acceptance work.

## First successful session

1. **Prepare the Mac.** Phone shows the receiver download URL and explains that both devices use the same local network. The Mac receiver opens a short setup window from its menu-bar item. It reports whether the virtual gamepad is ready, requires setup, or failed, with an actionable reason. Pairing must not imply HID setup succeeded.
2. **Pair the phone.** Mac shows an expiring single-use QR. Phone explains camera and local-network access just before requesting them, then scans and performs the authenticated handshake. The user sees the receiver's name. Camera denial has manual invitation entry; local-network denial links to the relevant system setting. LAN privacy applies to direct local connections too: see [Apple's usage-description documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/nslocalnetworkusagedescription?changes=l_9). Keep invite secrets out of logs and support exports.
3. **Verify the controller.** A short live test checks left/right stick range, neutral centers, both triggers, ABXY, D-pad and simultaneous movement + action. Separate indicators for paired, receiving input and virtual gamepad ready. The test must observe output at the HID layer in a separate process; displaying touch events is insufficient.
4. **Set up Forever.** Ask the user to select the Forever installation when needed; do not hardcode an unverified installation-folder name. Open the [ConsolePort distribution](https://www.curseforge.com/wow/addons/console-port), explain selection of the Forever flavor/client, and guide installation. Identify the detected addon version if the user grants folder access. If installed while WoW is running, guide the required game restart and verify the addon is enabled. A completed download does not establish that the addon loaded.
5. **Verify in game.** Connect the gamepad before launching for the initial test. Guide through the supported ConsolePort controller setup on the actual client version, confirm an Xbox-style button layout, then demonstrate movement, camera, interaction, jump, targeting and trigger-modified actions. Verify menu navigation and a way back to keyboard/mouse. Do not claim the receiver can inspect in-game state without an implemented integration; ask for user confirmation where only the game can show the result.
6. **Play.** Phone becomes the landscape controller. Menu-bar status stays small: connected phone, current profile, input health, pause/disconnect and setup help. On reconnect, reset input first and restore the selected profile without replaying onboarding.

Spell/action bindings belong to ConsolePort/WoW. AI edits the phone's physical arrangement and gamepad output mappings through MCP; onboarding has no layout editor.

## Acceptance criteria

- Fresh installs reach a demonstrated in-game action on a physical iPhone and Android phone without a terminal.
- No setup step claims success before its layer is actually verified.
- Camera denied, local-network denied, expired QR, wrong network and AP client isolation produce specific recovery guidance.
- Lost Wi-Fi, app background/lock, killed mobile process, receiver restart and rejected profile updates leave no stuck buttons or movement.
- Pairing can be revoked. Another phone cannot take over an active controller silently.
- A game opened before pairing can recover through hot-plug or an explicitly tested relaunch path.
- No existing WoW bindings or addon settings are silently overwritten.
- Diagnostics identify the failing layer and redact device secrets. RTT is labeled RTT; it is not presented as game input latency.
- Store reviewers can obtain the matching receiver and reproduce pairing/input verification without a paid WoW subscription; WoW-specific verification is a separate product acceptance check.

## Resumable phone setup

Fresh installs see Welcome once, followed by Getting started. The hub persists four independent milestones on the phone: paired, controls tested by the player, WoW action confirmed by the player, and first-layout choice completed. Leaving for the controller preserves unfinished milestones. Existing v1 intro completion migrates to a dismissed setup; it never invents verified milestones. Getting started remains in the controller menu.

Progress and layout preferences use the native `getOnboardingProgress` / `saveOnboardingProgress` methods (UserDefaults on iOS, committed SharedPreferences on Android). Writes are serialized and failed saves leave the prior state intact. Both phone native builds must be updated. The controller remains mounted beneath setup, releases gameplay input when unfocused, and renders/acknowledges incoming profiles normally.

**Connect your AI** is available from the menu and first-layout screen. Share the displayed request with a Mac agent that has the local MCP server configured. `agent_connection_check` records a non-secret 12-character correlation code in the shared profile store. Check connection requests the paired receiver's profile catalog and accepts only a matching code no older than ten minutes. An old receiver reports that an update is required; a missing/mismatched check explains how to refresh the agent and align `TAPPING_PROFILE_DIR`. This verifies access to the same store at the time of checking, not continuous agent availability or game compatibility. External agent installation still requires configuring the local stdio server; no hosted AI service is bundled.

**Your first layout** offers familiar controls, a ConsolePort mirror, or a character-based layout. Button size, movement side, optional character text, source profile ID and a unique target profile ID persist across restarts. The selectable/shareable request instructs the agent to read revisions, validate, preserve in-game review/Apply, import the verified binding result before syncing labels, activate explicitly and check delivery. Changing preferences clears the pending request. Check layout delivery completes the milestone only for the requested profile after phone rendering and neutral recovery. Standard-controller selection needs no agent and switches from an active custom profile through the existing acknowledged profile-selection path.

Verification: `npm test`, mobile lint/typecheck, `node tools/test-profile-catalog.mjs`, `node tools/test-onboarding-receiver.mjs` (isolated stub receiver), and the recorded simulator walkthrough. Physical in-game confirmations remain player assertions; setup does not synthesize HID verification.

## WoW and ConsolePort guided setup

WoW setup now resumes through installation selection, Mac pairing, a full standard-controller test, matching ConsolePort preparation and five explicit in-game checks. Pairing/test confirmations return directly to the WoW flow. Standard controls finish without an AI dependency; optional cloud requests include WoW and comfort context while character mirroring retains the local Bridge review/apply handoff. See [implementation and QA evidence](evidence/onboarding/wow-setup/README.md), including remaining cloud-to-Mac and live gameplay validation boundaries.
