# Headless Keychain provider test host

The simulator-only `KeychainProvider` scheme supplies an application identity and explicit Keychain access group to the real production vault test. A hostless Swift package test runs under `xctest` without the required application entitlement and returns `errSecMissingEntitlement` (-34018). The original CI failure and a local headless reproduction confirmed that error before this harness was added. See [Apple’s error reference](https://developer.apple.com/documentation/security/errsecmissingentitlement) for the required-entitlement error.

The host is ad-hoc signed with synthetic `THUMBLECI1.com.thumble.rewrite.KeychainProviderHost` entitlements. It needs no Apple account, provisioning secret or physical device, cannot be built for a device, and is never a shipping product target. The test uses a random synthetic pin and fixed public test token, verifies the actual record's device-only/unlocked accessibility and lack of synchronization, reloads across vault instances and removes its own record. Production storage policy and source are unchanged.

From `Rewrite/`, with an available simulator UDID:

```sh
bun run mobile:prepare
xcodebuild -project native/mobile-input/ios/ProviderTests/KeychainProvider.xcodeproj -scheme KeychainProvider -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" -derivedDataPath /tmp/thumble-keychain-tests -resultBundlePath /tmp/thumble-keychain-tests.xcresult -parallel-testing-enabled NO test
xcrun xcresulttool get test-results tests --schema-version 0.1.0 --path /tmp/thumble-keychain-tests.xcresult > /tmp/thumble-keychain-tests.json
xcrun xcresulttool get test-results summary --schema-version 0.1.0 --path /tmp/thumble-keychain-tests.xcresult > /tmp/thumble-keychain-summary.json
python3 tooling/check_native_vault_results.py ios /tmp/thumble-keychain-tests.json /tmp/thumble-keychain-summary.json
```

The verifier requires the exact `actualDeviceKeychainPersistsSyntheticCredentialAcrossVaultInstances` case to pass without being skipped. Ordinary package tests still run separately in the iOS Simulator and cover policy/format through test doubles; this additional hosted target supplies OS-provider runtime evidence. The workflow collects result JSON even after a test failure and preserves the failed exit status. This harness does not establish locked-device, power-loss, physical-device signing or gameplay acceptance.
