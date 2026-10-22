# Stage new keys before committing a live input continuation

A controller must outlive a bounded grant without reusing its nonce counter or
forcing held controls through an artificial release. Increasing authorization
lifetimes leaves the per-grant packet budget unresolved. Reinstalling an ordinary
source invokes its neutral barrier and is inappropriate for continuity.

The independent receiver stages at most one fresh grant for its exact live native
connection/session and configuration. Until a valid first packet commits it,
the current stream and all existing deadlines remain authoritative. Commit uses
the current full controller state and atomically replaces the packet decoder and
counter without changing configuration ownership. Old keys and stale cleanup
cannot affect the successor. The trusted receiver generates fresh random material;
rotation is not a form for importing arbitrary caller-selected keys or sessions.

A pending grant has at most two seconds to commit. Expiry, input/owner lease loss,
clock rollback, revocation, release, replacement or failed output prevents revival.
Cancellation can discard only the pending grant. A lost native grant receipt
retires both sources. Staging and peer cleanup retain constant memory, independent
of the number of valid continuations. Ordinary installations keep their neutral
barrier and existing reconnect budget.

The receiver/private native IPC seam is implemented. Explicit control version 6
now renews authorization under current durable trust, bounds the next native
grant by that authority, and retains one registry entry across staging and
commitment. Reliable packet zero commits the successor; pending keys cannot
commit over UDP. The [protocol](../rewrite-native-input-control-v6.md) defines
per-grant and continuous-time connection work bounds. Versions 3–5 retain their
existing lifetime behavior.

Native phone sender/transport transfer and automatic renewal remain
unimplemented. The apps must verify held controls across multiple real renewals
before opting in. Controlled-clock host tests prove protocol and registry
boundaries, not real-duration phone operation. This decision enables neither
physical output nor any launch acceptance claim.
