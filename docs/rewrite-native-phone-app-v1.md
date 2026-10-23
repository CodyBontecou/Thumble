# Native phone app connection flow

The React Native home screen opens either practice or a connected controller. Both
use the same shared control geometry and landscape route. Connection opens a
platform-native secure invitation field; its text, decoded proof, vault record,
bearer, packet grant and engine never have a React property, event or promise form.
The native field limits input size, disables text correction/autofill where the
platform supports it, clears on submission/dismissal, and closes on backgrounding.
The native enrollment decoders retain their independent strict 4 KiB UTF-8 bound.

The user starts the headless receiver, enables its recording configuration and
opens pairing through their agent/CLI, then pastes the resulting invitation on
the phone. Pairing uses the existing pinned TLS enrollment coordinator and real
Keychain/Keystore storage. The phone remembers one non-secret endpoint and a
local phone identifier in app preferences. Endpoint preferences are a convenience
for reconnect, not a credential store or a transactional migration journal.
Pair another computer by pasting its new invitation; failed authentication never
silently replaces trust, clears the vault or falls back to an unpinned channel.

Reconnect creates a new native control client, reloads its credential from the OS
provider, authenticates, reads the host's current active generation/revision and
binds the retained layout to that exact receipt. The subsequent grant request
independently checks the receipt again. A missing/inactive/stale configuration
fails closed. The app does not choose a host epoch, activate receiver ownership
or enable physical output. The agent remains the configuration owner.

Swift networking is asynchronous on its UI actor; Android enrollment, preference
commit, vault and control setup run on a dedicated cancellable worker, with the
single-use admission bound on the native UI thread. The app wrapper adopts the
fresh engine without reactivating it. First geometry establishes placement;
subsequent resize, detachment, navigation, focus/lifecycle loss and input failure
retain native neutralization. Native feedback remains outside the JavaScript
sample path. A live-mode view permanently refuses practice/configuration
reconfiguration through React, including after disconnection.

React receives only strict bounded lifecycle metadata: waiting, pairing,
connecting, ready with generation/revision and fixed connected/practice flags,
cancelled, unavailable or disconnected. It receives no per-sample events. Error
text explains how to restart pairing; Done returns home, where a new route can
reconnect with a fresh source. A rejected/closed attempt cannot reopen itself or
restore prior touches. Native view removal cancels setup and closes owned I/O.

## Headless app witnesses

`tooling/run_mobile_app_probe.py` wraps each platform's bundled-app test command.
It starts an owned recording-only Rust TLS/IPC host lazily when the native test
asks for a synthetic invitation. Its ephemeral localhost side channel exists
only in QA test code; product code uses the normal invitation field, provider,
pinned connection and input surface. Android forwards only the selected owned
emulator's side-channel and TLS TCP ports and removes those exact forwards. UDP
is not forwarded and may select the normal reliable fallback.

The app witness pairs, verifies the first recorded source sample and current
state are neutral, holds south at the separate recording receiver, closes the
controller and verifies native release, advances the configuration, then creates
a second neutral source using saved endpoint/OS trust. The app-history probe
permits native frame sampling to advance the current sequence; the original
SDK sequence-zero witness is unchanged. Product receiver checks still enforce
packet generation, replay and first-neutral admission.

Android instrumentation operates the real React connection route and native
secure field, injects system MotionEvents and closes Done with a second finger
while a control remains held. UIKit's hosted test invokes the same native submit
and reconnect methods used by alert actions, adopts the engine into the actual
app portal, drives native semantic input and verifies removal. It is not an iOS
system-finger-injection test. Its light/dark attachments show the actual native
alert. The QA preparation script supplies a simulator-only ad-hoc Keychain
identity; it does not configure device provisioning or change vault policy.
Exact result checkers require all ten Android and five UIKit cases without skips.

Manual invitation entry is implemented. Discovery/QR capture, account/multiple
host selection, continuous sixty-second authorization/grant renewal and physical
phone acceptance remain open. Driver/signing distribution, gameplay, haptics,
latency and mandatory optical live sync remain release gates. These app checks
use a recording receiver and do not certify physical input output or launch.
