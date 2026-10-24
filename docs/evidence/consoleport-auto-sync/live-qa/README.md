# Live ConsolePort sync and held-layer QA — October 24, 2026

The requested held-layer behavior passes in the app connected to the real WoW receiver. Computer Use confirmed the corresponding ConsolePort HUD states in the running Fuskotargar session on Azuresong. No game bindings, action slots, or modifier settings were changed.

| Check | Expected | Observed and evidence |
| --- | --- | --- |
| Fresh automatic sync | `/reload` writes a fresh character snapshot; receiver notices it without manual export | Saved snapshot timestamp refreshed; character profile stayed at activation 16 because its contents were identical. Receiver reported connected, unlimited and ready at revision 16. See `sync-acknowledgement.json`. |
| Base layer | Heroic Strike, Attack, Tough Jerky and Jump | Present in the app and WoW. |
| Hold LT | SHIFT layer; Heroic Strike disappears; RB becomes Target Scan Enemy (Hold) | Live AX positive/negative checks pass. App and WoW screenshots agree: `app-lt.png`, `wow-lt.png`. |
| Hold RT | CTRL layer; A becomes Quick menu; base spell slots clear | Live AX checks pass; `app-rt.png`, `wow-rt.png`. |
| Hold both | CTRL-SHIFT layer; A becomes Utility ring; base spell slots clear | Live AX checks pass; `app-both.png`, `wow-both.png`. WoW uses the ring artwork; the app currently shows its text fallback. |
| Release each hold | Base Heroic Strike returns; Utility ring disappears after releasing both | All checks pass; `app-released.png`. HID trace finishes completely neutral. |
| Physical iPhone transport | Three-second LT and RT holds reach the actual Mac controller and release | Successful live holds measured 3082.9 ms and 3071.5 ms. No HID submission errors. |
| Repeated sequence | LT → release → RT → release → both → release, without stale layers | Two consecutive simulator fragment replays pass: 17 checks/actions, zero failures, errors or skipped steps per replay. First replay started after recycling only this simulator's Argent services. |

The simulator is **Tapping React Native QA**, using the isolated `com.thumble.consoleportartworkqa` app built from the production spell/layer renderer. Its custom scheme paired it to the real signed **Thumble Local Test Receiver**, which emits real virtual-HID reports to WoW. This is not an offline profile fixture or a receiver linked to a discard stub. The baseline is the live exported Fuskotargar layout, with LT = Shift and RT = Ctrl. Saved coordinates `.6295,.395` and `.6295,.605` come from its LandscapeRight AX tree (portrait-oriented screenshot axes).

`consoleport-live-wow-spell-layers` is a reusable **fragment**, with its explicit live-character/paired/unlimited/neutral prerequisites, rather than a standalone purchase/onboarding QA test. Raw Down/Up steps intentionally keep touch ownership across live accessibility checks. Checks stay as raw `await-ui-element` calls against the working AX service. Recording warned that the separate native UIView hierarchy was unavailable, so these checks were not promoted into hierarchy-based `assert:`/`await:` directives. Each negative check follows an earlier positive check for the same label. Their immediate-hidden notes are expected after removing the positively established state.

Replay with Argent `e2e-execute`, name `consoleport-live-wow-spell-layers`, project root `/Users/codybontecou/dev/tapping`, device `87952CD2-B760-40A1-AF11-5CE40995960B`, and acknowledge the prerequisite only after pairing and establishing the neutral base state. The captured second result is in `replay-second.json`.

## Limits and interrupted run

Argent cannot automate two simultaneous fingers on a physical iPhone. The live two-finger visual and WoW comparison therefore used the simulator; the physical phone's single-trigger transport holds were independently confirmed in the HID audit. A physical replay was interrupted when a different app took the device foreground. That replay is invalid and is not counted as a passing run. The original physical live holds remain valid; no further actions were taken in that other app.

This run verifies a fresh, unchanged ConsolePort snapshot and its delivered layers. It does not claim a live binding-edit or character-switch test; native fixture tests separately cover changed labels, character switching, stale/malformed input, write races and idempotence. `npm run test:consoleport-sync` and `npm run test:addon` were rerun.

There were zero HID submission errors across the valid live observations and simulator replays, and all controls released. `hid-audit.jsonl` contains only report bytes, monotonic timestamps and submission results; `hid-summary.json` shows trigger durations, including two brief intermediate states as the multi-touch transport releases its fingers sequentially. No pairing secrets are stored here.

Cleanup: the simulator was backgrounded from neutral and only its own Argent services were stopped. The local test receiver was relaunched without the input-audit or private-link export environment variables. Unlimited testing remains available. The physical phone was left in the foreground app that interrupted its replay; its Argent runner was not stopped because another session was using it. Pair the phone again when returning to Thumble after this simulator-connected QA run.
