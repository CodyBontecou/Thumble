# Private editor owner lifetime prerequisite

This seam is not a phone write capability. No native role, broker, revocation,
service command, or MCP registration calls it. It prepares one label-only path
for a future commit fence; existing read roles stay read-only.

The actual configuration child creates a random immutable `ownerLifetimeId`
only after acquiring its existing SQLite lifetime lease. Its ready message
carries that identity. Existing three-field fake ready messages remain supported
for readonly tests but cannot enter the editor path. Each parent object owns one
child forever: it does not restart, substitute, or redirect editor requests.

A private `editor-label-commit` carries that nonce, native event/authority/phone/
credential-epoch identity, and the existing strict label intent. It accepts no
raw source, paths, fingerprint, or generic configuration command. The child
checks its own nonce before calling the ordinary label operation, retaining the
existing receipt fingerprint, replay-before-decode, revision CAS, and source
preservation. Replies repeat the complete normalized envelope. Stale bytes sent
to a replacement child are rejected before an operation or receipt can be made.

`NativePipe.requestParsed` distinguishes a parsed correlated success/error from
requests rejected before dispatch. A lost/invalid/timed-out reply after enqueue
throws an uncertain-transport error. Ordinary `NativePipe.request` semantics
and budgets remain unchanged. A parsed operation error proves the synchronous
owner call ended; it does **not** prove that no durable write occurred. A journal
must still reconcile ambiguous storage errors using the original exact intent.

The parent keeps a single editor write slot while awaiting a definitive reply.
Other configuration work is rejected rather than queued behind it. On uncertain
transport it permanently closes editor admission, destroys the private input,
and requires actual child exit. After two seconds it requests SIGKILL; after
three seconds without an exit event/state it reports exit-unconfirmed and keeps
the slot closed/retained. Time elapsed, stdin EOF, and kill issuance are not
confirmation. Confirmed death returns unknown disposition, never a no-op receipt.
A valid owner reply may complete a previously dispatched edit after admission
has closed; closing admission only forbids future dispatch.

## Integration gates

This does not implement the native SQLite orphan-drain fence. Future native
composition must strongly retain the credential scope, ticket and exact writer
identity independent of TLS/parent lifetime. On parent failure it must exclude
future bytes for that child, retain the exclusive DB guard through any revoke/
reenroll acknowledgement, and never send a pending request to a replacement
owner. A phone's admitted/pending response is only allowed after strong retention
and dispatch; it is not completion and cannot release the fence. Actual parsed
owner completion, confirmed writer death plus the required orphan proof, and
final authorization/send fencing must be connected and tested before enabling
phone writes. No Windows/Linux conformance is claimed here.
