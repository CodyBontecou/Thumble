# Wi-Fi transport comparison — October 23, 2026

Authenticated UDP is implemented and tested on the physical iPhone 13 Pro Max and Pixel 7. It remains an opt-in experiment: these runs do not establish a consistent latency improvement over pinned TLS WebSockets. The default receiver still uses WebSockets.

## Results

Bundled Release apps, signed Mac receiver, both phones and Mac on Wi-Fi. No Ethernet adapter was available. Each timing comparison uses the first 60 seconds after a five-second warm-up, nearest-rank percentiles, and identical instrumentation. Rows are mostly 33 ms heartbeats. All values below are milliseconds.

| Phone / run order | Accepted samples | Native RTT median | Native RTT p95 | Phone native send → Mac HID p95 bounds | Mac receive → HID p95 |
| --- | ---: | ---: | ---: | ---: | ---: |
| iPhone WebSocket 1 | 1561 | 10.95 | 33.71 | 10.83–17.10 | 0.168 |
| iPhone UDP | 1673 | 9.30 | 84.34 | 48.70–54.19 | 0.109 |
| iPhone WebSocket 2 | 1786 | 10.79 | 61.39 | 18.54–24.53 | 0.161 |
| Pixel WebSocket 1 | 1329 | 12.95 | 57.41 | 11.05–19.32 | 0.106 |
| Pixel UDP | 1405 | 11.26 | 43.43 | 17.08–24.72 | 0.166 |
| Pixel WebSocket 2 | 1496 | 12.74 | 21.30 | 8.40–16.26 | 0.118 |

The reversal is important: Pixel UDP beat the first WebSocket run's RTT p95, but the second WebSocket run beat UDP. iPhone UDP was worse than both surrounding WebSocket runs. There was also an iPhone UDP disconnection with “Connection stalled · controls released” after roughly two minutes. Its exact cause was not established. It is a failed reliability observation, not a successful soak test.

Twenty separately injected 150 ms LT presses per comparison were checked with an independent macOS GameController observer. It required an LT=1 report followed by all controls neutral after each press. Observed press/release pairs: iPhone WebSocket reversal 16/20, iPhone UDP 15/20, Pixel WebSocket 14/20, Pixel UDP 17/20, Pixel WebSocket reversal 14/20. Missing observations were retained as failures; these small automation samples do not isolate touchscreen injection, touch ownership cancellation, network delivery, or observer coalescing. They are not a release-quality input success rate. Every successful assertion required neutral, and the safety recovery continued to release controls.

## What the spikes isolate

Native send, Mac receive callback, successful HID submission, Mac ACK preparation, and native ACK receipt now have monotonic timestamps. Nearby exchanges constrain the inter-device clock offset without assuming symmetric network delay. The analysis uses a ±2 s neighborhood and an explicit 200 ppm relative drift allowance. Each sample bounds offset between `Mac ACK − phone receive` and `Mac receive − phone send`; bounds expand with sample distance. All selected exchanges have consistent bounds. A ±1 s / 500 ppm sensitivity result is retained alongside each summary.

Among native RTT spikes over 40 ms, the lower bounds identify a forward leg over 20 ms in 51/109/78 iPhone samples (WebSocket/UDP/WebSocket) and 49/63/41 Pixel samples. Return-only counts are 19/16/30 and 23/10/13; a few iPhone samples and one Pixel sample have both legs over 20 ms. Thus the large delays frequently precede the Mac receive callback on both transports. These boundaries include sender socket scheduling, network/radio/AP delivery, and receiver callback scheduling. They do not prove a specific radio, AP, TCP head-of-line blocking, or Wi-Fi power-saving cause. Mac receive-to-HID work is consistently tiny relative to the spikes.

The freshness mechanism is a second visible cost. Across the complete runs, roughly one fifth of transmitted snapshots reach the receiver with an expired server lease and are discarded. For example, iPhone WebSocket reversal recorded 5,359 sent, 4,280 acknowledged, and 1,079 expired-lease rejections. Pixel UDP recorded 2,215 sent, 1,743 acknowledged, and 461 expired-lease rejections. This is direct evidence of authorization expiry, not evidence that all those packets were lost in transit. Leases expire 150 ms after server issue; delayed return delivery or native-to-JS processing also consumes that budget. A pause cancels touch ownership and requires fresh neutral recovery. The experiment does not extend deadlines or replay stale held input to hide missed presses.

Pixel numeric Wi-Fi counter snapshots span about 16.8 minutes, including setup and iPhone testing: 4,920 successful transmissions, 594 retries, zero added failed transmissions, and 52,855 ms channel-busy time over 188,635 ms radio-on-frequency time. Retries represent about 10.8% of success+retry+bad attempts and busy/on time about 28.0%. RSSI was −61 dBm at both endpoints. These broad counters lack per-spike alignment and Mac/AP coverage; they are supporting context, not causal attribution.

