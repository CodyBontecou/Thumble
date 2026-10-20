# Owned pending-layout recovery

A phone's pending layout record used to retain only a customization. If the authority removed an owned profile while the phone was offline, recovery could restore geometry while losing the eight-state appearance bank and its binary table. Both phone journal paths now optionally retain an immutable local recovery profile for owned profiles. A missing authority profile is restored from that snapshot before applying its pending orientation-specific layout. Existing ordinary records decode without the new field. Recovery data is not sent as part of the existing layout-edit wire message.

Apple stores the snapshot behind immutable reference storage. Android stores compact immutable JSON, preserving opaque profile metadata and pooled resources; journal capture validates the bank/resources and checks snapshot ownership. Both decoders reject a recovery profile belonging to another profile. Other hosts cannot cause recovery or upload of the retained edit. Existing host profiles continue to take precedence for fields outside the pending layout delta. Android merges only resource blobs referenced by the pending layout into a replaced owned resource table, validates/prunes the result, and expands canonical layout references when applying against a legacy profile without promoting it to owned format. Native recovered timestamps retain the pending edit time.

Verification:

- 23 focused Apple tests (15 bank cases and eight phone UX/journal cases), plus the 36 constrained-stack cases in the final gate.
- Required `./scripts/verify-stack-safety.sh`: all 36 constrained-stack cases and both Apple Debug builds pass. Cold owned recovery save/load/reconciliation now runs in the resource transport case on a 512 KiB thread. Pending edit inline size is 1,920 bytes, below the unchanged 4 KiB limit.
- All 203 Android unit tests pass. New cases cover all eight resolved states, exact embedded resource bytes, opaque metadata, post-capture source/container mutation, unrelated-host isolation, wrong ownership, malformed recovery records, absent resources, authority resource replacement and legacy rollback.
- Frozen baseline, native edit oracle and profile-format matrix verification pass without changing those fixtures.

These are journal/model and native-build checks, not a live phone-to-host migration. Version 5 is still unadvertised and authority migration remains gated. Complete configuration/journal/transport budgets, pooled pending-edit transfer, atomic migration/rollback, device haptics, input latency and live WoW acceptance remain outstanding. Full temporary log hashes and selected test/build excerpts are adjacent.
