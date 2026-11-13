# Receivers with Thumble Studio — November 13, 2026

Mac receiver 1.1.0 (build 5) and Windows/Linux preview 0.2.0. Both ship the redesigned Thumble Studio (PR #10) and the Nov 12 plan requirement: the free demo is retired, and controller output needs a plan or free trial from the phone app.

Source: `release/receivers-studio` at `6b1de62d0b3e5555be01072833f11a68de0bc581`.

## Windows and Linux 0.2.0

Native CI passed: https://github.com/CodyBontecou/Thumble/actions/runs/43430272712 (installed runtime, native gamepad, and the Studio save/select GUI smoke on both platforms). Published installers are the CI artifacts, verified against their `SHA256SUMS`. Sizes grew from 0.1.1 because the bundle now includes Qt WebEngine for Studio.

- Windows: `Thumble-Receiver-0.2.0-windows-x64-setup.exe`, 130,916,841 bytes, `03e2e3046823cee30083696ebac06b2a604a1c91f6e4ff6a31b7d6a40f2ac705`
- Linux: `Thumble-Receiver-0.2.0-linux-x64.tar.gz`, 212,232,134 bytes, `599926ccd76e0aa7ecdd08a9038bd1200ad0be24b049ac72d39b097420ec82fe`

## Mac 1.1.0

Built and signed locally with Developer ID profile `PTQ96A4K5H`. App notarization `839492e7-290e-42a6-a939-d5091e602707` and DMG notarization `3f675d92-f2d0-4d3e-a570-ad1c21065cca` were accepted, stapled, and the DMG assesses as Notarized Developer ID. See `docs/releases/macos-receiver-1.1.0.json`.

## Publication

Uploaded to R2 `pocketpad-releases`; download Worker version `500a86e2-acae-4c42-b0c7-1212bdcf39a4`. All ten public files (installers, setup guide, manifest, checksums) were downloaded through thumble.io and are byte-identical to the local release files; each checksum verifies; the latest aliases redirect to 1.1.0 and 0.2.0; 1.0.3 and 0.1.1 remain available; the downloaded DMG passes Gatekeeper.

Not verified here: real-game play with the new receivers, Studio inside the signed macOS app window, and Windows/Linux installs on physical machines.
