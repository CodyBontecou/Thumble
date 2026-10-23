# iOS reliable input write window

The native v5/v6 recording and v9 Mac phone owners opt into a private eight-input TLS dispatch window. The generic TLS transport and legacy v4 keep their previous behavior. This changes flow control, not TLS authentication, packet encoding, counters, input freshness, or any deadline.

`NativeInputWriteQueue` runs synchronously on the main actor, alongside `ControlTLSClient` dispatch and phone ownership. A credit is reserved before `NWConnection.send`, so the active socket write counts toward the global eight. One unsent latest full-state sample coalesces subsequent input. Packet zero stays in the ordered control FIFO and clears an older unsent latest sample.

Enqueuing a control request pauses latest input dispatch. Already queued packet-zero barriers retain FIFO order. A strictly parsed current-session progress receipt reaches the queue only after `NativeInputRoute` validates the shared UDP/TLS counter and monotonic acceptance. UDP can legitimately advance that counter beyond the highest TLS write. A forged future receipt, wrong scope, or regressing receipt cannot unlock credits.

A strictly validated renewal reply behind the paused writer is an ordered consumption barrier for earlier TLS inputs. Only that reply retires the old grant's credits; a new packet zero cannot reset them. The same touch owner queues the fresh grant's packet zero before completing the barrier and requesting progress for that grant. A queued old packet zero prevents credit retirement.

Each queued input, including packet zero, keeps its original `ContinuousClock` offer instant. Dispatch rejects rollback or age at least 350 ms. A later receipt never gives an old held sample a new timestamp. Close clears queued samples and credit state, and later completion or acknowledgement cannot reopen the writer. The existing 100 ms progress cadence, 350 ms receiver input TTL, two-second transport operations, grant lifetimes, certificate pin, ALPN, and protocol checks remain unchanged.

Focused tests cover active-write accounting, input pressure/coalescing, ordered controls, UDP-advanced acceptance, invalid acknowledgements, full-window renewal, queued old packet zero, stale held/neutral samples, rollback, cancellation, and legacy behavior. A phone-owner test uses the actual queue through strict renewal and background release. Native TLS and SDK tests are separate from physical-device acceptance. Physical iPhone/high-refresh sustained acceptance remains required before a store candidate is declared ready.
