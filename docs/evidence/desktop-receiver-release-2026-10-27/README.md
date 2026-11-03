# Desktop receiver 0.1.1 — October 27, 2026

Native Windows/Linux CI passed: https://github.com/CodyBontecou/Thumble/actions/runs/40509685547

Installer source: `85ea6d605e3ef7660a66b4b86dc6cb8fd5c90d4e`.
Download Worker version: `8bb8b089-b6a9-43f1-a112-d5efdbb834c4`.

The Windows XInput and Linux evdev native gamepad tests, isolated native desktop UI/power tests, and installed/frozen runtime and GUI checks passed on both platforms. The final regression suite has 80 tests; the separate native UI job executes checks skipped by the headless suite.

This preview persists the TLS certificate, listener port, and phone-bound reconnect credential. Sleep and shutdown preserve trust; explicit unpairing revokes it. Reconnect creates a fresh input session. A regression discovered on Windows also verifies that newer UDP input can overtake queued TLS input without replaying stale state or disconnecting; replay on the TLS stream remains rejected. Linux upgrades retain enabled sign-in startup using the new installed binary.

Published installers are byte-identical to the artifacts from the successful run. The public setup guide, release manifest, installers, and all four checksum files were downloaded through thumble.io and matched their local hashes. Public GET/HEAD, latest aliases, previous versions, and reviewer authentication were verified. `native-ci.json` and `public-verification.json` retain the evidence.

Windows: https://thumble.io/downloads/Thumble-Receiver-0.1.1-windows-x64-setup.exe

Linux: https://thumble.io/downloads/Thumble-Receiver-0.1.1-linux-x64.tar.gz

Manifest: https://thumble.io/downloads/Thumble-Receiver-0.1.1-desktop.json

These remain unsigned desktop previews. Real WoW/Steam/Proton acceptance remains separate from automated native-device validation. Existing installations need one QR pairing with the updated phone app to establish durable reconnect trust.

Website deployed from clean release commit `1a15100bb9ab54129697ddfaa1445f13be0c8c6d`: https://9dc8f03f.pocketpad-site.pages.dev . Live homepage and docs show the 0.1.1 installer/checksum links.

All 39 live website checks passed after accounting for the exact existing homepage language links and Chinese sitemap entry added by the production edge. The direct Pages artifact matched the clean build, and the existing Chinese route remained HTTP 200. Negative checks confirmed changed installer links and unknown HTML still fail verification.
