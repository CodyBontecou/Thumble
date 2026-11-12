# Physical phone desktop-workspace QA

Implementation baseline: a07563a. Targets: connected iPhone 17 Pro and Pixel 7. Test profiles and receiver storage are isolated from personal controllers. OS input is captured by an isolated desktop target; no live game or unrelated app receives QA keystrokes.

| Scenario | User actions | Required evidence | Side effects |
| --- | --- | --- | --- |
| Build / launch | Open current QA build on each phone | Native screen, app version and source identity | Preserve existing app data |
| Desktop delivery | Pair, save a keyboard/mouse controller, send saved revision | Phone renders exact controls; receiver acknowledges revision | QA profile + pairing |
| Input | Press keys and mouse buttons, move trackpad, two-finger scroll, release | Captured receiver events and neutral/release state | Isolated input capture only |
| Editing | Move/resize a control, save, reopen | Phone + desktop agree on saved revision and geometry | QA profile revision |
| Recovery | Background, reopen and reconnect | Remembered pairing; fresh neutral before held input | QA connection lifecycle |
| Boundaries | Invalid geometry / stale draft / duplicate sources | Rejected save preserves draft; no held input after pause or disconnect | QA fixtures only |

## Result

Physical functional QA completed, with one unresolved iPhone orientation finding. This is not release certification or a passing standalone automated regression suite.

Both actual USB-connected phones were used: iPhone 17 Pro, iOS 27.0.1, and Pixel 7, Android API 37. No simulator results are substituted for these checks.

- iPhone: freshly built, automatically signed Debug `com.thumble.ios` 1.0.0(2), installed over the existing development app without uninstalling it.
- Pixel: existing Debug `com.thumble.android` 1.0.0(1), target SDK 36, running this worktree's current JavaScript through Metro 8093. This was not a new Android release APK.
- Source: a07563a plus the menu changes in this QA commit. Metro reported this worktree's `apps/mobile` as its project root; the Android debugger identified Google Pixel 7 explicitly.
- Native receiver: separately named `Thumble Hardware QA.app`, isolated profile directory, file-backed QA secrets, local-testing access, real TLS/profile/revision handling. CoreGraphics events and Xbox reports were captured instead of being posted to other apps or a virtual HID device. Store ownership and the user's demo ledger were not modified.

| Check | iPhone 17 Pro | Pixel 7 | Evidence |
| --- | --- | --- | --- |
| Pair and receive exact desktop layout | Pass | Pass | Trackpad, Left click, Right click, Space rendered; native layout acknowledgement confirmed |
| Space / left / right mouse press and release | Pass | Pass, repeated with native assertions | `iphone-native-inputs.json`, `pixel-native-inputs.json`, `pixel-native-repeat.json` |
| Relative pointer and two-finger scrolling | Pass | Pass, with automation recovery described below | Native mouse-move and scroll events in the same traces |
| Shift+Space modifier ordering | Pass | Pass | `*-shortcut.json`: Shift flags set before Space down/up, then cleared |
| Xbox A button and movement stick | Pass | Pass | `*-gamepad.json`: non-neutral reports followed by neutral; isolated gamepad sink |
| Edit geometry, save, apply | Pass: drag, save, apply | Pass: resize, save/apply | iPhone copy activation revision 2; Pixel copy activation revision 3; receiver store confirms exact geometry |
| Preserve keyboard/mouse mappings while editing | Pass | Pass | Applied copies retain key, mouse, and pointer mappings; subsequent input checks pass |
| Overlap validation | Pass | Not repeated | iPhone overlap shows actionable error and disables Use on Mac; correcting it enables activation |
| Background and reconnect | Pass | Pass | Receiver output disabled while backgrounded; same active layout restored after foreground reconnect |
| Background during held Space | Not separately exercised | Pass | `pixel-background-release.json`: native key up and disabled receiver output |
| Menu layout after fix | Pass | Pass | `iphone-menu.png`, `pixel-menu.png` |
| Controller orientation after menu dismissal | Open finding: returns portrait | Pass: returns landscape | See below |

The iPhone input fragment was replayed twice unchanged after its scroll path was corrected. Those tool passes were corroborated with native events. The Pixel's initial selector replays reported success without delivering the intended inputs; they are explicitly **not** counted as successful input QA. The corrected physical Pixel run and its repeat were verified against captured native events. The retained `iphone-input-walkthrough.yaml` is a paired-state diagnostic fragment, not a standalone acceptance test with native-output assertions.

## Fixes and open findings

1. **Fixed: menu items collapse into narrow portrait columns.** The portrait column previously retained wrapping and unspecified child widths. Portrait rows now occupy the full width without wrapping. Controller menu and demo overlays explicitly retain landscape. The resulting landscape menus were visually checked on both phones. Lint and typecheck pass.
2. **Open: iPhone controller returns in portrait.** Pairing and dismissing the menu/editor can leave the root controller portrait despite its existing landscape option. Editor and corrected menu do render landscape, but the root issue persists. Observed on the signed iOS 27 Debug development client; production/release behavior and cause remain unverified. Do not label the entire orientation issue fixed.
3. **Tooling: physical Pixel landscape injection rotates coordinates.** Fresh Android accessibility frames describe landscape correctly, but injected taps can be rotated away from their targets. Android input-dispatch logs confirmed the mismatch. After proving it with a native Space down/up trace, some gestures used the inverse transform. Deterministic subsequent taps/drags used physical-device ADB at accessibility-derived logical display positions. No targets were guessed from screenshot pixels.
4. **Tooling: Android two-finger automation leaves two synthetic pointers held.** Android InputDispatcher rejected subsequent Down/Up injections because pointer IDs 0 and 1 remained down. A matching two-pointer CANCEL, injected by a temporary shell helper, cleared the stream without restarting the phone or changing app data. Two-finger scroll itself produced native scroll events. The problem recurred with the pinch/drift helper, so it is not treated as a portable replayable regression.
5. **QA harness configuration corrected.** Its missing normal public verification configuration caused a purchase warning and blocked auto-resume. Bundling `Monetization.json` corrected that setup problem. Local-testing access is not evidence of successful production purchase verification.

## Limits

No live-game input, OS permission prompt flow for production keyboard injection, WoW addon spell Apply, physical external-controller pairing, store purchase flow, Windows/Linux hardware session, or release-build performance certification was performed. Desktop fixture selection used the actual shared ProfileStore transactions; that setup is not claimed as a desktop-UI design walkthrough. Device build numbers are development-shell numbers, not the submitted store builds.

Phone storage was preserved. The isolated receiver and QA-created phone drafts are separate from personal desktop profiles; QA pairing necessarily replaces the currently remembered peer. Temporary pairing URLs, reconnect credentials, and secrets are excluded from these artifacts. Incomplete setup recordings were removed so they cannot be mistaken for passing tests.

Cleanup: both phones were backgrounded and the session-owned input-capture receiver was stopped. Synthetic touch pointers were released. Metro and Argent services remain available for continued development.
