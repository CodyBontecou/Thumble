# Complete document and outgoing wire bounds

The complete Rust configuration document now passes through a bounded counting sink before semantic validation. The counter includes profiles, maps, resources and opaque fields, follows serde JSON's exact compact UTF-8 escaping, and avoids allocating a second encoded document. Oversize errors report the proven lower bound of the unchanged 8 MiB limit plus one byte. The original configuration is not installed on failure.

Swift and Rust outgoing JSON frames now obey the same 8 MiB ceiling already enforced by receiving peers. Compact protocol-3 input retains its existing fast path. Rust bounded serialization stops before returning oversized bytes; Swift checks the completed Foundation encoding. Mac receiver delivery uses its existing rejection/release path. Rust runtime delivery releases the affected peer, retires authentication and UDP state, and sends only a small error/close; a stale different connection cannot release the active peer's holds. Native pending edits remain stored because a failed send cannot acknowledge them.

Verification:

- Full `./scripts/verify-rust-host.sh` passes formatting, clippy, 493 tests and retained target checks; three native-dependent tests remain ignored.
- Exact-limit and one-byte-over tests cover complete outgoing profile frames in Rust and Swift. The native case runs on a 512 KiB thread. Rust sink tests include UTF-8, escaped keys/controls, nested data and early termination before later values are serialized.
- Configuration coverage accepts the exact 8 MiB serialized document, counts opaque fields and refuses an oversized install without changing state.
- The runtime regression verifies authority equality, released keyboard holds, retired authentication and a bounded error with no profiles. It also verifies that a response for a stale second connection leaves the active connection and its held output intact. This is a production runtime-effect test with mock/recording output, not physical hardware or a new socket scenario.
- Required Apple stack gate passes all 37 constrained-stack tests plus macOS/iOS Debug builds, with unchanged budgets. Native Mac rejection is compiled production code plus shared codec/stack coverage; it has no separate real-network oversize test in this batch.
- Frozen fixtures, native edit oracle and shared format matrix verification pass unchanged.

This does not activate format 5 or prove every admitted configuration fits a decorated snapshot, which can duplicate the selected layout or include extra presentation/package metadata. Actual migration-transfer admission, combined phone-journal/resource bounds, atomic conversion/rollback, physical haptics/latency and live WoW acceptance remain outstanding. Android source did not change in this batch; it retains the same 8 MiB inbound ceiling and explicit pending layout/appearance send checks. Full temporary log hashes and selected excerpts are adjacent.
