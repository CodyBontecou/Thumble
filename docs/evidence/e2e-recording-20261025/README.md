# Assisted physical iPhone / WoW recording — October 25, 2026

This session is **incomplete**, not a passing end-to-end regression or a complete continuous tutorial. Cody selected the physical iPhone 13 Pro Max (00008110-00046CC63CA0401E). Actual WoW Classic Era character: Fuskotargar, level 1 Orc, Valley of Trials.

## Playable evidence

- [Edited phone walkthrough](../../../build/e2e-recording-20261025/phone-walkthrough.mp4): 7:05, H.264, 1600×740, silent. Real phone recording with pauses and the unsuccessful manual-link section removed. Segments from the main phone movie: 0–90, 405–445, 535–665, 730–790 seconds, followed by 0–105 seconds of the recovery movie. Cuts are not a continuous real-time timeline.
- [Mac step screenshots as a video](../../../build/e2e-recording-20261025/mac-steps-evidence.mp4): actual installation and WoW screenshots, explicitly labeled as screenshot evidence. It is not continuous screen recording.
- [Uncut main phone movie](../../../build/e2e-recording-20261025/iphone-setup-and-play.mov): 17:55.7.
- [Uncut recovery phone movie](../../../build/e2e-recording-20261025/iphone-recovery-check.mov): 4:04.8.
- Earlier phone take: `build/e2e-recording-20261025/iphone-setup-part1.mov`, 6:30.2, largely idle.

The edited video omits raw audio. No recording was published or uploaded. QuickTime phone recording and Screen Studio recording were stopped and saved. The three Mac screen capture attempts targeted Codex rather than WoW; files `mac-setup.mov`, `mac-install-and-play.mov`, and the misleadingly named `wow-setup-and-play.mp4` are excluded from deliverable footage. Screen Studio's two exported source tracks also showed Codex. This is a recording blocker, not a WoW gameplay result.

## Actual actions and findings

| Check | Result / evidence |
| --- | --- |
| Public release | CurseForge project 1763832 / file 9316122 approved and downloaded via public page. ZIP SHA-256 `3043ae49936b7135b0ee5435b1195541f79aec0407e3102dbf41cc0eb9f20ad8` matches the packaged 0.1.2 ZIP. See earlier [QA evidence](../qa-2026-10-25/README.md). |
| Addon install | Copied the actual downloaded/extracted ThumbleBridge folder into `_classic_era_/Interface/AddOns/` using Finder and replaced the existing folder. Captured again as source/destination/replace/installed screenshots. Existing backup from this morning retained. SavedVariables and bindings were not replaced. |
| Addon setup | WoW AddOn List shows Console Port and Thumble checked. Console Port Keyboard remains disabled; legacy Thumble Link remains disabled. `wow-addons-enabled.png`. WoW reloaded after installation. |
| Phone onboarding | Selected Classic Era, paired via physical QR scan confirmed by Cody, advanced through addon instructions, reached “Reload WoW. Check your phone labels.” and opened the controller. Phone data was retained. |
| Receiver / profile delivery | Phone menu displayed Connected, Xbox gamepad, Fuskotargar · ConsolePort. These are transport/UI observations, not proof every binding is correct. |
| Movement | Argent held the Move area for 3 seconds then released. Actual WoW screenshots `wow-before.png` and `wow-after-move-hold.png` show changed character/world position. Receiver remained responsive. Continuous movement/release footage from WoW is unavailable. |
| Menu button | Argent tapped Menu, and an actual WoW screenshot showed the game menu opened. Second tap returned to gameplay. This verifies a real phone input reaching WoW. |
| Jump / camera / LT / RT | Argent executed Jump, Look drag and separate 3-second LT/RT holds during phone recording. Their gameplay outcomes are not independently proven by the failed Mac recordings. Do not mark these checks passed solely from dispatch success. |
| Labels/artwork | **Mismatch observed.** Phone shows Heroic Strike artwork at LB and X and `SPELL Perception` at Y. Actual ConsolePort base bar shows different LB artwork and unassigned X/Y placeholders. The phone's “labels match ConsolePort” confirmation was deliberately not pressed. Root cause has not been established. |
| Disconnect | Argent used Disconnect Mac. Phone changed to practice / generic labels; receiver visibly reported “Disconnected · controls released.” This is receiver/UI release evidence, not a measured HID-neutral report or an interruption while an input was held. |
| Reconnect | Cody performed the fresh QR scan and confirmed Connected. Argent then observed the synced controller with Heroic Strike, Attack, Tough Jerky and Jump labels restored (`phone-reconnected.png`). This verifies reconnect and profile delivery, not every gameplay binding. |
| App restart / persistence | Argent restarted then launched com.thumble.ios on the real phone. The app opened disconnected in practice mode; Classic Era remained selected, and WoW setup correctly returned to Connect Mac (step 2 of 5). See `phone-after-restart.png`. Automatic connection/session restoration was not observed. Full saved addon/checklist persistence remains unverified until paired again. QuickTime stopped with “Recording Stopped — Try recording again” during restart; only the 10-second partial movie was recoverable. |
| Modifier + action / both modifier layers | Physical iOS Argent does not support simultaneous two-finger gestures. No passing player confirmation was supplied; Cody asked the agent to use Argent. These remain unverified. |

The normal hosted receiver's existing demo was exhausted. Gameplay checks used the existing signed **Thumble Local Test Receiver** built with local QA unlimited access and real HID output. It used the existing profile store. No purchase or ownership ledger was changed. The phone's “Pro / unlimited” display in this footage reflects that QA receiver, not a purchased entitlement.

## Remaining work

1. The disconnect/reconnect test succeeded. The subsequent app restart returned the phone to disconnected practice mode. To resume play, scan the receiver QR again; the phone scanner is open. Receiver invitations rotate while disconnected.
2. Obtain verified continuous recording of the actual WoW and Finder windows before repeating the missing Mac footage. Existing screenshot evidence must not be relabeled as continuous video.
3. Investigate the phone / ConsolePort label mismatch; compare base and held modifier layers after a fresh reload. Keep sync confirmation unmarked until they agree.
4. Verify actual Jump, camera, bound action, modifier combinations, release during disconnect and the remaining saved addon/checklist progress after pairing following restart. Keep unsupported real gameplay checks separate from fixture results.

`assisted-phone-session.yaml.txt`, `assisted-recovery-session.yaml.txt` and `assisted-restart-session.yaml.txt` preserve the actual Argent authoring logs for diagnostics. They include assisted QR steps, coordinate gestures and a mistap in the first session. They are intentionally outside runnable `.argent/e2e/`, have not passed replay, and are not regression tests.
