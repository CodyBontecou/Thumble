# Native phone input version 5

Swift and Kotlin opt into UDP input with `inputSessions:true, datagrams:true`. Default metadata control remains version 3; `inputSessions:true` alone retains version 4 and reliable-only delivery. The explicit version-5 hello, pinned TLS, native credential/epoch validation and exact acknowledged configuration precede every grant. The caller never receives a key, packet backlog or bridge representation. Physical receiver output remains disabled.

The [version-5 host contract](rewrite-native-input-control-v5.md) supplies one fresh grant for both UDP and TLS. UDP packets contain exactly the existing 108-byte AES-GCM input packet. A native sender owns one counter; transport selection consumes its already sealed packet. Fallback never encrypts again with a reused nonce, resets a counter, reinstates touches or creates another grant.

## Scheduling and fallback

The first neutral sequence-zero snapshot uses TLS. UDP setup runs independently: Network.framework asynchronously on iOS, a separate native setup worker on Android. Setup failure, delayed DNS or a stalled UDP open cannot delay neutral admission. If the first non-neutral/full-state offer encounters an unavailable UDP adapter, the route permanently selects TLS for that source.

Each UDP adapter retains one in-flight datagram and one replaceable latest sealed snapshot. Input/UI callbacks never perform blocking socket I/O or wait for setup. Closing discards pending work; an in-flight old packet can still arrive, so the native receiver's source/generation/replay fence remains authoritative. UDP has no phone-side receive surface and carries no plaintext control or credential material.

A native control heartbeat requests `input-status` approximately every 100ms, within the host's 1,024-control/60-second budget. Only receiver-acknowledged packet progress counts as delivery. The decoder validates exact connection, session, generation and revision, rejects acknowledgments beyond offered input or below previous progress, and treats inactive status as terminal. External control operations are serialized; a busy control channel may defer a heartbeat but cannot stop input sampling or its fallback watchdog.

The route tracks at most 64 outstanding sequence/time pairs, with no cached plaintext or ciphertext in that metadata. On a fresh sample, the oldest unacknowledged offer reaching 150ms, metadata capacity, or UDP offer failure selects TLS permanently. A partial acknowledgment removes only covered entries; it cannot reset the age of later outstanding packets. The fallback uses the current full-state packet, with its fresh counter, and discards no packet into a future connection. If both transports fail, time rolls backward, scope/counter changes or native progress is invalid, the source closes. The engine clears touches immediately on Swift; Android observes worker failure and clears on its next native UI frame, with UI-driven cancellation immediate.

The 150ms watchdog targets the CLI's current 350ms input TTL and requires continued native display sampling. It does not guarantee repair before arbitrary user-selected TTLs or network stalls. Shorter TTL configuration needs explicit timing negotiation before exposing it to users. If the receiver has already expired, neither fallback nor progress restores the source: a fresh acknowledged activation is required. Grant/credential wall and continuous deadlines remain independent of routing, and input never renews the configuration owner lease.

## Verification and remaining gates

Native route tests verify reliable neutral admission, acknowledged UDP, dropped UDP, exact ciphertext fallback, one-way selection, monotonic counters, scope/clock rejection, partial-progress deadlines and fixed metadata bounds. Real UDP socket tests deliver exact packet bytes and verify terminal close. Client tests keep UDP setup blocked while binding and using TLS, then require cleanup of a late setup result; malformed/inactive/foreign/unsent progress closes a held touch owner.

Both native phone clients enroll and authenticate over real pinned TLS to the native host, bind to the separate recording receiver, sustain known held state through multiple progress heartbeats, release on lifecycle/transport closure and reconnect neutral on an advanced receipt. The witness runs in reliable-only, UDP and deliberately dropped-UDP modes. The drop case samples current native state to exercise fallback; it does not replay a touch queue.

These headless checks do not certify physical phones, real LAN loss/latency, sample timing under React load, physical output/signing, gameplay or optical sync. Sixty-second grant/authorization renewal, application/bridge wiring and every launch acceptance gate remain open. Hosted OS-provider checks must be rerun against this source snapshot; prior green results certify their exact commits only.
