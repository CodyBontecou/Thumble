# Tapping Receiver

Small AppKit menu-bar app for macOS 15+. Receives one phone over local Wi-Fi and emits the Xbox-compatible 20-byte HID report. No game scripts, keyboard emulation, accounts, or cloud relay.

```sh
bash tools/build-macos-receiver.sh /path/to/approved.provisionprofile 'Apple Development identity'
open 'build/Tapping Receiver.app'
```

The development bundle intentionally uses the existing approved Thumble Mac App ID. It is a locally signed development build, not a notarized public installer. The phone scans the receiver window's QR code or uses its “Copy pairing link” button. Codes expire in two minutes and can be redeemed once. Disconnecting generates another code.

The receiver creates a process-local TLS certificate with macOS's `/usr/bin/openssl`, imports its identity into memory only, and deletes temporary key files. The phone pins the exact SHA-256 leaf certificate from the QR. A new receiver process has a new certificate. LAN changes currently require restarting the receiver. Automatic discovery, remembered pairing, distribution signing and launch-at-login remain follow-up work.

Input processing and the watchdog use their own serial queue. A 20 ms timer releases the gamepad after 300 ms without valid input, uses a separate 500 ms server-clock lease budget, requires fresh-lease neutral recovery, and closes the session after two seconds without valid input. The UI thread does not own that timer. On Mac sleep, disconnect or quit, all controls release. Rumble is unsupported.

`ThirdParty/SteamControllerBridge-LICENSE.txt` covers the reused Xbox descriptor/report contract and is included in the app bundle.
