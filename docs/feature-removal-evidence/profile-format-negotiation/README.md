# Profile-format negotiation evidence

Current phones advertise only format 4. This change prepares independent profile-format negotiation and rejects unsupported snapshots before save; it does not enable format 5, migrate profiles, or remove the active skin runtime.

- Full `./scripts/verify-rust-host.sh`: formatting, clippy, 488 passing tests, three native-dependent ignored tests, and retained all-target checks.
- Final targeted `cargo +1.88.0 test --manifest-path Host/Cargo.toml -p thumble-host --test loopback_runtime`: passes after extending the real WebSocket test with incompatible-format rejection, exact authority-byte preservation, explicit format-4 pairing, and retained legacy reconnect/input/release coverage.
- Focused Apple tests: four format-policy cases plus 36 constrained-stack cases pass. The required `./scripts/verify-stack-safety.sh` then passes all 36 constrained-stack tests and both macOS/iOS Debug app builds, including the new preflight object in static inspection. Existing budgets are unchanged.
- Android: 200 unit tests pass, and `:app:assembleDebugAndroidTest` succeeds. After removing unnecessary format metadata from UDP authentication, the complete 200-test unit suite passes again. Instrumentation was compiled, not run.
- `python3 scripts/verify-feature-removal-fixtures.py` verifies the unchanged baseline, native edit oracle, and new pinned 14-negotiation/14-frame matrix shared by Swift, Rust and Android.

`verification.json` records hashes and paths of full temporary logs; the adjacent text files preserve success/test-result excerpts. The first focused Swift compile exposed a throwing-expression syntax error and the first Rust matrix run exposed missing frame timestamps; both were corrected before the passing checks recorded here. Test names and selected excerpts describe their scope; these receipts do not imply physical-device haptics, physical input latency, live WoW, successful user migration, or format-5 authority acceptance.

The core transition case deliberately installs a synthetic post-validation future-format state to assert held-input release and session retirement. The real authority still rejects that state. Stored future-version tests verify source preservation in isolated native defaults and Android JSON. Native Mac delivery gating is exercised by compiled production code and the shared policy/stack tests; the real network scenario runs against the Rust receiver.
