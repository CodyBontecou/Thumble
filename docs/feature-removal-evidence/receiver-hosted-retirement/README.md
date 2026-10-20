# Receiver hosted-upload retirement

Mac and Rust receiver upload assemblers, commit jobs, native adoption validators, ledger writers/pruners and capability advertisements are removed. Ordinary local file import/export and phone editing remain. Legacy wire shapes and socket requests decode only to rejection; old receipt storage remains recoverable and is not replayed or pruned.

## Evidence

- `rust-gate.log`: `./scripts/verify-rust-host.sh` passes formatting, clippy, 477 tests and retained target checks. Three native-dependent tests are ignored in that gate. The old upload-only tests are removed; the independent native profile compatibility case is retained under `local_profile_compatibility` and its CI invocation is updated.
- `native-compatibility.log`: that retained native test passes separately against the freshly built `thumble-bridge`. Legacy inline outputs and unknown metadata survive profile selection/reordering. The other two ignored skin-native tests remain outstanding for final acceptance.
- `loopback-rejection.log`: two new integration tests pass. Real pairing is followed by retired Begin/Chunk/Commit/Cancel WebSocket requests and adopt/status/cancel socket requests. Every request returns an explicit error; authority bytes, including an expired legacy receipt, remain identical. Ping and profile synchronization still work on the same connection, and snapshots do not advertise adoption. Hidden `thumble-host shared-build` commands reject before reading files or creating state.
- `swift-tests.log`: 23 tests pass across ordinary portable artifacts, Mac local file import, read-only phone recovery and legacy rejection. The production Mac rejection helper covers valid legacy request shapes, malformed requests, unauthenticated suppression and no reflected payloads.
- `stack-safety.log`: the final required stack gate passes, with 35 constrained-thread tests and macOS/iOS Debug builds. No inline/frame budget increased.
- `local-profile-flow.log`: the retained profile import/export regression flow passes with the fresh Apple CLI/legacy fallback/native bridge and Rust executables in a private temporary account.
- `packaged-clients.log`: Apple app executable checks reject the removed upload assembler, commit gate and ledger in addition to retired pickup/fetch/preview implementations. Read-only recovery/local import remain. `binary-hashes.json` identifies the tested packaged binaries.

Reproduce the network checks with `cargo test --locked --manifest-path Host/Cargo.toml -p thumble-host --test retired_hosted_builds`. They require local socket access and create only temporary no-input receiver state. The full Rust gate uses the repository's configured toolchain. Native compatibility additionally requires `THUMBLE_TEST_ARTIFACT_RUNTIME_BIN` pointing to a directory containing the built native bridge.

The real paired network scenario runs against the Rust receiver. Mac wire rejection has helper tests and app/package build evidence; a separate live Mac receiver scenario was not performed. Physical haptics, same-condition device latency and live WoW acceptance remain outside this evidence. No deployed service was changed.
