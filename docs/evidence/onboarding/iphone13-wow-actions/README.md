# Reachable WoW onboarding actions — iPhone 13

Verified 2026-10-23 on the connected iPhone 13 Pro Max, iOS 26.3.1, in the app’s supported landscape orientation. Updated signed Release build installed over `com.thumble.ios`, preserving setup progress.

## Change

WoW onboarding uses the existing safe-area-aware Page footer and Actions bar. Confirmation stays outside the instruction scroll view. Offline, Connect Mac appears beside the disabled confirmation. The in-game reminder and save errors are also outside the scroller. The general WoW help screen (without setup=1) retains its existing layout.

## Verification

- PASS: Offline first render shows both buttons without scrolling. Both remain at normalized y=.812, height=.122 (52pt on this device) after four content scroll gestures. The bar clears the home indicator; the final instruction card remains readable above it.
- PASS: Connect Mac opens the actual pairing screen. Done returns to WoW setup, then Getting started.
- PASS: Connected first render shows the full-width enabled confirmation with the in-game reminder. Connect Mac is absent.
- PASS: Stopping the QA receiver updates the same open WoW screen to the disabled confirmation and available Connect Mac action.
- PASS: Onboarding remains 1 of 4 complete. Confirmation was never pressed; no game input, bindings, or profiles were changed.
- PASS: Saved offline flow replay: 23 executable steps passed, plus two diagnostic echoes (25 reported entries). Connected fragment replay: 9/9 passed.
- PASS: Mobile lint, TypeScript check, signed device build, and existing onboarding/pairing-link tests.

Screenshots and AX trees supplement the flow checks: the physical iOS accessibility projection may include scroll children outside the scroller viewport, so tree existence alone is not proof that content is unobscured. The action buttons are outside that viewport and were visually inspected at top and bottom. The before/after full-resolution diff reports 5.49% pixel mismatch localized to the bottom action area (capture pixels include device orientation metadata). This is expected layout change, not a zero-diff regression assertion.

Flows: `.argent/flows/iphone13-wow-actions.yaml` and `.argent/flows/iphone13-wow-actions-connected.yaml`. The offline flow requires an existing saved pairing, Getting started as the launch destination, pending WoW milestone, and no active phone connection. The connected fragment requires Getting started foregrounded and an active receiver connection. Four explicit raw swipe gestures in the offline flow intentionally exercise fixed footer stability at multiple offsets on iPhone 13 landscape; taps use semantic labels. Replay with an explicit device argument. Neither flow confirms gameplay.

A fresh private invitation was used only to stage connected state. Its first attempt had expired; restarting the QA receiver produced a fresh invitation and pairing succeeded. No invitation URL is saved in these artifacts. The receiver was restored without the QA export, the phone returned to Getting started, and only this iPhone’s Argent services were stopped.

Actual WoW gameplay and simultaneous two-finger input remain outside this UI retest. Physical Argent does not support multi-touch or screen recording; no motion-performance or Dynamic Type claim is made.
