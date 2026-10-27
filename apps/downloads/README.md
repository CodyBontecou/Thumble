# Thumble receiver downloads

This Worker serves an explicit allowlist of public receiver releases from
`pocketpad-releases`. Other bucket objects and the legacy Mac app manifest remain
private to their existing endpoints. Large files stream directly from R2.

| Download | Alias | R2 prefix |
| --- | --- | --- |
| Signed/notarized macOS 1.0.0 DMG | `/downloads/receiver-latest.dmg` | `macos/receiver/` |
| Unsigned Windows x64 0.1.0 preview setup | `/downloads/receiver-latest-windows.exe` | `windows/receiver/` |
| Linux x64 0.1.0 preview archive | `/downloads/receiver-latest-linux.tar.gz` | `linux/receiver/` |
| Desktop setup instructions | `/downloads/receiver-desktop-setup.txt` | `desktop/receiver/` |

Aliases redirect without caching. Versioned filenames and their `.sha256` files
are immutable. The allowlist also publishes
`/downloads/Thumble-Receiver-0.1.1-desktop.json` with the preview's source commit,
validation run, file sizes and hashes. See `docs/releases/desktop-receiver-0.1.0.json`.

## Publish

Download Windows and Linux artifacts only from a fully passing **Desktop receiver**
Actions run. Verify their bundled `SHA256SUMS`; retain the tested package bytes.
The Windows installer is an unsigned preview and requires separate ViGEmBus setup.
Linux requires uinput permissions. Public copy must retain these requirements and
must not imply real-game acceptance solely from native CI checks.

Build macOS with `tools/build-macos-receiver.sh`, then
`tools/package-macos-receiver.sh`. Both app and DMG must pass notarization,
stapling and Gatekeeper assessment before upload.

Use a new versioned filename for every release, update `src/worker.js`, and retain
published artifacts. Upload files/checksums with
`wrangler r2 object put pocketpad-releases/<prefix>/<filename> --remote --file <file>`.
Run `node --test tools/test/downloads-worker.test.js`, dry-run the Worker deployment,
then deploy with `wrangler deploy --config apps/downloads/wrangler.jsonc`.
Verify public GET/HEAD, alias targets and downloaded SHA-256 before adding links.

The website source is currently `../Thumble-legacy/Website`, deployed to Pages
project `pocketpad-site`. Its download cards and `/docs#desktop-receivers` explain
all three platforms. Preserve the published `/cli/` files when deploying that
source, since CLI archives are generated outputs stored separately.

Desktop preview 0.1.1 retains phone pairing across checkout, app/receiver restarts, and sleep. Publish only installers from the successful native Windows/Linux workflow run recorded in `docs/releases/desktop-receiver-0.1.1.json`. Keep previous versioned objects immutable. The private reviewer ZIP retains its separate authentication requirement.
