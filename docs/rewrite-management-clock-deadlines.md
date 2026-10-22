# Management read clock deadlines

The role-7 saved catalog and role-8 saved controller clients accept an authenticated host expiry only when it is positive, still ahead of their local wall clock, and no later than the stored credential expiry. The host continues to enforce its original absolute expiry and authorization fence on delivery. These read-only roles cannot grant input.

The client independently sets its local deadline to `min(hostExpiry, checked(localNow + 60_000))`. This matches the existing role-6 client policy. It does not reject a host expiry solely because `hostExpiry - localNow` exceeds 60 seconds: those values originate on different computers, and a phone clock one second behind the host previously rejected a legitimate host-issued 60-second lease. No grace interval is added to host authorization, and the client's local operation remains capped at 60 seconds. Checked addition fails closed on overflow. Existing local clock rollback, closed-client and deadline checks remain in place.

This is not complete independence from wall-clock synchronization. Credential and invitation preflight still use absolute timestamps; a sufficiently advanced phone clock can reject a credential or host lease early. The native host remains authoritative for credential and connection expiry. No wire fields, role-3 through role-8 schemas, input packet TTLs, input owner leases, or TLS deadlines change.

Regression tests exercise the actual catalog and map clients with a host clock one second ahead, local-cap exhaustion, rollback, expired and beyond-credential host expiries, and checked-addition overflow. Actual Android app acceptance additionally traverses the production catalog, saved-map fetch and input grant rather than installing a test map.
