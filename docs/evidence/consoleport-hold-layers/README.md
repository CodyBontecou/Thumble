# ConsolePort held layers

Verified October 24, 2026. Holding LT, RT, or both updates the built-in ConsolePort action buttons immediately, using physical chord labels such as `RT + A`. Sticks, trigger labels, menus, geometry and emitted gamepad mappings stay stable. Release, cancellation and profile replacement clear the held presentation through the existing input reset path.

Character profiles use their exported modifier assignments and action labels, including swapped triggers, combined modifiers, and explicitly empty slots. A configured `none` modifier is respected. Without an export the built-in layout does not claim to know character spells or WoW's Shift/Ctrl assignments. Exports remain snapshots; live page, stance and cooldown updates are not added.

The screen now derives its modifier prefix from the same profile that produced the input state, supplied by TouchController's state callback, rather than independently looking up a connection or cloud profile.

Validation:

- Controller regressions exercise both trigger orders, independent release while an action remains held, actual gamepad output, character modifier assignments, complementary trigger labels, reset and profile replacement.
- Mobile lint and typecheck passed. Production iOS JavaScript bundle exported successfully.
- Isolated simulator app `com.thumble.consoleportlayersqa` uses a copy of the existing simulator binary plus the updated production JS bundle. No physical phone installation or live WoW test was performed.
- `.argent/e2e/consoleport-hold-layers.yaml` replay passed: 12 executed gestures/checks, zero failures/errors. The fragment requires that isolated app in offline ConsolePort practice, neutral input, and the recorded landscape orientation. Run with `argent e2e run consoleport-hold-layers --device <simulator-udid>` after staging that state.
- Raw touch gestures intentionally preserve a finger down across accessibility checks and support the simultaneous two-finger hold. Coordinates were read from the simulator accessibility tree; this fragment is tied to its viewport. Accessibility waits remain raw because AXButton labels differ from the native runner tree. Each hidden check follows a successful visible check on the same label and its removing release.
- Recorded video reviewed as a filmstrip confirms stable button positions and all four presentations. Video is ignored by Git at `.argent/recordings/screen-recording-87952CD2-B760-40A1-AF11-5CE40995960B-1792865701521.mp4`.
