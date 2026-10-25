# Onboarding: WoW and ConsolePort

Thumble initially targets World of Warcraft on a Mac with ConsolePort. The phone supplies controls over the local network; the game stays on the Mac. ConsolePort and WoW own spell bindings and modifier layers. The built-in ConsolePort controller is the default. AI/MCP controller generation is disabled unless explicitly enabled through the feature flag.

## First successful session

1. **Choose the WoW client.** Welcome leads directly to WoW setup. Choose the installation actually launched, then use a compatible ConsolePort release. Client selection does not establish compatibility.
2. **Pair the phone.** Download Thumble Receiver from thumble.io on the Mac. Run it, open Pair phone, and scan the invitation on the same Wi-Fi. Keep the receiver running. Camera denial supports manual invitation entry. Pairing does not establish working gamepad output.
3. **Prepare ConsolePort.** Use CurseForge → World of Warcraft → the selected WoW installation → Get More Addons to install ConsolePort. Also search for the recommended Thumble companion addon (project 1763832) and install a matching release when available. Restart WoW after a first installation, enable the addons at character selection and follow ConsolePort’s controller setup. Thumble provides Mac gamepad recovery; it is not a prerequisite for completing setup. The submitted 0.1.1 release targets Classic Era 1.15.9 and is awaiting CurseForge approval. The sync-enabled 0.1.2 package was uploaded as CurseForge file 9316122; the project still awaits moderator approval. The onboarding hub links to thumble.io/docs#thumble-addon for current installation instructions. Use standard Xbox-style button names. The app's confirmation establishes only that the player has completed these steps. If the receiver has not delivered a saved controller yet, select the built-in ConsolePort controller through the acknowledged catalog path.
4. **Reload WoW and compare phone labels.** With Thumble 0.1.2 or later, ConsolePort action bars enabled, an updated receiver running and ConsolePort controls selected on the connected phone, type `/reload` after loading the character. Open the phone controller and compare spell labels and held modifier layers with ConsolePort, then return to WoW setup to confirm. Reload after starting the receiver or changing spells/bindings. If labels are missing, enable **Automatically sync ConsolePort**, use **Choose WoW folder…** for a different installation, check `/thumble sync`, and reload again. Players can explicitly continue without synced labels. That choice is saved separately from confirmation; neither completes gameplay checks. Both choices are tied to the current receiver, controller revision and client. Existing completed setups remain complete.
5. **Check controls in WoW.** Open the controller and test in a quiet place, then return through Thumble menu → WoW setup. Confirm movement, camera, an action, a modifier combination and menu navigation. One five-check list replaces the former separate preliminary controller test. Finish enables only after all five confirmations for the current receiver, profile revision and WoW client.
6. **Play.** Open the WoW controller. Revisit setup or stick calibration from the Thumble menu. Changing the controller or receiver invalidates the corresponding control confirmations; changing the WoW client also requires ConsolePort preparation again.

Setup saves each milestone locally and resumes after leaving the controller or restarting the app. Existing players retain their profiles and progress. No step inspects WoW or claims that player confirmations are native HID measurements.

## Requirements and positioning

- Mac with macOS 15 or later, Thumble Receiver, WoW and a compatible ConsolePort release.
- iPhone or Android phone on the same local Wi-Fi network as the Mac.
- The game renders on the Mac. Thumble does not stream WoW to the phone.
- No AI connection or cloud account is required for the default controller.
- Public phone-store availability remains coming soon until store release. The website offers launch updates and the Mac receiver download.
- The demo provides 30 total connected minutes across sessions. Pro is a one-time $19.99 purchase.

Welcome, Getting started, pairing, WoW setup, Pro, the website landing page, setup guide and support copy use this same scope. Compatibility with other games and universal WoW-client support are not promised.

## Progress and input safety

Progress and layout preferences use native getOnboardingProgress / saveOnboardingProgress methods. Writes are serialized and failed saves leave the prior state intact. The controller remains mounted beneath setup and releases gameplay input when unfocused. Existing v1 intro completion migrates to dismissed setup without inventing verified milestones.

All five checks are tied to the active test context. Finish rechecks the connection, profile revision, recovery state and current confirmations inside the serialized save. It marks both controls and WoW milestones complete. Profile delivery and neutral recovery must finish before checks can be recorded.

Camera denial, local-network denial, expired invitations and wrong networks need actionable recovery. Lost Wi-Fi, backgrounding, locking, process termination and receiver restart must release held input. Existing WoW bindings and addon settings must never be silently overwritten. Invite secrets must stay out of logs and support exports. RTT is labeled RTT, not game input latency.

## Optional generator

EXPO_PUBLIC_AI_CONTROLLER_GENERATOR_ENABLED=true restores the optional mobile AI routes. The shared/local and cloud flags independently guard generation and mutation endpoints. Legacy first-layout and agent-connection screens remain behind the flag. They are not part of the default onboarding path. Existing saved profiles remain available.

## Verification

Run npm test plus mobile lint and typecheck. Context-bound checklist tests cover disconnected, changed-controller, stale-revision and incomplete-check cases. The first-run simulator recording exercises Welcome → WoW client → Mac connection using an isolated QA app. Physical game confirmations remain player assertions; neither the recording nor unit tests establish that every WoW client supports ConsolePort.
