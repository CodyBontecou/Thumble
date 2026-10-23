# Mobile store candidate preparation

The explicit store profile remains separate from ordinary `.rewrite` development builds. No task in this document authorizes account changes, creating/replacing signing keys, provisioning updates, production-ID installation, upload or store publication. Run generation/build inspection in a fresh disposable copy. The current physical development apps and receiver remain independent.

## Prepared source and local evidence

Keep the curated store icon byte-identical (`6eae962eb6ad8037b0d661bacdc8e1920825028aecfcc5fb05124fbcc07427a7`); `Rewrite/.gitattributes` must classify PNG as `-text`, overriding the general LF-text rule so a future Git add cannot normalize the binary. Existing public icon bytes were verified correct; the override prevents future corruption.

The store profile requires explicit canonical version/build inputs and preserves default development configuration. Its store-only review supplement adds native privacy reasons and removes inherited unused Android storage/overlay permissions. Native QA targets are excluded and release debug-key signing is removed. The source EAS profile has no linked project/account and must receive the same version/build environment.

A fresh offline prebuild with illustrative version1.0.0/build4 passed both native metadata inspections. An isolated cached `:app:processReleaseMainManifest` run passed without assembling, signing or installing an app. Its merged permissions are INTERNET, VIBRATE, CAMERA and `com.thumble.android.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`; camera hardware is optional. The iOS app PrivacyInfo contains CA92.1/35F9.1 and the generated target remains iPhone-only. These are prebuild/manifest gates, not final archive/AAB or gameplay acceptance.

Repeat the bounded read-only check after generating fresh store sources:

```sh
python3 -B Rewrite/tooling/test_mobile_store_prebuild.py
python3 Rewrite/tooling/check-mobile-store-prebuild.py \
  --mobile-root /absolute/disposable/Rewrite/apps/mobile \
  --version 1.0.0 --build 4 \
  --merged-android-manifest /absolute/disposable/Rewrite/apps/mobile/android/app/build/intermediates/merged_manifest/release/processReleaseMainManifest/AndroidManifest.xml
```

The inspector emits fixed check names and file hashes. It does not run Xcode, Gradle, signers or devices. Without the optional merged-manifest argument it checks source removal directives only. Final packaging and dependency/label review are always reported as still required.

## Final archive and signing path

1. Confirm the existing App Store Connect/Play records, approved version and monotonically higher build number before choosing real overrides. `1.0.0`/`4` is inspection input, not an approved release assignment.
2. Generate fresh store native projects with the explicit environment and install only their audited dependencies. Compile/archive in private derived/output directories. Do not use production identifiers to install over retained phone apps.
3. iOS must use an existing matching Apple distribution certificate/private key and App Store provisioning profile for `com.codybontecou.PocketPad.iOS`. Existing retained Mac development HID signing is not iOS distribution signing. `apps/mobile/release/ExportOptions.example.plist` is an inert manual/local-export template with deliberately unresolved markers; make a private reviewed copy. Do not run it with markers, use `-allowProvisioningUpdates`, or reuse an unrelated Mac profile. The retained `Config/ExportOptions/iOS-TestFlight.plist` is historical automatic-signing input, not verified rewrite distribution evidence.
4. Inspect the archive's actual Info.plist, signature/entitlements, embedded provisioning profile, device families/minimum OS, icons and every bundled privacy manifest. Generate the Xcode privacy report and reconcile third-party declarations. Review dSYMs and retain artifact hashes.
5. Android must use the app's existing upload-key path under its current Play App Signing arrangement. Do not generate a replacement key or use the debug keystore. Configure release signing explicitly; the source deliberately supplies no key/password. Inspect the final AAB manifest, versionCode/target SDK, signature certificate and native library/resource contents, and compare the upload certificate with the existing Play record. [Android signing and upload keys](https://developer.android.com/studio/publish/app-signing).
6. Export to a private local destination and record hashes. Upload/submission is a separate explicit action after functional/recovery/live-sync gates and review of the exact artifacts.

## Notices and privacy artifacts

`modules/thumble-input/android/src/main/assets/thumble-qr-notices.txt` bundles the pinned ZXing scanner dependencies' Apache texts. `TEST-DEPENDENCY-NOTICES.txt` covers test-only React dependencies and is not production runtime clearance. Existing CocoaPods acknowledgements and npm license files are useful inputs, but no complete final production mobile notice bundle has yet been verified. Audit the final Metro bundle, Pods and resolved release Maven graph; include the required license/NOTICE text with both distributions. Internal/workspace package metadata and absent installed license files are not evidence of a permissive license. Changes to dependencies invalidate the inventory.

A private conservative installed npm runtime/peer/optional dependency inventory was prepared:500 packages,49 unresolved dependency edges and51 entries lacking a root license text, plus638,318 bytes of available license texts. These figures are a build-tool-inclusive superset, not500 shipped libraries or51 demonstrated licensing violations. The current development Pods acknowledgement inventory has11 library components (plus its acknowledgements heading). Reconcile those inputs against actual release bundles before claiming notice completeness; no copied vendor implementation or new package adoption occurred.

Use [the mobile privacy worksheet](rewrite-mobile-privacy-review.md) to prepare app-specific policy text, store labels, permission explanations and encryption answers. The current website policy is for the waitlist. A final mobile policy URL, support URL/contact and owner-reviewed export classification are still needed; source declarations are not submission answers.

## Reviewer material to finish once behavior is stable

Prepare current rewrite screenshots, truthful feature/device support, age-rating/privacy answers and reviewer notes. Do not reuse retained desktop/phone marketing screenshots as if they depict the rewrite. Describe the standalone practice path and the external Mac requirement for physical input. Provide a reproducible signed/notarized headless receiver package and instructions to initialize identity/starter, explicitly activate the saved profile, start auth-only LAN listening and open a bounded QR window. Never put real credentials/invitation images in review notes. An App Review account is unnecessary unless a real account feature is introduced; actual companion/reviewer access must still be operable.

Outstanding functional acceptance includes the unresolved Pixel terminal failure, both target game experiences, full physical controls/recovery/latency and mandatory live-sync permission/freshness/authority/phone delivery. A configured store profile does not close these gates.

## External values not established by source

After the prepared checks, the remaining account-bound inputs are: existing app-record ownership/access, approved next version/build, existing distribution certificate/profile and Android upload-key arrangement, intended distribution regions/export classification, mobile privacy/support URLs and reviewed store metadata. Retrieve them through authorized existing account access or have the owner supply them; do not infer, mint or rotate them. No request for these values is necessary to run the source/prebuild/manifest checks above.
