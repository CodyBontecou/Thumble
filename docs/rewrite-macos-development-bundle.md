# Isolated macOS development receiver bundle

This procedure prepares the rewrite receiver for an explicitly coordinated local device test. It does not launch the receiver, replace an installed application, change an account or provisioning identity, or create a controller. It is development signing only; App Store/Developer ID distribution and gameplay acceptance remain separate gates.

Build the exact reviewed source with `bun tooling/build.ts --with-macos-output --with-wow-capture` from `Rewrite/`. Building compiles helpers without running them. Retain the source capsule hashes and build log. The default service remains recording-only.

Use an existing final bundle that already passes `scripts/verify-hid-signing.py --require-hid --distribution development` for `com.codybontecou.PocketPadMac`, team `67KC823C9A`. The script verifies that bundle, derives its actual leaf certificate, requires the same identity to be available for signing, and reuses only that bundle's matching embedded profile and signed entitlements. It never requests a new certificate, edits a keychain, installs a profile, or changes provisioning.

```sh
python3 scripts/prepare-rewrite-macos-development.py \
  --package /absolute/reviewed-package \
  --authorized-bundle '/absolute/authorized-lab.app' \
  --destination '/absolute/new-isolated/Thumble Rewrite Development Receiver.app'

python3 scripts/verify-hid-signing.py \
  '/absolute/new-isolated/Thumble Rewrite Development Receiver.app' \
  --require-hid --bundle-id com.codybontecou.PocketPadMac --distribution development
```

The destination must be new. A failure can leave an incomplete destination for inspection; it is never automatically replaced. Keep the adjacent entitlement and SHA-256 manifest sidecars private with the local evidence. No profile/certificate bytes or device identifiers are printed by the script.

The bundle's main executable is `Contents/MacOS/thumble-rewrite-receiver`, with the authorized HID entitlement. The nested `Contents/Helpers/thumble-wow-capture-macos` is signed with the same development identity without HID entitlements. Capture permission and actual capture behavior remain unverified until a separate explicit test. The Bun CLI stays outside the app bundle; this procedure does not invent hardened runtime/JIT entitlements for it.

The manifest records source executable hashes, signed bundle file hashes, profile validity, certificate hash, development scope, and explicit false execution/acceptance flags. Signing changes the executable hashes, so use the signed hashes when recording a physical test.

Before launching, coordinate retirement of the existing input owner and confirm its device cancellation. Keep isolated runtime/configuration state. The physical path additionally requires explicit `macos-hid` backend selection and `--allow-physical-output`; signing alone does not enable it. Never run two input owners to test enumeration. Do not interpret the signing verifier's pass as consumer/game compatibility, latency, disconnect safety, capture freshness, or shipping approval.
