# Bank-aware read-only phone presentation (control role 11)

A dedicated authenticated management connection negotiates hello version 1,
controlVersion 11 and role `management`. Its metadata and icon commands and
replies use version 2 and require an exact `bank`: `base`, `left-trigger`,
`right-trigger` or `both-triggers`. Light and dark theme selection remains
explicit. This protocol transports presentation only; input protocol 9,
input grants, report semantics and input deadlines are unchanged.

The native parent event uses version 2 and echoes the requested bank. It does
not expose the child's internal `presentationProtocol` discriminator. Parent
reply envelopes remain version 1. Both successful metadata and icon results
must echo the exact requested bank, theme and installed source/map pins.
A changed or missing bank, mismatched negotiated version, unknown fields and
duplicate JSON keys fail strict validation. The configuration child remains
the sole source of bank-specific labels and verified icon content.

Role 10 retains its exact version 1 contract: requests have no bank field,
metadata is base-only and icon replies have no additional bank field. A role
11 connection cannot submit input or acquire a grant. Neither presentation
protocol activates, replaces or retires an input configuration.

Both presentation roles share the existing single authenticated connection
try-gate and management operation gate, maximum 65 sequential commands,
existing frame and PNG bounds, two-second idle reads and parent waits, and
per-request authentication, revocation and active saved-binding checks.
Slow parent work and TLS writes hold no input or global trust mutex. Final
delivery uses the separate management fence; the existing non-atomic
saved-binding query/send boundary is unchanged, and the phone's input grant
still independently rechecks its exact generation and revision.

Portable tests replay all eight shared fixture variants (four banks by two
themes), reject malformed and cross-version payloads, and exercise actual
pinned TLS metadata/icon delivery for every bank. Shared lifecycle witnesses
cover replacement, revocation, timeout, late replies, role rejection,
connection exhaustion and cross-role connection exclusion. Tests use fake
native output; they do not create a physical device or capture a game.
Mobile SDK selection and rendering acceptance are separate integration gates.
