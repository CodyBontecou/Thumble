# Local controller protocol v3 (v1 pairing invitations)

An opt-in authenticated UDP input experiment uses the same pairing/control session and freshness checks. It remains disabled by default because physical-device testing did not establish a consistent improvement. See [UDP framing, security, measurements and reproduction](network-udp.md).

The QR URI is `tapping://pair?data=<base64url JSON>`. Its object contains `v:1`, a private IPv4 `wss://<ip>:<port>/controller` URL, SHA-256 leaf certificate hex `pin`, random 256-bit hex `token`, and Unix-seconds `expires`. Treat the whole invitation as a secret. Never log it or put it in source control. The Mac's optional `TAPPING_INVITATION_FILE` environment variable exports it to a mode-0600 local file for opt-in QA only.

For local MCP chat pairing, the receiver caches a QR PNG (not the raw URI) in `pairing-code.json` in the profile directory (`TAPPING_PROFILE_DIR` or `~/Library/Application Support/Tapping/profiles`). This image carries the same secret as the invitation: never publish, log or commit it. The file is atomically created with mode 0600, refreshed every second, and removed when paired, expired, or stopped. The MCP tool rejects files with group/other access, symlinks, expired codes, and heartbeats older than five seconds, including crash leftovers. Chat history may retain the image after its single-use invitation expires.

