# Onboarding: pair, verify, enter WoW

This is the implementation specification. The current app implements QR/manual pairing, a controller-only play view with a Thumble options menu, native HID acknowledgements and an introductory setup guide. Physical Android and iPhone gameplay and optical QR pairing have been verified on installed Classic with ConsolePort. Clean-install onboarding and Forever-specific verification remain acceptance work.

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
