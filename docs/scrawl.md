# Scrawl development captures

Debug builds of the mobile app include [Scrawl](https://github.com/kitlangton/scrawl): hold three fingers for half a second to start/finish a recording of the screen, your narration and touches, and send it to Scrawl on your Mac. EAS production builds skip the plugin entirely, so store builds never link ScrawlKit. This follows the myself.md integration.

## iOS

`apps/mobile/plugins/with-scrawl.cjs` links the ScrawlKit Swift package (pinned to revision `b5fa0705f6e5724ede414727797b4b6ed274d3d2`) and rewrites the generated SDK 58 `SceneDelegate.swift`. In Debug only it:

- handles pairing links, both cold start (`connectionOptions.urlContexts`) and warm (`scene(_:openURLContexts:)`); Scrawl links are not forwarded to React Native, and `src/app/+native-intent.js` sends a cold-start Scrawl link to `/` instead of the not-found screen;
- moves React Native into a `ScrawlTouchWindow` and attaches ScrawlKit's observer through a zero-size SwiftUI host;
- stops React Native's touch handlers waiting for Scrawl's passive `TouchObserver` to fail. Without this, RN buttons stopped responding after pairing in myself.md;
- raises the app target's Debug deployment target to iOS 18, which ScrawlKit needs. Release keeps Expo's target.

The microphone and local-network usage strings already exist in `app.json`. The plugin survives `expo prebuild`; never edit `ios/` by hand. Changes need a fresh native build, because an OTA update cannot add the SDK.

Pair: with Scrawl running on the Mac, run `scrawl link --scheme thumble` and open the link/QR on the phone. The link contains a private token, so do not commit it. Unpair with `thumble://scrawl?reset=1`. The SDK stays inert on unpaired devices.

## Android

`apps/mobile/plugins/with-scrawl-android.cjs` adds `dev.kitlangton.scrawl:scrawlkit-autoinstall:0.1.0` as a `debugImplementation` from Maven local. It is skipped when `~/.m2` doesn't have it (EAS, CI), so publish it first with `./gradlew publishToMavenLocal` in `~/dev/scrawl/android`. Pair with `scrawl link --scheme thumblescrawl`.

## Use

On the Mac, run `scrawl inspect latest` or paste with Option-Shift-V. Captures include whatever is visible on screen. Scrawl is owner-operated development tooling and changes no product behavior.
