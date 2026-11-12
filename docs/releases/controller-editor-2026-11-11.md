# In-app controller customization release

The phone editor supports dragging and resizing the actual controls, adding and removing controls, labels, gamepad outputs, stick calibration, encrypted drafts and local practice. The receiver saves and activates an exact phone revision after validation and rendered-layout acknowledgement. WoW spell proposals require the player's final Review and Apply in the addon.

This release combines the existing redesign/reconnect branch and iOS release validation before adding controller customization. Unrelated website and download-service edits from the development workspace are excluded.

## Verification

- Isolated source: 299 tests pass; mobile lint and typecheck pass. The release gate also runs the layout-editor regression tests.
- Argent iPhone simulator: drag/resize, labels/output edits, persistence, discard protection, add/remove, stick settings, practice and isolated receiver activation checked.
- Argent Android 15 foldable emulator: drag/resize to the 48-point minimum, labels/output edits, encrypted persistence, hardware Back/discard, add/remove, stick settings, whitespace-only name rejection, practice and isolated receiver activation checked. Receiver profile data matched the saved Android draft.
- Practice inputs remained neutral at the receiver stub. Physical gameplay and purchases were not exercised in these editor QA passes.
- QA fixes: semantic dirty-state comparison; minimum resize targets (48-point buttons/triggers, 96-point sticks); blank layout names blocked; saved/applied feedback hidden while the draft has unsaved changes.

## Outstanding finding

Intermittent Android receiver disconnect/reconnect failures occurred in the development environment, including after Fast Refresh. One complete Apply round trip succeeded and its saved profile was inspected. Continuous connectivity is not a passed check. Verify the signed release artifact separately; the cause of these development-session reconnect failures has not been established.

## Distribution

Store build IDs, artifact hashes, smoke receipts and submission results must be recorded after the production artifacts are generated. Simulator development-client QA does not replace production launch validation.
