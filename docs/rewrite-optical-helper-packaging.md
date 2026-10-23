# Optional optical helper review packages

The ordinary `bun tooling/build.ts` package remains recording-only and contains no optical helper. `--with-wow-capture` explicitly adds the standalone Swift helper on macOS or the standalone Rust helper on Windows. Unsupported platforms and repeated/unknown flags are rejected before any build or package writes. `--with-macos-output` remains a separate macOS-only option and may be combined with capture compilation; neither compilation flag activates an OS device or capture.

```sh
cd Rewrite
bun tooling/build.ts --with-wow-capture
# Optional separate macOS output compilation:
bun tooling/build.ts --with-wow-capture --with-macos-output
```

The opt-in build compiles source only. It never executes the helper's status, permission, capture or any other mode; it performs no signing, provisioning, installation or driver operations. Windows dependency notices are checked before helper compilation. The package contains one platform-specific sibling, `thumble-wow-capture-macos` or `thumble-wow-capture-windows.exe`, plus `Optical-THIRD-PARTY-NOTICES.txt` and `WOW-CAPTURE-MANIFEST.json`. The bounded manifest identifies exact helper and notice names, byte counts and SHA-256s, and records capture disabled, no capture execution, and compatibility unverified. Artifact assembly reads bounded regular files once; manifest hashes cover the bytes actually written. A later default build removes these fixed optional leaves, including stale symlinks, without deleting unrelated files.

Move the complete `dist` directory anywhere, retaining the CLI, receiver, helper and notices. Supply the helper's **absolute packaged sibling path** explicitly; no source checkout, Bun executable or Thumble desktop GUI is required at runtime:

```sh
/absolute/package/thumble-rewrite service start --runtime-dir /absolute/private/runtime --capture-helper /absolute/package/thumble-wow-capture-macos --json
/absolute/package/thumble-rewrite wow capture-start --source world-of-warcraft --runtime-dir /absolute/private/runtime --json
/absolute/package/thumble-rewrite wow capture-status --runtime-dir /absolute/private/runtime --json
/absolute/package/thumble-rewrite wow capture-stop --runtime-dir /absolute/private/runtime --json
/absolute/package/thumble-rewrite service stop --runtime-dir /absolute/private/runtime --json
```

On Windows, use the `.exe` names and absolute Windows paths. Existing platform-native runtime requirements, OS capture permissions, client-build compatibility, signing and distribution acceptance remain separate gates; copying a helper is not evidence they passed. The service never discovers or auto-enables the packaged helper. Capture status exposes bounded receipt metadata only and does not apply configuration, renew game freshness, activate input or certify mandatory live sync. The product flag is `--capture-helper`; compilation uses `--with-wow-capture`.

`tests/build-capture.test.ts` uses owned synthetic file bytes for policy, hashing, notices and cleanup. `THUMBLE_REWRITE_CAPTURE_PACKAGE_TEST=1 bun test tests/capture-package.test.ts` relocates an opt-in package, verifies its real helper bytes without running it, then exercises the compiled CLI/recording receiver with an explicitly selected **synthetic compiled helper** and a runtime `PATH` without Bun. No acceptance test invokes the actual capture helper or OS capture/permission APIs.
