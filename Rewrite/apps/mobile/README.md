# Rewrite mobile application — in progress

Expo development/native builds for iOS and Android. This slice runs the standard
controller in **local practice**: native feedback, no receiver connection and no OS
input. Pairing, native credential/control binding, renewal, editing, haptics and WoW
presentation are subsequent integration work. This does not replace the retained
application or satisfy launch acceptance.

From `Rewrite`, install the pinned Bun/Node dependencies with `bun install
--frozen-lockfile`, then run `bun run mobile:prepare`. In `apps/mobile`, run
`bun run prebuild`. The generated `ios/` and `android/` projects are ignored;
plugins and local native modules are the source of truth. CocoaPods is required on
macOS. Shared native code and generated contracts are linked directly as local
pods/Gradle sources.

For development, `bun run start` binds Metro to IPv4 localhost on port 8087. Use
only your selected emulator/device; Android needs a scoped `adb -s SERIAL reverse
tcp:8087 tcp:8087`. Native Release builds bundle JavaScript and need no Metro.

## Input boundary

React draws immutable region geometry and labels. Configure/practice/snapshot and
release are bounded metadata calls; there is no JavaScript touch/sample callback.
Initial practice admission uses one immutable native prop and a native receipt
event after props commit. This avoids Fabric's imperative view-tag mount race.
The strict receipt lives inside an `admission` event envelope, separate from
React Native's `target`/`timeStamp` metadata.

A transparent input surface is attached as an Activity content/`UIWindow` sibling
outside React root ancestry. Merely putting a native child inside a React view
still sends touches through React's root dispatcher. The sibling accepts initial
touches only in validated controller regions; Done and other navigation pass
through. Native layout/visibility checks follow the presentation anchor, releasing
on hiding, detachment, focus loss, background, cancellation and rotation. Native
sampling and feedback continue while JavaScript is blocked. Practice never admits
host output, and released touches are never reconstructed on reopening.

## Headless witnesses

Use dedicated synthetic test simulators/emulators, without physical output.

Android, after prebuild, from `android/`:

```sh
ANDROID_SERIAL=YOUR_TEST_SERIAL ./gradlew :app:connectedNativeQaAndroidTest -PreactNativeArchitectures=arm64-v8a
```

The `.qa` application variant bundles Release JavaScript/native dependencies and
keeps test classes unminified. Production Release keeps its own shrinking policy.
Instrumentation injects actual system touch events into all 19 regions and a
six-finger chord, blocks the actual React Native JS queue, checks native
cancellation, background release, rotation/reopening and Done navigation. The
ancestry test was observed failing before moving input outside the React root.
The generated Android release key is a development template key, not release
signing evidence.

iOS, after prebuild, from `apps/mobile`:

```sh
ruby tests/prepare-ios.rb
(cd ios && pod install)
xcodebuild -workspace ios/ThumbleRewrite.xcworkspace -scheme NativePortalTests -configuration Release -destination 'platform=iOS Simulator,id=YOUR_TEST_UDID' -derivedDataPath /tmp/thumble-mobile-ios-qa -parallel-testing-enabled NO ENABLE_TESTABILITY=YES CODE_SIGNING_ALLOWED=NO test
```

The QA target disables Swift explicit dependency scanning after a reproduced
Xcode 26.5 scanner deadlock; production compiler settings remain unchanged.
This creates a QA target in the generated project; it does not add a shipped test
bridge. Hosted tests exercise the actual native view under the running app's React
root, UIKit hit testing and hidden/removed-anchor release. They do not claim iOS
six-finger injection or JavaScript-stall acceptance. The separate native core tests
and SDK builds remain required. Preserve failures as well as successful runs.

Physical-device latency, minimum touch targets across phone sizes, dark/large text
and motion/accessibility review, signing/clean install, real transport and grant
renewal remain open. Retained stack-safety verification remains required for
subsequent shared-model/startup changes. Simulator compilation or
practice routing does not certify gameplay or optical live sync.
