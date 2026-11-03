# Thumble supporting UI

The redesign is published as a Design canvas (Thumble WoW Redesign). Two looks,
one rule: the controller follows ConsolePort, everything around it follows
Thumble's "Cartridge" style, taken from the app icon.

## Design system

`apps/mobile/src/ui/design.js` holds the tokens and primitives:

- Ground #9F9E9C (the icon's own grey); bone #EAE1D0 panels; inset #D6CCB9;
  ink #24211F outlines and text; orange #F56807 for one primary action per screen.
- 3px ink outlines, 4–6px corners, hard offset shadows; pressed controls lose
  their shadow and shift 3px.
- Pixelify Sans for headlines and buttons, Silkscreen for small labels, Inter
  Tight for body copy, loaded with expo-font.
- Every new screen adapts to portrait and landscape. Setup can be done upright;
  the controller stays landscape and the Rotate screen hands off to it.
- The ConsolePort controller keeps its own dark palette, artwork and ABXY
  colours. Its Thumble chrome is a bone status pill, Chat and an orange menu.

## Flow

Welcome → paywall carousel (Controller preview with full screen, Setup
features, Plans with the trial timeline) → Connect (three detected lights:
paired, gamepad live, ConsolePort labels) → Rotate (portrait only) → coached
Practice on the controller → controller. A lapsed plan shows Access ended; a
dropped link shows Connection lost over the controller.

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