Optional hosted pairing uploads the QR PNG only after explicit Mac OAuth consent. A ten-minute account-bound sharing session exposes it through authenticated `show_pairing_code`; no LAN addresses are fetched by the cloud service. Paired-phone state clears it; stale/expired sessions are unreadable. See [hosted pairing](hosted-mcp.md#pair-a-mac-from-chatgpt).

TLS 1.2+ with certificate pinning supplies confidentiality and authenticates the Mac named in the QR. Pinning is scoped to this connection's URLSession/OkHttp client; the app never changes platform-wide certificate validation. The expiring single-use token authenticates the first phone. Only one authenticated connection can emit input; at most four unauthenticated transports may exist, each with a five-second deadline. Phone-to-receiver messages are bounded to 4096 bytes except authenticated profile-save/profile-adopt messages, which may use up to 65536 bytes. Receiver-to-phone messages are bounded to 65536 bytes to carry declarative layouts.

Phone sends `{"type":"hello","v":3,"phoneId":"UUID","token":"...","desktopInput":1}`. Current receivers require v3. On first pairing the receiver returns a separate random `reconnectToken`; subsequent handshakes send it instead of the QR token. The phone stores the receiver URL, certificate pin and reconnect credential in device-only secure storage. The receiver persists its TLS identity, stable port and remembered-phone trust; explicit Forget revokes trust. A remembered phone can replace its lingering authenticated socket, releasing all previous input. Invalid remembered trust returns `forgotten` and stops automatic retries. Mac consumes the token and replies `{"type":"ready","seq":-1,"lease":"..."}`. Each input is the complete current state:

```json
{"type":"input","seq":1,"lease":"server-issued value","revision":0,"state":{"buttons":0,"lx":0,"ly":0,"rx":0,"ry":0,"lt":0,"rt":0}}
```

Buttons use the shared controller package's bit order. Axis Y is positive up, matching the HID report without inversion. Sequences strictly increase within this connection and reset on fresh pairing. Invalid state, duplicate sequence, or transport failure disconnects and releases all input. Expired or unknown leases are discarded without refreshing the watchdog.

The Mac acknowledges each applied report with `{"type":"ack","seq":1,"lease":"new value"}`. A lease expires 500 ms after the Mac issues it, using the Mac's monotonic clock. The phone echoes the most recently received lease. The separate lease budget covers both network legs and phone callback scheduling. No wall-clock synchronization is needed for input freshness. Watchdog expiry revokes every lease, including ones still inside that budget.

After 300 ms without accepted input, the independent 20 ms receiver timer writes neutral and enters a paused state. It sends `{"type":"paused","seq":1,"lease":"fresh value"}` every 80 ms. The phone clears touch ownership and pending states, then echoes a fresh lease with neutral input. New touch acquisition waits for the neutral acknowledgement. Only neutral can resume a paused connection; buffered held input cannot re-arm it. Two seconds without accepted input closes the session. The phone closes after 1.5 seconds without receiver messages. These are safety deadlines subject to OS scheduling, not hard real-time guarantees. The earlier 150/150 ms receive/lease policy interrupted real physical holds during 151–188 ms Wi-Fi gaps; see the hold-reliability evidence.

Touch transitions send outside React rendering; a 33 ms heartbeat resends the current state. Native socket write capacity controls backpressure, independently of network ACK return: iOS reserves two of its eight pending-write slots for control traffic, while Android bounds queued WebSocket bytes. A blocked outbox retries after 8 ms. Additional motion snapshots with the same button and trigger ownership coalesce, while press/release transitions stay ordered in a bounded 64-entry outbox. Heartbeats replace redundant heartbeat snapshots but never refresh the age of a queued press. Queued input older than 150 ms is cancelled and touch ownership released; it is never replayed after a pause. Outbox overflow or 256 unacknowledged inputs closes safely. Older native builds without capacity reporting use a conservative four-ACK fallback. Receiver expiry independently neutralizes input if JavaScript pauses. `{"type":"bye"}` disconnects explicitly. Backgrounding the phone closes the connection and releases input while retaining trust. Foregrounding reconnects with bounded backoff. A fresh scan is needed when trust was forgotten, expired or invalidated.

The displayed round-trip sample measures JS submission through Mac HID report completion and its acknowledgement back to JS. It excludes the touch sample before submission, game frame scheduling, display scanout, and Wi-Fi worst-case tails. It is not advertised as touch-to-game latency.

## Live layout activation

Pairing invitation version remains 1. Phones negotiate application protocol 3 in `hello`. Inputs include `revision` (0 for the built-in layout). The receiver ignores wrong-revision input without refreshing the watchdog, even if its lease would otherwise be valid.

The local profile MCP tools validate and atomically save a whole profile, then activate a particular saved revision. The receiver observes activation off the input queue. Before publishing `{"type":"layout","revision":1,"profile":{...}}`, it successfully writes neutral HID state and clears all old leases. It blocks input until the phone validates the profile, commits its renderer/touch controller and sends `{"type":"layout-ready","revision":1}`. A layout acknowledgement is not a gameplay input.

The receiver then sends `paused` with a fresh lease. The phone releases touch ownership again and sends neutral input with the new revision; normal input resumes through the existing neutral recovery rule. Superseded layout acknowledgements are ignored. Future acknowledgements disconnect. A pending layout has a five-second deadline; normal input watchdog processing resumes after acknowledgement. The phone's own 1.5-second receive deadline can close sooner if its renderer stalls.

Every reconnect receives the currently active saved profile. If the receiver has no activation, the phone uses its built-in layout at revision 0. Older application-protocol clients must update before connecting to current receivers. Layouts contain no executable code or spell-casting instructions, and the MCP server has no input-generation tools. See [agent profiles](agent-profiles.md).

## Phone canvas capability

New receivers advertise `viewport:1` in `ready`. Only then does the phone send
`{"type":"viewport","width":844,"height":390}` on authenticated TLS. Dimensions
are logical points of the usable controller canvas after safe-area subtraction,
finite and positive, bounded to 10000, with width greater than height. Portrait
transitions are not published. This message carries no input and refreshes neither
leases nor the input watchdog. It is not accepted over UDP.

The receiver publishes the current session's viewport in its status snapshot;
disconnecting clears it. Studio automatically uses a connected phone's size for
preview, target validation and save/send. Native adapters prefer the current
reported size to a workspace-supplied size. Offline and older receivers retain the
manual size picker. The phone republishes its measured canvas after reconnect.

## Plan access

Pairing and profile delivery work before purchase. Game input and chat require a
verified, unexpired signed plan grant and neutral recovery. `access-pause` releases
output; `access-resume` requests play but cannot bypass grant verification.
`remaining` and `debitedUsed` remain in access responses for compatibility and
always report zero remaining time and a spent old demo. Current phones neither
read nor write demo usage. Legacy receiver records and native storage namespaces
are preserved to avoid rotating installation or receiver identities.
