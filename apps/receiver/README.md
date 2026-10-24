# Thumble Receiver

Small AppKit menu-bar app for macOS 15+. Receives one phone over local Wi-Fi and emits the Xbox-compatible 20-byte HID report. A paired phone can explicitly adopt a validated cloud controller as an immutable local profile. The receiver has no cloud account or cloud network connection, game scripts or keyboard emulation.

```sh
bash tools/build-macos-receiver.sh /path/to/approved.provisionprofile 'Developer ID Application identity'
open 'build/Thumble Receiver.app'
```

The bundle retains `com.codybontecou.PocketPadMac`, whose production virtual HID capability is already approved. The visible name is Thumble Receiver. The default build requires a matching Developer ID profile for all devices, a Developer ID Application identity, and production purchase configuration. Notarization is a separate release step. The receiver starts with its pairing window hidden. Ask an agent to call the local `show_pairing_code` tool to display the QR in chat, or choose **Pair phone…** in the menu bar. Launch with `--show-pairing` to open the window immediately. The window also offers “Copy pairing link”. Codes expire in two minutes and can be redeemed once. Disconnecting generates another code.

The receiver creates a process-local TLS certificate with macOS's `/usr/bin/openssl`, imports its identity into memory only, and deletes temporary key files. The phone pins the exact SHA-256 leaf certificate from the QR. A new receiver process has a new certificate. LAN changes currently require restarting the receiver. Automatic discovery, remembered pairing, distribution signing and launch-at-login remain follow-up work.

Input processing and the watchdog use their own serial queue. A 20 ms timer releases the gamepad after 300 ms without valid input, uses a separate 500 ms server-clock lease budget, requires fresh-lease neutral recovery, and closes the session after two seconds without valid input. The UI thread does not own that timer. On Mac sleep, disconnect or quit, all controls release. Rumble is unsupported.

Cloud adoption validates the complete profile, preserves existing local profiles, and compares the current activation revision before writing. Each source service/account/profile/revision gets its own namespaced local ID. Activation releases controls and waits for the phone's layout commit and fresh neutral acknowledgement. The player must resume controls separately. Hosted MCP cannot activate the Mac directly. See the [paired adoption contract](../../docs/cloud-contracts.md#paired-mac-adoption) for wire and provenance details.

`ThirdParty/SteamControllerBridge-LICENSE.txt` covers the reused Xbox descriptor/report contract and is included in the app bundle.

For the sandbox purchase test, use the separate `--testflight` build mode described
in [the purchase setup guide](../../docs/monetization-setup.md). It preserves the
existing approved Mac signing identity; it does not launch or replace the running
receiver. A production build rejects sandbox verifier configuration.
