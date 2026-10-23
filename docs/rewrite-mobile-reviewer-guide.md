# Mobile reviewer setup rehearsal

This is a review-candidate walkthrough, not a released product or store
acceptance certificate. The current draft still has intermittent receiver
failures and open iOS bank, physical gameplay, optical live-sync and distribution
gates. Final reviewer instructions need the exact approved signed/notarized Mac
package and corresponding phone builds. Do not substitute development signing
for distribution evidence.

## What the reviewer needs

The phone app has a local Practice route. Connected control needs a reachable
Mac running the companion headless receiver. The Mac does not need the Thumble
desktop GUI or a source checkout. No application account is currently required;
a real game may require its own login. Practice does not emit host input.

A user's local agent can perform the setup through the CLI or its corresponding
MCP operations. Use a new private state directory for this rehearsal, retaining
its identity separately from disposable runtime files. The standalone CLI and
native receiver must remain siblings. QR export additionally requires the
packaged optional `thumble-pairing-qr-macos` helper and its manifest. The default
recording package does not create an OS input device.

## Initialize without listening or input

Replace the two absolute paths with the unpacked reviewed package and a new
private directory. Keep the existing personal installation separate.

```sh
umask 077
THUMBLE_BIN=/absolute/package/thumble-rewrite
THUMBLE_STATE=/absolute/private/review-state
mkdir -p "$THUMBLE_STATE"
"$THUMBLE_BIN" identity initialize --identity-dir "$THUMBLE_STATE/identity" --json
"$THUMBLE_BIN" service start --runtime-dir "$THUMBLE_STATE/runtime" \
  --identity-dir "$THUMBLE_STATE/identity" --json
"$THUMBLE_BIN" pairing status --runtime-dir "$THUMBLE_STATE/runtime" --json
"$THUMBLE_BIN" receiver status --runtime-dir "$THUMBLE_STATE/runtime" --json
```

Default startup has no network listener. Check that the backend is `recording`,
`inputEnabled` is false and the receiver is inactive. `pairing status` reveals
no offer. Initialize the starter only in the new empty configuration authority:

```sh
"$THUMBLE_BIN" configuration initialize-starter \
  --runtime-dir "$THUMBLE_STATE/runtime" --operation-id reviewer-first-controller \
  --expected-revision 0 --profile-id e1000000-0000-0000-0000-000000000001 \
  --name 'Review controller' --json
"$THUMBLE_BIN" configuration list --runtime-dir "$THUMBLE_STATE/runtime" --json
```

The starter contains 18 controls including both sticks and independent analog
triggers. Existing configuration is refused, not overwritten. An exact retry of
the same operation recovers its receipt. Saved selection does not activate input.

## Explicit connected setup

Choose a fixed Mac LAN address and free port reachable by the phone. The sample
below is illustrative; use the actual Mac address, not loopback on a real phone.
Stop the owned rehearsal service before changing its launch options:

```sh
"$THUMBLE_BIN" service stop --runtime-dir "$THUMBLE_STATE/runtime" --json
"$THUMBLE_BIN" service start --runtime-dir "$THUMBLE_STATE/runtime" \
  --identity-dir "$THUMBLE_STATE/identity" \
  --listen-address 192.168.1.20:27183 --advertise-host 192.168.1.20 --json
"$THUMBLE_BIN" pairing status --runtime-dir "$THUMBLE_STATE/runtime" --json
"$THUMBLE_BIN" configuration list --runtime-dir "$THUMBLE_STATE/runtime" --json
"$THUMBLE_BIN" receiver status --runtime-dir "$THUMBLE_STATE/runtime" --json
```

This listener starts with enrollment closed. There is no implicit discovery,
port substitution or firewall permission grant. Have the local agent read the
current configuration revision, contentHash and activeProfileId from
`configuration list`, and receiver revision from `receiver status` under
`result.receiver.snapshot`. Supply those exact values to:

