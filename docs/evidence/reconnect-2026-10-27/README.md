# Remembered Mac reconnect — October 27, 2026

Implemented and verified locally on the Pixel 7 and normal production-configured Mac receiver.

## Cause and change

The phone disconnected on AppState background, discarded its invitation after handshake, and had no saved reconnect identity. The receiver accepted only the short-lived, single-use QR token. A pairing now issues a separate random 256-bit reconnect credential bound to the phone installation. The phone stores only the reconnect credential, local endpoint and TLS pin in Expo SecureStore, then reconnects on startup/foreground and retries transient transport failures with capped backoff. The QR token is never persisted or reused. Explicit phone disconnect forgets the saved computer; receiver reset revokes trust. Input is released in the background, and every reconnection gets fresh leases, layout activation and purchase verification.

## Verification

- 40 mobile connection/pairing tests passed, including process recreation from storage, QR-token non-reuse, explicit disconnect, invalid endpoints and backgrounding during a storage read.
- Real receiver/mobile protocol regression passed using a stub HID device: background return, fresh mobile process, rejection of another phone using the credential, and explicit forgetting. Native credential checks cover forged, reset and superseded credentials.
- Swift demo/grant checks passed, plus seven monetization tests. Mobile lint and typecheck passed.
- Pixel installed local version 1.0.0 (3), signed with the existing matching local debug key using install -r. Existing app and Google purchase data retained.
- After an initial pairing to the updated receiver, force-stop/relaunch reconnected automatically without opening or delivering another pairing link. Mac reported connected=true, ready=true, pro=true and restored the existing ConsolePort layout.
- Home/background test confirmed receiver disconnected and released controls, waited three additional seconds, then returned to Thumble. Mac automatically returned to connected=true, ready=true, pro=true.
- Recorded UI smoke test `.argent/e2e/android-remembered-mac-reconnect-20261027.yaml` replayed end to end twice: eight steps passed each time. This checks process launch and foreground transitions; receiver acceptance is separately established by protocol tests and receiver-status.json. The menu screenshot shows Connected and PRO / UNLIMITED PLAY after reconnect.

## Scope and limits

No second Google purchase was attempted: the account already owns Pro. Background/foreground exercises the same AppState path that interrupted checkout, while store grants and ownership remain enforced. A fresh purchase with this new binary was not tested. iOS shares the JS reconnect implementation but was not tested on-device in this change.

At this initial checkpoint, restarting the Mac receiver still required pairing because its TLS identity was ephemeral. That limitation was subsequently fixed and verified: see [persistent receiver restart verification](../receiver-restart-2026-10-27/README.md). Explicitly resetting/replacing a pairing still requires a fresh QR; upgrading from the old ephemeral receiver requires one initial pairing.

This is a local test build, not a new Play/App Store submission or notarized desktop release. The submitted Android 1.0.0 (2) and iOS build remain unchanged. EAS preview upload was rejected by automatic approval review; local builds were used. Local build repairs regenerated stale paths after the repository rename and corrected only the stale dedicated Thumble keychain search path.

Replay on the paired device with Argent e2e-execute, name android-remembered-mac-reconnect-20261027, project_root /Users/codybontecou/dev/Thumble, device 2C061FDH200CJN. Protocol regression: `node tools/test-reconnect-receiver.mjs`.
