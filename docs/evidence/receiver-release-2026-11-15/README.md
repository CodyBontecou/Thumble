# Mac receiver 1.1.1 — November 15, 2026

Mac receiver 1.1.1 (build 6). Reports the connected phone's canvas to Thumble Studio, so desktop saves and selections validate against the phone's real layout. Replacing a plan grant now releases held input and requires Resume, matching the desktop receiver. Windows/Linux preview stays at 0.2.0.

Source: `main` at `432a478` plus the version bump in this commit.

## Build

Built and signed locally with Developer ID profile `PTQ96A4K5H` (universal arm64 + x86_64). App notarization `9b9effec-7c18-4c25-b75e-972e36241ad3` and DMG notarization `bf361c88-1a63-4dbf-9e2e-d25c3e079bd7` were accepted and stapled, and both assess as Notarized Developer ID.

- `Thumble-Receiver-1.1.1.dmg`, 2,728,241 bytes, `f6181ea04556326aabd8d8030b2bcdb972b67982b8ff9acbe3f10a7a79fb8feb`

## Publication

Uploaded the DMG and its `.sha256` to R2 `pocketpad-releases/macos/receiver/`; download Worker version `d4685041-8155-47e6-b438-8cc6783c007d`. `/downloads/receiver-latest.dmg` redirects to 1.1.1; the DMG downloaded through thumble.io matches the published checksum and passes Gatekeeper; 1.1.0 remains available. Website redeployed to Pages `pocketpad-site`; `/download` shows 1.1.1 and `/cli/` still serves.

Not verified here: real-game play with 1.1.1, or Studio viewport validation against a physical phone.
