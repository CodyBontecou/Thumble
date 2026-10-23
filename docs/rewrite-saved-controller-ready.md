# Keeping a saved macOS controller ready

Opt in when starting a service:

```sh
thumble-rewrite service start --output macos-hid --allow-physical-output --keep-saved-controller-ready --receiver /absolute/signed/receiver --runtime-dir /absolute/private/runtime
```

This is a local agent policy authorizing maintenance of the same neutral controller. It does not authorize phone credentials, open a pairing window, activate a profile at startup, or replay input. The default service behavior is unchanged. The policy requires physical output opt-in; recording receivers reject the flag. An already running service requires a restart to change this launch policy.

After an explicit local `receiver activate-saved` succeeds, a clean phone release can be followed by a fresh neutral generation of that exact saved profile. The service serializes maintenance with operator commands. It verifies the sole configuration authority's exact revision, source hash and profile, the native retired saved pin and receiver counters, and confirmed successful physical worker retirement. Unknown, failed, pending or uncertain cleanup is never permission to rearm. Existing input TTL, owner lease, phone authentication and generation checks remain unchanged. A revoked phone remains revoked.

Inspect the policy with `thumble-rewrite receiver readiness --runtime-dir /absolute/private/runtime` or the read-only MCP tool `receiver_readiness`. States are `disabled`, `waiting-for-explicit-activation`, `armed`, `rearming`, and `latched`, with a fixed reason such as `catalog-recheck-failed` or `retirement-unconfirmed`. Inspection remains responsive while maintenance awaits the configuration child and never creates input.

There is at most one attempt per released generation/revision. A stale catalog, malformed source, missing pin, unavailable child, uncertain cleanup, output failure or counter mismatch latches maintenance off. Editing the catalog does not silently refresh the controller. Explicitly activate the desired saved configuration again to arm the policy against its new revision/hash. An operator release, stop, or ordinary unsaved activation disarms maintenance. Owner expiry and input timeout do not trigger maintenance. The pin is process-local and is not restored after service restart.

The read-only native `savedRearmStatus` owner query returns the unchanged snapshot, a `releasedBinding` retained only for `native_input_released`, and `cleanupReady`. The latter requires a healthy authoritative clock, no uncertain receipt or worker fault, exact highest generation and confirmed `Inactive` state with no scope/deadline. It does not admit input. No global trust or phone management lock is held during configuration reads or output lifecycle operations.

Fake ports and output factories verify policy behavior and retirement proof without creating an OS controller. Real reconnect acceptance requires the separately signed macOS receiver and paired phones; this change alone does not establish that external acceptance.

The catalog comparison linearizes at the sole-authority saved-pin read, like explicit saved activation; it is not a transaction spanning SQLite and the native receiver. A catalog edit after that read may leave the previously authorized pin armed as a neutral generation. Subsequent phone map reads reject the stale source with `reactivation_required`; maintaining a newer catalog revision still requires explicit local activation. Operator release/stop/activation intent cancels pending maintenance immediately, including a blocked catalog read, before another neutral activation can be submitted.
