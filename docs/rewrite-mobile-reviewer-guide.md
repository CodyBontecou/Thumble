# Mobile reviewer setup rehearsal

This is a review-candidate walkthrough, not a released product or store
acceptance certificate. The current draft still has intermittent receiver
failures and open physical bank/gameplay, optical live-sync and distribution
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

## Saved control labels

Use the typed command through the local CLI or agent to edit one saved label.
For the fresh starter above, the Movement control has ID
`ce000000-0000-0000-0000-000000000001`. Use the actual control ID from owned
configuration for other profiles. The first example assumes the starter is still
at configuration revision `1`; read `configuration list` and use its current
revision after other edits.

```sh
"$THUMBLE_BIN" configuration set-control-label --help --json
"$THUMBLE_BIN" configuration set-control-label \
  --runtime-dir "$THUMBLE_STATE/runtime" --operation-id reviewer-movement-label \
  --expected-revision 1 --profile-id e1000000-0000-0000-0000-000000000001 \
  --control-id ce000000-0000-0000-0000-000000000001 --label 'Move' --json
```

The result uses the normal configuration receipt. Repeating the same operation
ID and exact intent recovers that receipt; a stale revision with a new operation
returns a conflict without overwriting a newer edit. Use the committed receipt's
resulting revision for the next change. To remove this override after the example
commits revision `2`:

```sh
"$THUMBLE_BIN" configuration set-control-label \
  --runtime-dir "$THUMBLE_STATE/runtime" --operation-id reviewer-movement-label-clear \
  --expected-revision 2 --profile-id e1000000-0000-0000-0000-000000000001 \
  --control-id ce000000-0000-0000-0000-000000000001 --clear-label --json
```

Labels preserve exact Unicode up to 128 UTF-8 bytes. `--label ''` stores an
explicit blank, whereas `--clear-label` removes the customization and restores
the generated label. Use `--label=--text` for a label beginning with two hyphens.
These two intents are mutually exclusive. The edit preserves the generated label,
control geometry, bindings and current input generation. It does not activate or
retire input; an installed compatible controller can receive the cosmetic change
through its separate presentation connection. Live-sync freshness and gameplay
acceptance still have their own gates.

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

The destination PNG must not already exist. On the phone Home screen, choose
**Test a connection** for this recording-only rehearsal, then Scan QR. Reserve
**Connect to Mac** for the explicit physical-output setup described above. Show
the PNG privately and keep the phone unlocked and reachable on the LAN.
Treat the offer JSON and PNG as temporary credentials: never attach them to
review notes, screenshots, issues or CI artifacts. After pairing, cancel the
window and remove those two private files. Trusted-phone reconnect does not
require an open enrollment window.

## Delete a saved profile explicitly

Read `configuration list` first and use its current revision. Deletion requires
an explicit remaining active profile and an explicit default (a remaining UUID
or `none`); it refuses deleting the last profile. For example:

```sh
"$THUMBLE_BIN" configuration delete-profile --runtime-dir "$THUMBLE_STATE/runtime" \
  --operation-id review-delete-1 --expected-revision CURRENT_REVISION \
  --profile-id DELETE_UUID --active-profile-id KEEP_UUID \
  --default-profile-id none --json
```

Reuse the same operation ID and exact selections to recover the durable receipt;
use a new operation ID for changed intent. A stale revision returns a conflict.
The MCP equivalent `configuration_delete_profile` is available only when the
agent explicitly starts MCP with `--allow-configuration-write`; its
`defaultProfileId` is a UUID or JSON `null`.

This edits the saved catalog and its selections. It does not replace or retire a
currently installed input pin, including one whose saved profile was deleted.
Release and explicitly activate a remaining saved profile when needed. Deletion
does not garbage-collect underlying asset bytes.

## Phone and recovery checks

Use Practice first to exercise the local layout. Use **Test a connection** to
reconnect to this recording receiver and check its truthful connection and
game-data status. Test both sticks, independent
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
