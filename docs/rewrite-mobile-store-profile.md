# Explicit mobile store profile

The default Expo configuration remains the static `Rewrite/apps/mobile/app.json` development app: Thumble Rewrite, separate `.rewrite` identifiers, version0.0.0 and the existing native QA plugin. Store configuration is selected only with `THUMBLE_MOBILE_VARIANT=store`; `NODE_ENV`, Release builds and ordinary Expo commands do not select it automatically.

The store variant is branded Thumble and uses the retained identifiers `com.codybontecou.PocketPad.iOS` and `com.thumble.android`, with scheme `thumble`. It uses the curated retained1024RGB icon at `apps/mobile/assets/store-icon.png` (SHA256 `6eae962eb6ad8037b0d661bacdc8e1920825028aecfcc5fb05124fbcc07427a7`). iOS targets iPhone only (`supportsTablet:false`, generated device family1). Native controller, QR scanner and semantic color plugins remain enabled. The native QA plugin is excluded; fresh prebuilds contain no instrumentation runner/nativeQa build type or iOS test target.

The [Expo dynamic configuration](https://docs.expo.dev/workflow/configuration/) consumes the static configuration as its base. A dependency-free CJS policy module keeps Expo's config loader compatible and never mutates that base. Unknown variants and store metadata supplied without the store variant are rejected.

Two explicit review overrides are required: `THUMBLE_STORE_VERSION` is three canonical decimal components (0..999 each), and `THUMBLE_STORE_BUILD` is a canonical positive integer1..9999. These are conservative project review limits, not a claim that every platform accepts every possible version. The shared build becomes iOS `buildNumber` and Android `versionCode`; the source EAS store profile disables automatic increment and uses local version authority. The example below does not assign an approved release version.

```sh
cd Rewrite/apps/mobile
THUMBLE_MOBILE_VARIANT=store \
THUMBLE_STORE_VERSION=1.0.0 THUMBLE_STORE_BUILD=4 \
EXPO_OFFLINE=1 EXPO_NO_TELEMETRY=1 EXPO_NO_DOTENV=1 \
node node_modules/expo/bin/cli config --type public --json
```

Inspect a fresh disposable source copy with the same environment and `expo prebuild --no-install --platform all` from that copy's mobile directory. Keep normal development native folders and active phone installs separate. No Pod/package installation, device installation, account operation or upload is part of this procedure. Store identifiers share the retained applications' identities; metadata generation is not installation approval.

The store-only plugin removes the audited Expo template's release debug-key fallback, leaving debug builds unchanged. Release signing must be configured separately. It also aligns both generated Xcode target version/build settings with the explicit plist values. Unexpected Gradle/Xcode templates fail closed instead of silently retaining stale signing or version data. No certificate, keystore, provisioning profile or account is selected by the profile.

`eas.json` provides an explicit `store` source profile (store distribution, Release/app-bundle, local versions, no auto-increment). No EAS project/account is linked or contacted here. A future remote build must receive the same validated version/build overrides in its environment; remote variables and production signing are currently unconfigured. App Store Connect/Play metadata, monotonic build acceptance, privacy declarations and distribution review remain external release work.

Android is phone-first in current product acceptance. No fragile density allowlist is introduced. Android's [supports-screens behavior](https://developer.android.com/guide/topics/manifest/supports-screens-element) can place large screens in compatibility mode; it does not establish a strict phone-only Play distribution policy. Review the actual Play device catalog/tablet exclusions before distribution. iOS's [supportsTablet field](https://docs.expo.dev/versions/latest/config/app/) directly controls this profile's tablet support.

Verification covers default identity preservation, strict review inputs, icon provenance, required native plugin retention, QA exclusion, fail-closed release signing transformation and actual offline Expo config resolution. A fresh isolated iOS/Android prebuild was inspected with version1.0.0/build4: production IDs, iOS device family1, matching Xcode/plist version fields, Android version metadata, generated branded icons, no QA targets, and no release debug signing. No production archive/AAB was signed, installed or uploaded.
