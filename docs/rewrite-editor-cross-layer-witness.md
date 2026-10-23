# Actual editor service and native SDK witness

This opt-in Unix test runs a real Bun CLI recording service, the actual Rust
role12/policy host, a pinned TLS1.3 loopback client, and the actual configuration
child owning SQLite. It does not use a parent-response mock or a physical input
backend. Windows remains gated on its unsupported orphan-drain provider.

Build the composed native receiver and run `bun run mobile:prepare` to install
the shared SDK fixtures, then run from `Rewrite` with:

```sh
THUMBLE_REWRITE_EDITOR_CROSS_LAYER=1 \
THUMBLE_EDITOR_PYTHON=/path/to/TLS1.3-capable/python3 \
THUMBLE_EDITOR_EVIDENCE=/private/test-output/editor-summary.json \
bun test tests/editor-cross-layer.test.ts
```

`THUMBLE_EDITOR_RECEIVER` can select the composed receiver executable. The
system Python on this Mac uses LibreSSL without TLS1.3; the verified witness
used `/opt/homebrew/bin/python3`. Enrollment credentials stay in inherited
pipes/in-memory client objects. Only fixed synthetic phases and revision
numbers enter the saved report.

The witness establishes a pinned profile read, a persisted label commit, exact
original-intent receipt status, and an identical retry without a second revision.
It rejects changed original intent, wrong authority and extra phone-supplied
owner context. The first write reserves the captured owner behind an actual
outstanding CLI read; that read finishes and the exact pinned write commits
without retiring the owner. A second write remains suspended beyond the native
two-second phone response budget and returns admitted. A fresh authenticated
role12 status read still returns busy while that actual write remains pending.
The test suspends only the exact `__configuration` child belonging to its own
recording service, observes `configuration_owner_busy` after native editor
dispatch, starts four revoke calls, and receives pairing status while the edit
remains unresolved. No revoke response arrives before the child is
resumed. Every revoke response is immediately checked against the actual
completed configuration revision. Reenrollment then reads the exact receipt and
persisted label. Cleanup resumes the owned child in `finally` and waits for
service shutdown before deleting its private runtime.

To include the real Swift SDK, set `THUMBLE_EDITOR_SWIFT_COMMAND` to a JSON argv
array invoking:

```text
swift test --package-path native/mobile-input/ios --filter realServiceEditorUsesPinnedTLSAndExactReceipt
```

The driver creates a mode0600 fixture in its private runtime and passes its path
through `THUMBLE_EDITOR_SDK_FIXTURE`. The helper uses real `ControlTLSClient`
with injected synthetic credentials and an in-memory journal; it uses no
Keychain or device UI. It reads revision3, commits `swift-cross-layer-label`,
reconciles an exact receipt, verifies its queue is empty without advancing the
cached profile, repeats the original intent without revision5, and reads the
persisted revision4 label. A fixed summary file is mandatory, so a skipped SDK
test cannot satisfy the gate. The Python client independently checks the same
Swift intent's exact receipt and persisted label. The credential fixture is
removed immediately after the helper exits and is excluded from all capsules.

The synthetic client validates role12 hello against the shared `helloReply`
vector and validates the exact authenticated admission shape. A source review
caught the SDK hello mismatch; the real Swift run verifies its correction
against the actual host. Kotlin uses the same canonical vector, but this test
does not execute Kotlin networking. The successful combined witness ran in
approximately 4.9 seconds. Its bounded report contains
revisions `[1,2,2,3,4]`, the completed phase names, the Swift queue-empty summary,
and `inputEnabled:false` / `physicalOutput:false`.

Separate native regressions retain four strict immutable read tombstones when
reads time out. New reads receive busy at capacity instead of evicting a
legitimate late response. A matching valid late result consumes only its
original tombstone; it cannot consume a newer read or complete an active write.
Malformed or cross-context late responses still fail closed. These tombstones
retain no authorization scope, pending-edit Arc or SQLite lease.

The two-second native wait is a response deadline, not a writer-health or drain
proof. It retains the exact dispatched call and ticket and returns admitted
without retiring a healthy writer. Publication failure, explicit uncertain
parent results, malformed replies and parent loss still retire and retain the
exact pending writer. Parent reservation and actual owner response share one
30-second monotonic health budget; new work cannot overtake the reserved intent.
Only an actual correlated owner response/error or independent orphan drain
proof can release the write fence.
