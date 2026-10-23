# Bounded native control terminal diagnostics

The synthetic app runtime harness now preserves the debug receiver's `native_control_terminal` outcomes instead of silently consuming them. Its final diagnostic object adds `nativeControlTerminals`, an array of at most the first 64 accepted records from that process. Each record contains only a whitelisted static `code` and canonical unsigned 64-bit `elapsedUs`. Unknown syntactically valid codes become `other`; malformed, oversized, non-ASCII or extra-field lines are discarded. Raw stderr, endpoint values, labels, reports and credentials are never copied into this field.

This is diagnostic evidence after the authenticated control owner has returned and its broker cleanup has run. It is not a native first-termination reason or a claim that transport failure caused an input release. Correlate it with the separately validated hold diagnostic, Swift runtime outcome, publication gap and control failure stage. Existing hold/failure parsing, success criteria, input lifetimes, protocol guards and test deadlines remain unchanged. The native producer remains debug-only and explicitly enabled by `THUMBLE_REWRITE_CONTROL_TERMINAL_PROBE=1`.

This four-file supplement is based on public commit `567bfe42452d9c2609cb68ed25f4227a3eab3dff`. The original public harness Git blob is `55212fc1963a852e5d3b67ee6e1c576efb0de803`, SHA-256 `a29f4cc0362b384a44bf19bcd5ee21f083aa2569054b07b63273b7accb1a94cc`. Only four narrow harness additions are applied: parser import, bounded accumulator, stderr admission and final sanitized metadata. Unpublished analog app harness changes are excluded.

Headless hostile-input tests cover unknown codes, payload/endpoint injection, extra fields, invalid Unicode, noncanonical/overflowing counters, fixed capacity and detached snapshots. Existing hold-diagnostic tests remain intact. The repair does not claim to fix an intermittent runtime termination or establish a passing hosted runtime result.

The optional `--terminal-report` writes only the bounded sanitized terminal outcomes to an atomic mode-0600 JSON artifact. The iOS native runtime CI step opts in explicitly. Raw child output and checkpoint payloads remain excluded. Diagnostic write errors preserve the prior artifact, emit a fixed unavailable marker, and never change test success or skip cleanup. These are post-cleanup outcomes, not first-cause certification.

The allowlist preserves the audited native IPC outcomes `native_input_transport_failed`,
`native_input_timeout`, `native_input_frame_invalid`, and `native_input_server_rejected`.
These fixed categories distinguish the observed native IPC transport failure from
other sanitized outcomes. They do not identify its underlying read/write cause.
