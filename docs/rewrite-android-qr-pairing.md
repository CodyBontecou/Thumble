# Android native QR pairing

The native pairing form offers **Scan pairing code** alongside manual invitation entry and saved-host reconnect. It retains the explicit recording or Mac input intent chosen on Home. Camera text and invitation credentials do not enter JavaScript, navigation parameters, logs, or clipboard storage.

The scanner uses the retained pinned `com.journeyapps:zxing-android-embedded:4.3.0` library and its ZXing core dependency. Upstream Apache licenses and notices are included in the Android APK asset `thumble-qr-notices.txt`. The app requests camera permission only after the user taps Scan. A missing camera, denied permission, cancellation, or camera failure leaves manual entry available.

Only QR codes are decoded. A candidate is limited to 4096 UTF-16 code units before encoding and 4096 UTF-8 bytes before admission. The exact existing seven-field native invitation decoder rejects malformed JSON, duplicate/extra fields, invalid endpoints and invalid bounded scalar values. The first valid candidate closes the camera before bootstrap; later callbacks cannot start a second enrollment. Invalid codes show fixed explanatory text without exposing their contents.

The scanner belongs to the native connection owner. Ordinary activity pause closes that owner; the pre-auth camera permission request alone can survive its permission-sheet pause. Actual activity stop closes unconditionally, including permission/background races. Closing the route releases the preview, closes the camera dialog and ignores late permission/decode results. No input timing, TLS pinning, output-mode negotiation, grant, or lifecycle rule for an admitted input session is relaxed.

`QrInvitationTest` exercises synthetic exact invitation admission and malformed, duplicate, extra-field and oversized rejection on the real Android runtime. These checks do not establish physical-camera recognition or actual QR enrollment; those require a device pointed at a live Mac pairing code. Existing manual pairing and controller acceptance gates remain required.
