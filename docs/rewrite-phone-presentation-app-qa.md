# Actual phone presentation UI witness

`Rewrite/tooling/run_presentation_app_probe.py` runs the bundled Android QA app
against the independent recording-only `presentation-service-probe.ts`. It never
uses the active physical Mac receiver, game, capture permissions or a supplied
controller-map test provider. Select the owned `emulator-5580` explicitly.

The instrumentation test follows the visible **Test a connection** route, enters
the synthetic invitation in the native field and waits for actual admission. It
finds the installed South region by its native map ID and injects an OS touch.
The real service recording must show at least 1.5 seconds of uninterrupted held
South, no neutral pulses and the unchanged 350 ms input TTL across a source CAS
that changes only the label/icon. The existing input generation remains active.
A separate valid source CAS then moves the saved rectangle while leaving the
activated input binding unchanged. The UI must display **Game data stale** while
retaining its installed map/icon and uninterrupted South hold. Done must return
Home and the real receiver must acknowledge neutral release.

The pixel oracle draws the actual mounted React image view into a bitmap. Its
center must change from RGB(24,64,168) to RGB(144,64,48), within two channel levels.
This exercises the native role10 client, bridge notification, strict React
notification admission and actual PNG rendering. It does not count model or AX
label checks as image evidence. The native view must observe the OS night-mode
transition while input remains held; the prior OS setting is restored afterward.

The runner requires exactly the named instrumentation case, no failures and no
skips. A bounded PNG screenshot is transferred through a QA-only loopback POST
before Gradle uninstalls the QA package. Raw UI logs, invitations, native helper
output and screenshots remain under `RUNNER_TEMP`; stdout contains only the fixed
outcome and counts. The helper and this side channel are absent from product UI.

## Measured scope

Local owned-emulator runs passed the actual image/source-refresh/held-input/Done
sequence. A native night-mode barrier initially exposed a light React palette;
the separate reactive semantic-palette correction now has an actual dark screen
screenshot with readable labels. The final witness also passed the valid geometry
CAS/stale UI case while native South remained held across both source writes.
The equivalent iOS actual PNG route remains a separate acceptance gap. This
witness does not claim game freshness, gameplay, physical haptics or physical
multitouch acceptance.
