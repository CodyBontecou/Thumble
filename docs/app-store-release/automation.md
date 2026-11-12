# Mobile release validation

The [Mobile workflow](../../.github/workflows/mobile.yml) runs lint, typecheck, and the mobile regression suite on every pull request and push to `main`. A macOS job builds the committed source in Release configuration and verifies two clean-install launches. `Mobile required checks` passes only when both jobs succeed. Use that check in branch protection when the repository plan supports required checks.

## Run locally

Install the locked dependencies with `npm ci`. Run `npm run mobile:check` for the source checks. EAS also runs these checks inside its build workspace after dependency installation.

On a Mac with Xcode, CocoaPods, and Argent 0.32.0 installed, run the launch check on a dedicated iPhone simulator. The test reinstalls Thumble before each pass and clears its app data on that simulator.

```sh
npm run mobile:smoke:ios -- --device SIMULATOR_UDID
```

The test waits for Welcome, checks that the screen settles, and verifies that Welcome is still visible. The runner saves two reports and a receipt in `build/mobile-smoke`. It builds from a clean Git snapshot. For local diagnostics, `--allow-dirty --sim-app /path/to/Thumble.app` can exercise a prebuilt Release simulator app. That receipt cannot authorize a release.

## Prepare and submit iOS

Use a clean committed checkout, an authenticated EAS session with iOS signing configured, and authenticated `asc` CLI credentials. Choose a new output directory under `build/` for each attempt. The production iOS config requires the provenance supplied by `prepare`.

```sh
npm run mobile:release -- prepare --output build/ios-release-7 --device SIMULATOR_UDID
npm run mobile:release -- verify --output build/ios-release-7
npm run mobile:release -- upload --output build/ios-release-7 --confirm
```

`prepare` validates the release source, builds the signed IPA through EAS locally, and embeds the commit, tree, and dependency lock hash in its Info.plist. It tests the IPA’s exact JavaScript and assets in a Release simulator app built from the same commit. Keep `app.ipa`, `release.json`, `source-checks.log`, and the three smoke JSON files together. The gate recomputes their hashes, compares source and build identifiers, and requires two successful launch reports before upload. The upload receipt records the processed App Store Connect build ID associated with those IPA bytes.

Cold-launch that same build in TestFlight on a physical iPhone before sending it to review. The simulator verifies the production JavaScript and assets with simulator-native code. Prepare the version metadata and review items in App Store Connect, then use the gated submission command for the processed build recorded in `upload.json`.

```sh
npm run mobile:release -- submit --output build/ios-release-7 --confirm
```

If a check fails, fix and commit the source, then prepare a new artifact. If ASC reports an interrupted upload, inspect the build processing status before retrying so the same build number is used only once. The review gate applies to this release command. Direct uploads and submissions through ASC require their own controls.
