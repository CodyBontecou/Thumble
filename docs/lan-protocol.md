# Local controller protocol v2 (v1 pairing invitations)

An opt-in authenticated UDP input experiment uses the same pairing/control session and freshness checks. It remains disabled by default because physical-device testing did not establish a consistent improvement. See [UDP framing, security, measurements and reproduction](network-udp.md).

The QR URI is `tapping://pair?data=<base64url JSON>`. Its object contains `v:1`, a private IPv4 `wss://<ip>:<port>/controller` URL, SHA-256 leaf certificate hex `pin`, random 256-bit hex `token`, and Unix-seconds `expires`. Treat the whole invitation as a secret. Never log it or put it in source control. The Mac's optional `TAPPING_INVITATION_FILE` environment variable exports it to a mode-0600 local file for opt-in QA only.

TLS 1.2+ with certificate pinning supplies confidentiality and authenticates the Mac named in the QR. Pinning is scoped to this connection's URLSession/OkHttp client; the app never changes platform-wide certificate validation. The expiring single-use token authenticates the first phone. Only one authenticated connection can emit input; at most four unauthenticated transports may exist, each with a five-second deadline. Phone-to-receiver messages are bounded to 4096 bytes. Receiver-to-phone messages are bounded to 65536 bytes to carry declarative layouts.

Phone sends `{"type":"hello","v":2,"token":"..."}`. Mac consumes the token and replies `{"type":"ready","seq":-1,"lease":"..."}`. Each input is the complete current state:

```json
{"type":"input","seq":1,"lease":"server-issued value","revision":0,"state":{"buttons":0,"lx":0,"ly":0,"rx":0,"ry":0,"lt":0,"rt":0}}
```

Buttons use the shared controller package's bit order. Axis Y is positive up, matching the HID report without inversion. Sequences strictly increase within this connection and reset on fresh pairing. Invalid state, duplicate sequence, or transport failure disconnects and releases all input. Expired or unknown leases are discarded without refreshing the watchdog.

The Mac acknowledges each applied report with `{"type":"ack","seq":1,"lease":"new value"}`. A lease expires 500 ms after the Mac issues it, using the Mac's monotonic clock. The phone echoes the most recently received lease. The separate lease budget covers both network legs and phone callback scheduling. No wall-clock synchronization is needed for input freshness. Watchdog expiry revokes every lease, including ones still inside that budget.

After 300 ms without accepted input, the independent 20 ms receiver timer writes neutral and enters a paused state. It sends `{"type":"paused","seq":1,"lease":"fresh value"}` every 80 ms. The phone clears touch ownership and pending states, then echoes a fresh lease with neutral input. New touch acquisition waits for the neutral acknowledgement. Only neutral can resume a paused connection; buffered held input cannot re-arm it. Two seconds without accepted input closes the session. The phone closes after 1.5 seconds without receiver messages. These are safety deadlines subject to OS scheduling, not hard real-time guarantees. The earlier 150/150 ms receive/lease policy interrupted real physical holds during 151–188 ms Wi-Fi gaps; see the hold-reliability evidence.

Touch transitions send outside React rendering; a 33 ms heartbeat resends the current state. Native socket write capacity controls backpressure, independently of network ACK return: iOS reserves two of its eight pending-write slots for control traffic, while Android bounds queued WebSocket bytes. A blocked outbox retries after 8 ms. Additional motion snapshots with the same button and trigger ownership coalesce, while press/release transitions stay ordered in a bounded 64-entry outbox. Heartbeats replace redundant heartbeat snapshots but never refresh the age of a queued press. Queued input older than 150 ms is cancelled and touch ownership released; it is never replayed after a pause. Outbox overflow or 256 unacknowledged inputs closes safely. Older native builds without capacity reporting use a conservative four-ACK fallback. Receiver expiry independently neutralizes input if JavaScript pauses. `{"type":"bye"}` disconnects explicitly. Backgrounding the phone also closes the connection; returning requires a fresh scan.

The displayed round-trip sample measures JS submission through Mac HID report completion and its acknowledgement back to JS. It excludes the touch sample before submission, game frame scheduling, display scanout, and Wi-Fi worst-case tails. It is not advertised as touch-to-game latency.

## Live layout activation

Pairing invitation version remains 1. Updated phones negotiate application protocol 2 in `hello`; protocol 1 is accepted only for the built-in layout. Protocol 2 inputs include `revision` (0 for the built-in layout). The receiver ignores wrong-revision input without refreshing the watchdog, even if its lease would otherwise be valid.

The local profile MCP tools validate and atomically save a whole profile, then activate a particular saved revision. The receiver observes activation off the input queue. Before publishing `{"type":"layout","revision":1,"profile":{...}}`, it successfully writes neutral HID state and clears all old leases. It blocks input until the phone validates the profile, commits its renderer/touch controller and sends `{"type":"layout-ready","revision":1}`. A layout acknowledgement is not a gameplay input.

The receiver then sends `paused` with a fresh lease. The phone releases touch ownership again and sends neutral input with the new revision; normal input resumes through the existing neutral recovery rule. Superseded layout acknowledgements are ignored. Future acknowledgements disconnect. A pending layout has a five-second deadline; normal input watchdog processing resumes after acknowledgement. The phone's own 1.5-second receive deadline can close sooner if its renderer stalls.

Every reconnect receives the currently active saved profile. If the receiver has no activation, the phone uses its built-in layout at revision 0. A legacy phone is disconnected with an update status when a custom layout is active. Layouts contain no executable code or spell-casting instructions, and the MCP server has no input-generation tools. See [agent profiles](agent-profiles.md).