## Limits

Only acknowledged, still-pending snapshots enter timing rows. Expired leases, superseded ACKs, pauses and disconnects censor the tail. The table therefore does not qualify all attempted inputs, physical touch-to-game latency, or an under-20 ms p95 target. Hardware touch sampling, OS-to-JS event delivery and WoW frame consumption remain outside the timing boundary. Timing windows match, but the whole runs and exact gesture timing differ. Wi-Fi load was uncontrolled; this was one WebSocket/UDP/WebSocket sequence per phone, not randomized trials. A controlled AP or wired Mac comparison is still needed to separate the two wireless legs.

Raw numeric timing batches, summaries, clock sensitivity runs and security results are in [evidence/udp](evidence/udp). No pairing keys, tokens, pins, SSIDs or IP addresses are retained there. Full-session counters in summaries have longer and unequal windows than the 60-second timing table.

## UDP protocol and safety

The phone advertises `datagram:1` in the existing authenticated hello. Only `TAPPING_INPUT_TRANSPORT=udp` enables the receiver offer. A fresh 256-bit session key and ephemeral UDP port travel exclusively inside the certificate-pinned WebSocket. Each datagram uses AES-256-GCM with AAD `tapping-udp-v1`, a 12-byte nonce (direction 1 phone / 2 Mac, then an increasing 64-bit big-endian counter), ciphertext and 16-byte tag. Maximum cleartext is 1,100 bytes. The receive replay counter advances only after authentication. Older reordered snapshots are discarded because inputs are complete states.

The receiver binds the first authenticated endpoint; unauthenticated endpoint allocation is bounded and timed out. Session disconnection destroys the listener and key capability. UDP carries only input/probe traffic and ACKs. Pairing, profile activation, pause recovery, diagnostics and disconnect control remain on reliable WebSockets. The phone switches only after an authenticated native UDP-ready reply; an unconfirmed handshake leaves WebSockets active. A failure after UDP activation releases/disconnects through existing safeguards rather than silently rearming input on another transport. The 150 ms watchdog, server leases, sequence and profile-revision checks remain enforced.

Swift and Java share an independently checked fixed AES-GCM fixture. Tests reject wrong keys, tampering, forged counters, reflection, replay, old reordered packets and oversized data. Live signed-receiver tests verify key rotation/revocation, fresh neutral recovery and rejection of expired leases and held recovery input. The JavaScript suite verifies negotiation and failure behavior. These checks do not constitute a production cryptographic audit. Public launch qualification and longer fault-injection/soak tests remain open.

## Reproduce

1. Build bundled Release phone apps and the signed receiver. Enable timing with `TAPPING_LATENCY_FILE=/absolute/private/path/run.jsonl`; add `TAPPING_INPUT_TRANSPORT=udp` only for the UDP run. Use a separate `TAPPING_PROFILE_DIR` for QA to preserve user layouts. Timing is disabled without its environment variable.
2. Pair one foreground phone. Check exported rows' final field is actually `udp`; do not label an unconfirmed fallback as UDP. Repeat WebSocket/UDP/WebSocket and disconnect to flush final batches.
3. Run `node tools/network-latency.mjs /path/run.jsonl`. It selects five-second warm-up plus 60 seconds. For gesture checks use `.argent/flows/network-iphone-trigger.yaml` or `network-pixel-trigger.yaml`, meet their prerequisites, and run the separate Mac HID assertion after every replay. These are device-specific profiling fragments, not portable regression tests. The old latency fragments expect a numeric readout now intentionally hidden while connected.
4. Run `npm test`, mobile lint/typecheck, `swift test --package-path tools/datagram-tests`, the Java cipher fixture, and `node tools/test-udp-receiver.mjs /private/invitation-file` against an opted-in receiver. The live test applies neutral states only.

A Pixel pairing crash exposed during this work was traced to the SDK 58 global imperative router being unbound on cold launch. PairScreen now uses its scoped `useRouter()` instance. A cold URI launch of the rebuilt Pixel app subsequently paired successfully.

Final verification: all 51 JavaScript tests, mobile lint/typecheck, five Swift crypto tests (including size cases), the Java fixture and four live receiver security groups pass. Final signed Release builds installed on both phones. The final Pixel test saw LT held at 1 immediately before Home and a fully neutral GameController report afterward. The iPhone's final post-rebuild UI check could not run because its device transport had changed to wireless; Argent requires USB on a physical iPhone. Earlier iPhone transport/HID comparisons used the preceding Release build; the only subsequent phone source change was the scoped-router fix. Final background verification loaded a saved Warrior profile, so it did not meet the standard-layout profiling fragment's prerequisite and is excluded from the benchmark gesture counts.

The receiver was returned to default WebSockets with timing export disabled and normal saved profiles. Temporary device automation services and the Mac observer were stopped.
