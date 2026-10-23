# Native editor module lifetime

The process-wide editor registry must survive JavaScript reloads without letting an abandoned JavaScript runtime retain the protected journal forever. React effect cleanup is insufficient when the bridge runtime disappears. The native Expo module now owns a private `PhoneEditorModuleLifetime`, and its actual destruction hook invalidates that token before scheduling retirement. The JavaScript API and opaque handle shape are unchanged; no endpoint, credential, authority, receipt, storage path, or lifecycle token is exposed to JavaScript.

`PhoneEditorRegistry` is the concrete SDK registry used by the app wrapper and compiled by SDK tests. It reserves an owner before asynchronous initialization or initial snapshot. A candidate that finishes after invalidation or cancellation is closed without publishing a handle. Initial snapshot failure retires the actual SDK session and preserves corrupt journal contents; it does not clear or recreate storage.

All lookups and closes require the current module token and handle. Teardown closes only a matching reservation. A late destruction callback from an older module cannot close a replacement. Invalidation is permanent for that token; an old module cannot reopen. Normal close and teardown share one retirement operation. The old reservation remains until close actually returns and the SDK reports that RPC, cancellation, and local journal work have settled. Swift requires its existing `reusable` condition, including its own closed/close-returned state. Android has an explicit registry `closeReturned` barrier in addition to SDK `settled`.

Swift registry state is main-actor isolated. The lifetime token uses a lock only for its validity bit, so module destruction can invalidate it synchronously before an actor hop. The async Expo closures capture only that Sendable token, not the non-Sendable module object. Android never holds its registry monitor across construction, SDK snapshot work, close, journal IO, or cancellation IO. Its single bounded close worker runs actual SDK close outside the registry monitor. A failed close keeps the reservation unavailable rather than treating the failure as proof of drain.

The native editor still opens its journal lazily, has one current owner, keeps original queued intents, and uses existing SDK transport/cancellation fences. Module teardown cannot promise whether a previously admitted remote operation committed; it cancels and retains that operation for exact reconciliation. No elapsed timer releases ownership. Backgrounding an intact runtime does not invalidate its module; ordinary background/foreground handling remains with the existing connection/session lifecycle.

## Evidence

Six tests per platform run the actual registry and real `PhoneEditorSession`, using gated journal storage or fake transport IO at existing SDK seams:

- Invalidation during asynchronous creation reserves and closes the returned candidate before replacement; late old teardown and old-handle lookup cannot affect the new owner.
- Invalidation during initial journal snapshot retires the provisional candidate and blocks replacement.
- Cancellation of an opening task/future never exposes the late handle and retires the actual session.
- Failed snapshot retires the failed session and does not reset corrupt storage.
- Blocked cancellation keeps close-returned false; after close returns, an outstanding actual RPC still blocks replacement until its worker settles. Normal close and destruction share one cancellation.
- A gated offline mutation keeps the journal owner reserved and preserves the exact original queued intent after replacement.

The full Swift/Android SDK suites, Android lint, actual Expo Android Kotlin compile, actual Expo iOS pod-target compile, iOS device SDK compile, and repository stack-safety check are recorded in the separate evidence capsule. These are native source and controlled IO proofs. They do not establish an actual paired-device JavaScript reload or background-reopen acceptance result.
