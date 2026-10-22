# Dormant native output core

`Rewrite/native/output-core` is an isolated Rust crate. It is not a receiver dependency, is not included in the CLI executable, and adds no running output mode. Creating `OutputOwner` starts one thread but creates no device. Default features include no physical adapter. The optional `macos-hid` module compiles the retained macOS IOHID implementation; tests use fake devices exclusively and never instantiate `MacFactory`, register an OS device or send physical input. There is no Windows virtual-gamepad implementation.

## Small interface and sole device ownership

`OutputOwner::spawn(factory)` moves a `Send` factory to its owned thread. The factory checks authorization and creates devices only for an explicit `Activate` operation. `Device` deliberately has no `Send` requirement: construction, reporting, cancellation, callback confirmation and destruction remain on that thread. Tests include an `Rc`-bearing fake device to exercise this restriction.

`request(operation)` admits work to an eight-slot queue with `try_send`; saturation returns `Busy`. One additional operation may be in flight. `Pending::wait(budget)` waits for a receipt for a positive duration no greater than one second. `Ok(None)` means completion remains uncertain; it does not cancel the operation or confirm release. The same pending handle can be waited on again and caches its eventual result. Request IDs are increasing uint64 values that never wrap.

Operations are `Activate {scope,valid_until}`, `Submit {scope,report}`, `RenewDeadline {scope,valid_until}`, `Release {scope}` and `Shutdown`. A scope contains a nonzero 16-byte owner identity and positive uint64 generation. The owner identity is an opaque caller-issued identifier, not a phone credential. Activation requires a strictly newer generation, including after release, expiry or failure. Only the exact active owner/generation may submit, renew or release. Replacement first retires the old device; no new device is created before its cancellation confirms. Work queued under an older scope cannot become input under a replacement scope.

The deadline is a trusted caller-supplied absolute monotonic `Instant`. This crate neither parses transport packets nor duplicates the receiver's 350 ms input TTL or 750 ms owner lease. `RenewDeadline` explicitly extends a still-live scope; it cannot revive an expired one. The worker checks expiry before operations, before device creation and after in-flight startup/reporting. Idle expiry initiates neutralization and retirement. Deterministic tests control an internal clock and wake the worker through requests rather than relying on elapsed sleep counts.

`snapshot()` reports the last worker-confirmed phase, scope/deadline, highest accepted generation and bounded fault enum. `Ready` requires a successful initial neutral submission. `Snapshot::admits_at(now)` also checks the deadline, so a stalled device call cannot make an expired grant appear admissible merely because its last device phase was ready. Readiness establishes neither consumer recognition nor gameplay acceptance.

## Failure, retirement and bounded retention

The owner submits neutral before requesting cancellation. A report failure clears admission, latches a fault and starts retirement; a later sample cannot silently recover output. Recovery requires explicit activation with a fresh generation after retirement has confirmed. Missing entitlement, unsupported platform, invalid scopes/deadlines/reports and queue pressure return typed errors without claiming successful output.

The owner retains at most one device and its callback context while retirement is pending. Release and replacement receipts wait for actual cancellation confirmation. Shutdown immediately closes further ordinary admission; even if its request encounters a full queue, the stop intent remains set and status must be checked. Shutdown receipts report `Stopped` only after retirement confirms. A cancellation-poll failure retains the context and latches a fault; confirmation later permits destruction but does not convert the failed release into success.

Dropping the handle requests shutdown and closes its sender without blocking or destroying another thread's device. Queued ordinary operations are rejected after the stop intent. An already in-flight native call may complete later. If the OS never returns or never confirms cancellation, one detached owner/device context may remain retained indefinitely; there is no accumulating retired-device list and no false confirmed-cleanup claim. Caller timeout, neutralization request and physical release are distinct. This crate cannot impose a hard real-time bound on a stalled OS call; eventual device cancellation and release behavior still require final-artifact and hardware acceptance.

## Existing wire contract and macOS extraction

`Report` admits existing 20-byte v2 report bytes with header `00 14`, reserved bit/bytes clear and opposing D-pad directions already canceled. It adds no semantic encoder. The descriptor and safe GetReport behavior are extracted from `Host/crates/thumble-host/src/gamepad.rs`; tests compare the descriptor and every report vector against `Host/fixtures/gamepad/v2.json`. GetReport rejects unsupported report type/ID and insufficient capacity without modifying the caller's buffer. Output/feature reports remain unsupported. The descriptor's upstream attribution remains the MIT-licensed steam-controller-bridge contract, with the existing `ThirdParty/SteamControllerBridge-LICENSE.txt` required by eventual packaging.

The macOS adapter extracts `Host/crates/thumble-host/src/platform/gamepad_macos.rs`: the executing task's actual Boolean `com.apple.developer.hid.virtual.device` claim, retained v2 device properties, an independent fixed-size callback cache, dedicated serial callback queue and CF lifetime rules. No CF pointer receives an unsafe `Send` implementation. Callbacks hold no owner queue or lifecycle lock, and reporting releases the cache lock before entering IOKit. Cancellation notification is followed by a serial callback-queue drain before the device, blocks, cache and queue are released. An emergency owner-thread drop also retains resources until cancellation completes. A process-local device lease prevents another macOS factory from creating a replacement while the prior device/context remains owned.

Checking the signed Boolean claim is not provisioning verification. Exact helper identity, matching profile, distribution signature and final-bundle authorization remain the release workflow's responsibility. This slice creates no bundle, changes no signing identity and installs no driver.

## Verification and integration still required

Both default and all-feature test commands exercise fake-only lifecycle tests, canonical fixture passthrough and GetReport policy. All-feature compilation and CF-value/callback-block tests check macOS code without creating or activating a HID device. The callback tests retain negative/huge-capacity, buffer ownership, current-cache and unsupported-request coverage, and the entitlement-value test distinguishes Boolean true from numeric/string lookalikes. The portable factory/device interface and fake tests are suitable for Windows Actions; `UnsupportedFactory` truthfully rejects unavailable output. The retained Windows `SendInput` code implements keyboard/mouse behavior, not a gamepad driver.

```sh
cargo +1.88.0 test --locked --manifest-path Rewrite/native/output-core/Cargo.toml
cargo +1.88.0 test --locked --manifest-path Rewrite/native/output-core/Cargo.toml --all-features
cargo +1.88.0 clippy --locked --manifest-path Rewrite/native/output-core/Cargo.toml --all-targets --all-features -- -D warnings
```

Receiver wiring, CLI/MCP backend selection and truthful status contracts, physical-output opt-in, validated activation compatibility, packaged helper verification, Windows driver integration and real input acceptance are separate work. Existing recording-only behavior and saved structural configuration admission remain unchanged. No M1/M2/M3 acceptance gate is completed by this dormant crate.
