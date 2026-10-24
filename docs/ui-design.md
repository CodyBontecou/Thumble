# Thumble supporting UI

The non-controller UI takes its direction from https://myself.md: near-black
surfaces, off-white system type, small monospace section labels, thin neutral
borders, and generous spacing. The controller's geometry, spell art, touch
ownership, stick directions, and input transport are preserved.

## Design system

`apps/mobile/src/ui/design.js` holds the palette and shared primitives:

- Background #0A0A0A; surface #141414; raised surface #1F1F1F.
- Text #EDEDED; secondary text #A1A1A1; border #2E2E2E.
- System sans for display/body; Menlo on iOS and monospace on Android for labels.
- 8pt spacing rhythm; 24pt surface corners, 16pt grouped controls, pill actions.
- Landscape uses two columns at 680pt and up, with a single column below that.
- Safe areas belong to each modal. Longer content scrolls and type scales.
- Native modal transitions and a short fade for the controller menu/welcome.
  Press feedback uses opacity or a row highlight; no decorative motion.

The app currently deliberately uses its configured dark appearance. This change
introduces no third-party fonts or native UI dependencies.

## Surfaces

- Branded welcome introduces describing a controller and offers a direct route
  into setup or local practice.
- Resumable setup is implemented by the agent-onboarding work and uses the same
  design primitives. It tracks actual pairing separately from human-confirmed
  controller and game checks.
- The controller menu groups the current profile/connection and setup actions.
- Pairing offers QR scanning, a manual-link fallback, and inline errors.
- Profiles keep revision-safe selection and explicit selected/loading/error states.
- Stick calibration uses native switches and compact dead-zone choices.
- WoW setup, chat options, and pause/demo dialogs use the same neutral styling.
- Pro shows a one-time price, demo alternative, restore and retry controls.
  All features are included in the 30-minute connected-use demo; Pro removes
  only the time limit. Actual charging is disabled while the native store and
  entitlement configuration are incomplete. This UI work does not validate real
  store transactions or change the metering/security contract.

## Verification boundaries

Simulator screenshots and flow recordings live in `docs/evidence/ui-redesign/`
and the ignored `.argent/recordings/` directory. Profile presentation QA uses
synthetic fixtures on an isolated pinned-TLS server that discards every input;
it never opens HID or modifies saved player profiles. This is visual/navigation
QA, separate from physical game-input verification.

## October 23 verification

- Release simulator and signed iPhone builds succeeded. The staged phone app is
  `build/UI Redesign iPhone.app` (current app identifier `com.thumble.ios`, following
  the concurrent Thumble naming update).
- Mobile lint/typecheck and all 90 JavaScript tests passed after integration.
- Inspected welcome, resumable setup hub, menu, Pro, pairing, keyboard avoidance,
  calibration, and profiles in the landscape simulator. Synthetic profile
  selection returned a rendered/acknowledged Selected state.
- Verified skipping the welcome and restarting returns to the controller; the
  setup hub remains available from the menu. The separate agent-onboarding work
  verifies saved preferences, agent checks, and first-layout milestones.
- Recorded and inspected native transitions, menu/Pro presentation, and return
  to controller. Latest video: `.argent/recordings/ui-redesign-flow.mp4`.
  Recording is 30fps; no 60fps performance measurement is claimed.
- Evidence: `welcome.png`, `menu.png`, `pro.png`, and `pair-keyboard.png` in
  `docs/evidence/ui-redesign/`. Font-size stress testing beyond the simulator's
  current system setting and real store transactions remain unverified.
