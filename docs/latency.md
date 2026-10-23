# Phone-to-Mac latency — October 23, 2026

Follow-up: [Wi-Fi isolation and authenticated UDP comparison](network-udp.md) adds native/Mac monotonic clock bounds, explicit expiry counters, physical WebSocket/UDP/WebSocket trials on both phones and live packet-security checks. UDP remains opt-in; no consistent improvement was established.

## Measurement boundary

Bundled Release apps on the physical Pixel 7 (Android 17/API 37) and iPhone 13 Pro Max (iOS 26.3.1), with the signed macOS receiver on the same local Wi-Fi. Metro is not involved. The Mac is also running WoW and other development workloads; this is a live LAN sample, not an isolated RF laboratory.

The opt-in benchmark records six fields per acknowledged input: source (touch, heartbeat, neutral), JavaScript input-handler-to-ACK duration, native socket-send-to-native-ACK duration, Mac receive-to-successful-HID-submission duration, Mac receive-to-ACK-preparation duration, and the difference between JS and native RTT. This last difference includes controller mapping/serialization, synchronous bridge entry and native-to-JS event scheduling; it is not all forward input delay.

Phone and Mac clocks are not subtracted. Each duration uses a monotonic clock on the same device. The native RTT minus Mac HID-to-ACK preparation is an upper bound on native send-to-HID submission: it still includes the ACK's return trip. It must not be presented as an exact one-way result or as proof of the under-20ms p95 target. Physical touchscreen sampling, OS-to-JS touch delivery, GameController consumption and WoW's rendered frame are outside these measurements.

Rows are recorded only after an ACK for a still-pending sequence; packets discarded during lease expiry, pauses, connection loss or superseding ACKs are absent. Tail percentiles therefore describe acknowledged samples, not an unbiased latency distribution across all attempted inputs. Neutral reset counts indicate recovery activity but are not a direct pause count. The existing 150ms receiver watchdog and fresh-lease neutral recovery remain enabled throughout.

## Reproduction

1. Install bundled Release phone builds and build the signed Mac receiver as described in the main README.
2. Launch the receiver with `TAPPING_LATENCY_FILE=/absolute/private/path/run.jsonl` (and optionally the private invitation export used by local QA). Without this environment variable, timing export is disabled. The output file is created with mode 0600 and contains only source labels and numeric durations, never pairing secrets, controller state, network identifiers or device identifiers. Export writes run on a separate utility queue.
3. Pair one phone and leave the controller in the foreground, screen on. The final build contains no Wi-Fi lock. The historical off/on/off experiment used a temporary benchmark-only switch in the same Android binary; its candidate and switch were removed after failing to improve the results.
4. Replay `.argent/flows/latency-pixel-trigger.yaml` on the Pixel or `.argent/flows/latency-iphone-trigger.yaml` on the iPhone. Both are fragments requiring the already-paired foreground controller. They use AX-derived, device-specific raw Down/Move/Up gestures to preserve analog timing; the Pixel additionally needs the documented Argent landscape coordinate transform. They are not portable selector-only regression tests. Each trace checks that the controller returns to neutral.
5. Disconnect to flush the final partial batch, then run `node tools/summarize-latency.mjs /path/run.jsonl`. Percentiles use nearest-rank ordering. The first samples include connection warm-up. Diagnostics add a small return-direction export batch every 20 acknowledged inputs; the same instrumentation must be used in every comparison.

The exploratory `latency-baseline` captures preceded the source-label correction and must not be used for touch-only claims. Final off/on comparison captures use the same Android binary and corrected source labels.

## Recorded results

These are native **round-trip** measurements across all acknowledged sources, mostly 33ms heartbeats. Values are milliseconds. Unequal run lengths, changing LAN load, recovery censorship and the small Android touch-only sample prevent a causal claim about whole-path latency. Raw timing rows and summaries are retained in [evidence/latency](evidence/latency).

