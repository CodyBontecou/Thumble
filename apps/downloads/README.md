# Thumble receiver downloads

This Worker serves only the signed release DMG and its SHA-256 checksum from
`pocketpad-releases/macos/receiver/`. The existing website and older app download
manifest are independent of this endpoint.

- `/downloads/receiver-latest.dmg` redirects to the current version.
- `/downloads/Thumble-Receiver-1.0.0.dmg` serves the immutable release.
- `/downloads/Thumble-Receiver-1.0.0.dmg.sha256` serves its checksum.

Build with `tools/build-macos-receiver.sh`, then run
`tools/package-macos-receiver.sh`. Both the app and DMG must pass notarization,
stapling and Gatekeeper assessment before upload. Publish the DMG and checksum with
`wrangler r2 object put --remote --file …`, then deploy this Worker with
`wrangler deploy --config apps/downloads/wrangler.jsonc`.

For a subsequent release, use a new versioned filename and update the explicit
allowlist in `src/worker.js`. Retain published immutable artifacts. Verify the
downloaded SHA-256 against the local stapled DMG after deployment.
