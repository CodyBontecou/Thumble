# Explicit macOS pairing QR export

Build the optional renderer with `bun tooling/build.ts --with-pairing-qr` from `Rewrite/`. This composes with `--with-macos-output` and `--with-wow-capture`; the default package excludes and removes stale QR artifacts. Build/assembly never runs the renderer, opens pairing, signs code or emits input. The package has a fixed sibling `thumble-pairing-qr-macos` executable, a SHA-256 manifest and notices. Apple frameworks are not redistributed; there are no external Swift package dependencies.

Start the headless service using an initialized persistent host identity. Then explicitly reveal a network pairing invitation and export its QR:

```sh
thumble-rewrite pairing listen \
  --runtime-dir /absolute/private/runtime \
  --bind-address 0.0.0.0:0 --advertise-host YOUR_MAC_LAN_ADDRESS \
  --reveal-secret --qr-output /absolute/private/new-pairing.png --json
```

The bind address includes a port; zero requests an ephemeral port. Use an actual address reachable by the phone as advertise-host. The QR uses only the exact seven fields returned by the native receiver; it never derives a replacement address from a wildcard or loopback bind. `pairing open --reveal-secret --qr-output ...` exports a new offer only when the existing persisted transport returns a complete network invitation. A three-field offline offer cannot become a QR invitation.

Use `--qr-helper /absolute/thumble-pairing-qr-macos` to select a renderer explicitly. Otherwise the standalone CLI looks for its packaged sibling. In an isolated development app bundle the helper is `Contents/Helpers/thumble-pairing-qr-macos`; the main receiver alone retains HID entitlements. Development bundle preparation signs an optional packaged QR helper without HID privileges. Signing and source hashes are separate from code execution.

Both open/listen retain the existing mandatory `--reveal-secret` opt-in. The normal response still contains the invitation secret because the operator explicitly requested it. QR output adds only artifact path, byte count and hash. Treat the JSON response and PNG as a temporary pairing credential: keep them private and delete the image after pairing or expiration. Nothing is uploaded, opened in a browser, copied to a clipboard or sent through a deep link.

Output must be a new absolute path. The CLI refuses overwrite and symlinks, creates with O_EXCL/O_NOFOLLOW mode0600, enforces0600 on the descriptor and fsyncs before success. Existing files are never replaced. Destination/preflight failures return fixed codes; helper failure does not cancel or secretly replace the current native offer. If a write fails after file creation, a private partial file may remain for explicit deletion. Native enrollment still enforces window expiration and attempt limits.

The native child receives bounded invitation JSON only through stdin, never argv, logs or an intermediate secret file. Its stdout is bounded to1MiB with a five-second process budget; errors are sanitized to fixed codes. PNG dimensions, chunk bounds, CRC and complete termination are checked before writing. Native tests additionally decode generated QR PNGs through Vision and compare the exact payload, including IPv4, IPv6 and maximum-length host cases. No camera, desktop GUI, receiver activation or physical input is required for rendering or verification.
