# Headless CI test shards

The portable Windows job reached its two-minute Bun step limit with passing individual tests. Windows now runs three deterministic file shards: `bun run test:ci --shard 1/3`, `2/3`, and `3/3`. Sort the discovered repository test paths, then assign each file by its index modulo three. Tests within each file and their deadlines are unchanged. Each shard retains the two-minute step limit and writes its own nonempty JUnit report. The prior report is removed before execution so stale evidence cannot satisfy the check.

macOS and Linux still run the full suite once each. Windows native stress, the complete native suite, independent TLS oracle, standalone package build and package tests run only in the primary shard. All shards build the native receiver required by TypeScript integration tests. Artifact names include the matrix identity to avoid collisions. No test failure is retried or converted to a pass.

The strict shard parser rejects mixed package/shard modes, duplicates, malformed fractions and out-of-range indices/counts. Tests prove sorted assignment is deterministic, selections are nonempty, the three-way union is exactly the discovered inventory and no file appears twice. Package mode remains an explicit separate selection.

The standalone iOS native runtime probe compiles its fixed pure native source inventory: Probe.swift, PhoneConnection.swift and PairingQRScanner.swift. The scanner is a compile dependency of the pairing prompt; it is not launched by the explicit-map TLS probe. No Expo module or product React host is substituted. Simulator SDK modules must be built from matching source before compiling the probe. Existing simulator ownership/cleanup, runtime assertions and TLS deadlines remain unchanged.