```text
thumble-rewrite receiver activate-saved --runtime-dir /absolute/private/review-state/runtime
  --expected-receiver-revision CURRENT_RECEIVER_REVISION
  --expected-configuration-revision CURRENT_CONFIGURATION_REVISION
  --expected-source-hash CURRENT_CONTENT_HASH --profile-id CURRENT_ACTIVE_PROFILE_ID --json
```

That command is one invocation; uppercase tokens are required values, not
literal arguments. Inspect `receiver saved-status` after uncertain responses
rather than retrying an old CAS. Activation remains recording-only in this
rehearsal. Physical Mac control requires the separately reviewed authorized HID
helper and explicit `--output macos-hid --allow-physical-output` at service
startup. A successful recording rehearsal is not proof of physical output.

With the optional QR helper packaged, open a bounded invitation privately:

```sh
"$THUMBLE_BIN" pairing open --runtime-dir "$THUMBLE_STATE/runtime" \
  --reveal-secret --qr-output "$THUMBLE_STATE/pairing.png" --json \
  > "$THUMBLE_STATE/pairing-offer.json"
```

The destination PNG must not already exist. Show it privately, then use the
phone's Scan QR route. Keep the phone unlocked and reachable on the LAN.
Treat the offer JSON and PNG as temporary credentials: never attach them to
review notes, screenshots, issues or CI artifacts. After pairing, cancel the
window and remove those two private files. Trusted-phone reconnect does not
require an open enrollment window.

## Phone and recovery checks

Use Practice first to exercise the local layout. Connect to the paired Mac and
check its truthful connection and game-data status. Test both sticks, independent
triggers, simultaneous controls and Done; Done should return home and release
held input. The current unattended synthetic Android test covers bank/theme
refresh with three held pointers, but physical multitouch and latency acceptance
remain open. Do not describe these as completed reviewer steps without executing
them on the exact candidate builds.

Inspect `receiver readiness`, `receiver saved-status` and `pairing status` through
the CLI/agent for bounded diagnostics. Connection and fresh game data are
separate conditions. Generic controls, updating or stale labels do not prove
live optical synchronization. Real live sync needs the exact supported game,
addon and capture permission, followed by its separate end-to-end acceptance.
No game launch is needed for this recording setup rehearsal.

After host restart, use the same identity and explicit listener address. Repeat
saved activation from the new receiver CAS state. Existing phone trust should
reconnect with enrollment closed. Input expiry may retire a saved runtime pin;
status reads do not renew it or automatically rearm held input. A required
reactivation is an explicit agent/operator action.

```sh
"$THUMBLE_BIN" pairing cancel --runtime-dir "$THUMBLE_STATE/runtime" --json
"$THUMBLE_BIN" receiver release --runtime-dir "$THUMBLE_STATE/runtime" --json
"$THUMBLE_BIN" service stop --runtime-dir "$THUMBLE_STATE/runtime" --json
```

## Rehearsal evidence and limits

A relocated compiled CLI and sibling recording receiver were exercised outside
the checkout with PATH limited to `/usr/bin:/bin`: fresh identity, default
no-listener startup, starter initialization, explicit fixed-loopback auth-only
startup with enrollment closed, saved activation, readiness, secret-free status,
a bounded invitation/cancel, release and service stop all passed. An initial
rehearsal script incorrectly read the nested receiver status as a flat snapshot;
correcting that script required no product change. The standalone package test
also passes one case and 67 assertions.

The loopback rehearsal did not scan a phone QR, test LAN/firewall reachability,
create a physical device, log into a game, establish optical freshness or verify
distribution signing. Those remain separate gates. See
[release preparation](rewrite-mobile-release-review.md),
[stable auth-only setup](rewrite-auth-only-listener.md),
[saved activation](rewrite-saved-runtime-binding-v1.md), and
[private QR export](rewrite-pairing-qr-v1.md) for the precise contracts.
