# Explicit saved-source runtime binding

`receiver activate-saved` explicitly activates a **recording-only** native configuration using independent saved-authority and native-receiver revision guards. It does not select/edit a saved profile, enable physical output, install a device or certify a layout's renderer/platform compatibility. Ordinary `receiver activate` remains an unbound recording activation, even when its arbitrary profile label happens to match a saved UUID.

```sh
thumble-rewrite configuration list --runtime-dir /absolute/runtime --json
thumble-rewrite receiver status --runtime-dir /absolute/runtime --json
thumble-rewrite receiver activate-saved --runtime-dir /absolute/runtime \
  --expected-receiver-revision 0 --expected-configuration-revision 1 \
  --expected-source-hash <catalog-contentHash> --profile-id <selected-profile-UUID> --json
thumble-rewrite receiver saved-status --runtime-dir /absolute/runtime --json
```

The read-only MCP tool `receiver_saved_status` is always available. `receiver_activate_saved` is available only when the agent's MCP server was launched with the existing `--allow-recorded-input` capability; the capability cannot be supplied in tool arguments. CLI activation is an explicit action. Both paths use the same authenticated local service operation and return service/receiver identity plus the native snapshot and optional saved binding. Existing receiver snapshots keep their exact recording-only fields.

The sole configuration owner verifies the requested positive saved revision, canonical storage content hash, and actually selected canonical profile UUID. It derives the returned pin from the repository; the parent does not accept an arbitrary label/hash as evidence of saved identity. This private read returns no source, resources, file paths or credentials. Database decoding remains in the configuration child; all existing input TTL, owner lease and pipe/client timeouts remain unchanged.

The saved-source CAS linearizes at the owner's read; the native-receiver CAS linearizes later when its serialized activation advances generation/revision. These are **not one cross-owner transaction**. No authority, trust, policy or global lock is held across native IO. A concurrent saved edit can make the pinned source unavailable for future delivery; the generation is never silently rebound to the latest source. A future saved-map request must match the native binding and current available authority exactly, otherwise it requires explicit reactivation. No historical source reconstruction is promised.

The native binding contains the saved `configurationRevision`, storage `sourceHash`, canonical `profileId`, and the exact native `generation`/`revision`. Storage `sourceHash` is the same canonical, domain-separated hash as catalog `contentHash`; it is distinct from a future materialized owned-document UTF-8 hash. The binding is immutable for that native configuration. Saved rename/selection/import alone does not publish a new runtime generation or rewrite the existing pin. A map successfully projected before a later storage edit may still be delivered and granted against that unchanged native pin. This is activated-snapshot consistency, not a promise that storage is current at grant time; storage writes alone do not retire a session. New reads still require the pinned source to be currently available.

New ordinary activation, replacement saved activation, operator release, shutdown, native restart and owner lease expiry retire the old binding. Phone/source operations retain it only while the existing native configuration remains active. In the retained safety model the 350 ms input TTL can retire the active configuration itself; that also clears the pin and reconnect then requires explicit activation. This change does not extend or reinterpret that safety policy. Status reads never renew ownership. No saved activation receipt survives native restart.

Activation has ephemeral CAS/retry semantics, not a durable configuration operation receipt. After an uncertain client response, inspect `receiver saved-status`; do not assume a retry can reuse the old receiver revision. A conflicting replacement detected before confirmation fails `saved_activation_unconfirmed` instead of reporting another generation as the caller's success.

Tests cover strict metadata/epoch contracts, sole-writer source/revision/selection checks without commits, actual CLI import/service/native activation, both official MCP SDK eras and capability modes, source/native conflict preservation, saved edits retaining the old immutable pin until explicit activation, ordinary activation clearing it, release and restart. Native tests additionally cover invalid/stale commands, neutral barriers, failed output, owner and input expiry, packet attachment/renewal and exact status framing. Actual revision-pinned management delivery and the connected phone surface are separate work.
