# Consume pairing before committing phone trust

The native TLS worker consumes a one-use pairing window before committing a phone credential, then waits for an acknowledgment that the phone retained that credential. A failure after consumption never restores the window or rolls back a potentially delivered credential; uncertain delivery requires a fresh locally authorized invitation. This avoids replay after ambiguous network failures while preserving an explicit recovery path.

The window policy lock covers only local policy operations and proof consumption. TLS reads/writes hold no policy lock, allowing local cancellation or replacement while a phone is stalled. Native trust remains committed before any credential bytes leave the host. This coordinator grants no input session. The control exchange and integration boundaries are specified in [the enrollment protocol](../rewrite-enrollment-v1.md).