| Run | Acknowledged samples | Native RTT p50 | Native RTT p95 | Mac receive → HID p95 |
| --- | ---: | ---: | ---: | ---: |
| iPhone baseline | 2796 | 9.364 | 53.956 | 0.253 |
| Pixel Wi-Fi lock off, first | 2881 | 13.753 | 34.510 | 0.204 |
| Pixel Wi-Fi lock on | 3545 | 12.858 | 35.077 | 0.218 |
| Pixel Wi-Fi lock off, reversal | 1180 | 12.618 | 25.247 | 0.165 |
| Pixel direct parser, no lock | 2561 | 13.415 | 60.211 | 0.180 |

The iPhone has 108 acknowledged touch-handler samples. Its touch-only native RTT p50/p95 are 8.763/24.068ms. Pixel control runs have only 15 and 13 acknowledged touch samples; do not treat their touch-only p95 as a stable estimate. The continuous custom gesture does not guarantee delivery of all injected Move events through RN, and a safety pause also cancels touch ownership. The on run has 98 touch samples, another reason not to attribute its aggregate distribution solely to the lock.

The receiver is a small part of the measured duration. Both phones have longer native RTT tails; Android also shows significant native-to-JS acknowledgement scheduling delay. ACK scheduling affects lease recovery and the displayed RTT, but cannot be equated with delayed arrival of the already-sent input at the Mac. The under-20ms p95 phone-to-game target remains unproven.

## Optimization retained

The receiver previously encoded the already-decoded state dictionary back into JSON and decoded it a second time. `PadState.parse` now validates the seven numeric fields directly, rejects booleans, strings, non-finite numbers, fractional/out-of-range button masks, extra/missing fields and out-of-range axes/triggers.

The [five-round isolated benchmark](evidence/latency/parser-benchmark.txt) compares 20,000 parses per path per round with optimization enabled. The saved run takes 4.64–4.86µs per state on the original path and 0.56–0.59µs on the direct parser (about 8.1–8.4× faster). Earlier runs under greater host load were slower on both paths. This is a several-microsecond CPU saving, **not a demonstrated perceptible or end-to-end latency improvement**. Live receiver timings remain within run-to-run variation. The test suite checks 1,000 valid states for matching HID bytes and numeric agreement; removing the second text conversion can change a double below 1e-15, which the tests explicitly allow while requiring identical output reports.

Reproduce:

```sh
xcrun swiftc -O apps/receiver/Sources/Report.swift tools/latency-benchmark/main.swift -o build/latency-parser-benchmark
build/latency-parser-benchmark
xcrun swiftc -O apps/receiver/Sources/Report.swift tools/receiver-tests/main.swift -o build/receiver-report-tests
build/receiver-report-tests
```

## Experiment rejected

Android’s [`WIFI_MODE_FULL_LOW_LATENCY`](https://developer.android.com/reference/android/net/wifi/WifiManager#WIFI_MODE_FULL_LOW_LATENCY) was held only during a foreground controller session. System diagnostics confirmed a type-4 `Tapping:controller` lock and `is_low_latency_activated=true`; both off runs showed no held lock. The on run did not beat the surrounding off runs at native RTT p95. The lock, its permission declaration and benchmark control were removed. No battery-costly radio lock is retained on speculation.

## Final verification and next experiment

The final iOS and Android Release builds install and pair with the signed receiver. Recorded trace replay returns each controller to neutral. A separate GameController observer verifies LT 1.0 → 0.0 on both phones with timing capture disabled. All 29 JavaScript tests, receiver report/parser tests, six live authentication/watchdog/protocol checks, lint and type checking pass. See [final observer values](evidence/latency/final-gamepad-values.txt).

The next useful experiment is to isolate the network contribution: repeat the same workload with a wired Mac and a controlled access point, then distinguish outbound input delay from ACK return delay before selecting a new data transport. An authenticated datagram prototype is a candidate if TCP queueing is confirmed; the current evidence does not establish that cause. No claim is made that Wi-Fi power saving, TCP head-of-line blocking or a particular device caused the observed spikes.
