# Input delivery and sustained holds — October 23, 2026

This work follows the [transport comparison](network-udp.md). Wi-Fi spikes remain; changing transports did not consistently help. The reliability changes address burst backpressure and timeout-induced loss of touch ownership.

## Reproduced failures and fixes

- A deterministic 200-update touch burst disconnected the old JavaScript sender before ACK callbacks ran. A bounded outbox now coalesces redundant motion while preserving button and trigger ownership transitions. A blocked native socket is retried after 8 ms. iOS reserves capacity below its eight pending-write cap; Android checks queued WebSocket bytes. ACK bookkeeping is separately bounded to 256 inputs. A slow ACK return path does not stop forward heartbeats.
- An initial four-ACK send window passed burst tests but failed stronger physical movement checks: it could starve forward heartbeats during a delayed ACK return. That intermediate implementation was replaced with native write-capacity reporting. Its failed trace remains in the evidence directory; it is not counted as a final pass.
- Another intermediate queue policy let an old heartbeat falsely cancel a sustained hold after about 3.15 seconds. Heartbeats now replace older heartbeat snapshots, while never refreshing a queued press. Queued press/motion history older than 150 ms is cancelled; held input is never replayed after recovery.
- The original 150 ms receive timeout and 150 ms lease budget cut off a physical five-second iPhone hold after 2.27 seconds. The coordinated [isolated comparison](evidence/hold-reliability/physical-hold-summary.json) reproduced 151–188 ms input gaps. The receiver now has a 300 ms silence timeout and a separate 500 ms lease budget. Genuine silence releases later than before; backgrounding/disconnect still release immediately. Pausing revokes leases and requires a fresh neutral acknowledgement before new touch acquisition.

The queue regression tests exercise real connection state transitions, delayed ACKs, native backpressure, edge ordering, old queued input, sustained heartbeat freshness and disconnect cleanup. Native receiver tests accept 190 ms gaps, require pause at 301 ms and reject leases at 501 ms. Live WebSocket and encrypted UDP checks verify authentication, replay rejection, stale lease rejection, neutral-only recovery and session revocation.

## Physical verification method

Release builds are tested over local Wi-Fi. Completed iOS results below use the physical iPhone 13 Pro Max; remaining iOS checks move to the iPhone 17 Pro at the user’s request. Pixel 7 verification is tracked separately. The signed Mac receiver applies actual virtual HID reports. WoW Classic and ConsolePort run in Northshire Valley. Tests use an isolated empty profile directory, preserving the user's saved profiles. Test gestures send movement, camera and jump inputs. Local read-only `/dump` commands check controller enablement and active device; no public chat messages or combat actions are sent.

An opt-in `TAPPING_INPUT_AUDIT_FILE` records successful HID report bytes, monotonic submission timestamps and native return codes on a separate writer queue. It includes controller state, so it is QA-only and disabled in normal use; it contains no pairing secrets, network identifiers or chat. A separate GameController observer supplies additional operating-system-level observations.

The recorded `reliability-iphone-gameplay` fragment performs LT for five seconds, four movement directions for two seconds each, two camera directions for half a second each and A for 100 ms. Coordinates come from accessibility frames; these are device-specific profiling fragments. The Pixel requires Argent's observed landscape coordinate transform. A standalone audit assertion checks every expected run, its order, duration and final neutral state. A screen-presence check alone is not a connected/gameplay verdict. WoW is visually checked between batches.

`node tools/assert-input-hold.mjs /private/audit.jsonl --reset` sets the byte cursor before a replay. `node tools/assert-input-hold.mjs /private/audit.jsonl 5000 --gameplay` checks the eight-control cycle afterward. The audit confirms HID submission, not exact game-frame latency. Physical comparisons on shared Wi-Fi are not a production reliability guarantee or a substitute for longer player sessions on other networks.

## Completed iPhone 13 Pro Max batch

The final native-capacity build completed six eight-control cycles: 48 expected control runs, all passing the independent HID audit, including final neutral state. Five-second LT runs lasted approximately 4.87–4.96 seconds. The 100 ms A presses produced HID holds of approximately 24–237 ms on this shared Wi-Fi network; this demonstrates delivery, not tight latency consistency.

The connection remained up for more than six minutes, including idle intervals. One pause recovered outside the validated cycles; the session was not pause-free. Movement was visibly confirmed in WoW Classic Era 1.15.9 with ConsolePort 3.3.11 after restoring game focus. These results do not qualify a different WoW client or an entire public release.

The iPhone 13 Pro Max was unplugged at the user’s request. Remaining iOS verification uses the iPhone 17 Pro; do not attribute the completed 13 results to the 17. Final iPhone 17 and Pixel results follow below. Intermediate failed traces and completed 13 audit/timing exports are retained separately in [evidence/input-reliability](evidence/input-reliability).


## Remaining tests moved to iPhone 17 Pro

| Device | Full cycles | Expected control runs | Failed cycles | LT hold range | 100 ms A HID hold range | Recovered pauses in session |
| --- | ---: | ---: | ---: | --- | --- | ---: |
| iPhone 17 Pro | 6 | 48 | 0 | 4.90–5.13 s | 32–239 ms | 1, outside validated cycles |
| Pixel 7 | 6 | 48 | 0 | 4.98–5.15 s | 70–182 ms | 0 |

Each batch includes one recorded walkthrough and five complete replays with the independent HID assertion. The iPhone 17 batch spans more than five minutes and the Pixel batch about three minutes, including idle intervals. Every cycle ended neutral. There were no connection stalls requiring reconnection in these final batches. The recovered iPhone pause and wide short-press duration range mean these are successful delivery checks, not consistent low-latency qualification.

Backgrounding the iPhone 17 changed its status to practice/disconnected and the receiver to controls released, with a neutral audit report. On Pixel, the audit first confirmed LT=255 while a touch remained down; pressing Home then produced LT=0 and an entirely neutral report. No exact background-release latency is claimed from tool completion times.

WoW remained responsive with ConsolePort. A dedicated iPhone 17 directional hold visibly changed the game view, and the Pixel cycles changed terrain/camera orientation while the character remained alive. The HID assertions validate input submission and hold continuity; screenshots do not establish that every short press was consumed by a specific game frame. This was a short movement/camera/jump session, not a prolonged combat soak.

The device-specific fragments are `.argent/flows/reliability-iphone17-gameplay.yaml` and `.argent/flows/reliability-pixel-gameplay.yaml`. Replay with `flow-execute`, the matching physical device, the project root, and its prerequisite acknowledged; set the audit cursor before each run and run the independent assertion afterward. Raw gestures retain the measured hold durations; positions come from fresh accessibility frames, with the documented Pixel landscape transform. These fragments require the built-in Xbox geometry and are not portable to other layouts.

[Machine-readable batch results](evidence/input-reliability/final-device-results.json), per-device final audit/timing exports, and intermediate failures are retained in the evidence directory. Final source checks passed: 78 JavaScript tests, mobile ESLint and TypeScript checking. Native timeout/report checks and live WebSocket/UDP security checks passed earlier in this investigation. Sustained physical gameplay here used default WebSockets; UDP remains opt-in.

## Development caveat

During earlier repeated receiver restarts, WoW hung in macOS game-controller device initialization and needed the user-approved restart. The final batches retained one HID device throughout phone switching and used an immutable copy of the signed receiver bundle. Building or re-signing the executable in place while it is running is unsafe; use a separate output bundle. These runs do not establish that repeated HID removal/recreation while WoW is open is reliable. Exit WoW cleanly before replacing the running receiver binary.
