# Mac receiver controller access repair

The public `receiver-latest.dmg` served 1.0.1. Its downloaded executable SHA-256
was `4af8bae594a0cd506ee001af09356b89e44c2e453182ba2606891b27e2426bd0`,
identical to the locally failing release. The DMG SHA-256 was
`4377bfa6d5d6b4840f376dd598e2738c1df558717fc86e50b2fc7f7c00dc50e6`.

## Reproduction and cause

The original Developer ID app and an identically re-signed copy both failed
virtual controller creation when launched through Launch Services. The HID log
reported `IOServiceOpen:0xe00002e2` (`kIOReturnNotPermitted`). A probe signed
with the same Developer ID identity and the same approved, active provisioning
profile succeeded when executed directly from the authorized terminal. Launching
that probe through Launch Services triggered the macOS `kTCCServicePostEvent`
privacy check. Direct terminal startup is therefore an insufficient release test.

## Changes

Release 1.0.2 opens a controller-access setup window after a HID creation failure,
explains the required macOS permission, offers the native permission request and
settings link, and retries on return or an explicit button press. Already-enabled
entries from development signing can require removal and re-adding the release
app. Copying a pairing link stays disabled until an invitation exists.

`--self-test-hid` exercises the production gamepad backend and submits only a
neutral report, without opening a listener or loading user profiles. Packaging
runs `python3 tools/check-macos-receiver-hid.py 'build/Thumble Receiver.app'`, which
uses Launch Services and checks the explicit success result. This gate reproduced
the missing-permission failure before local authorization.

## Validation so far

- The nine public/private download routing tests pass with the 1.0.2 alias and
  immutable previous releases.
- `node tools/test-reconnect-receiver.mjs` passes pairing, phone and receiver
  process restarts, phone-bound credential rejection, and explicit forgetting.
  This regression suite uses a stub HID backend and does not prove native output.
- Cloudflare deployment dry run passes.
- With owner approval, removing the stale development entry and re-adding the
  Developer ID app made the Launch Services HID gate pass. Adding the app without
  removing the stale entry did not repair the authorization.
- The final DMG and embedded app pass signature, stapling and Gatekeeper checks.
  The exact app mounted from the final DMG passes native HID creation and accepts
  the neutral report. Its executable SHA-256 is
  `2a0e57794dcff870bc4b761619784322340c281c4db14dec72bccc2ea20309ac`.
- Both app and DMG notarization are Accepted; see the release JSON for submission
  IDs, final DMG size and SHA-256.
- Physical iPhone automation could not initialize: XCTest timed out while
  enabling automation mode. This does not count as a successful pairing test.
- The owner confirmed successful QR pairing from the phone to the exact packaged
  receiver before publication.
- Published the 1.0.2 installer and checksum and advanced the public latest alias.
  Worker version: `92ee5085-75c9-48f9-b366-6565f2354005`.
- A fresh public download through `receiver-latest.dmg` redirects to 1.0.2 and
  matches the verified DMG SHA-256 and published checksum. HEAD returns 200 with
  the expected 1,868,921-byte size.

The existing Developer ID identity was recovered, with owner approval, into a
new private release keychain from the backed-up certificate and private key.
No Apple certificate was issued or revoked. No signing credentials or pairing
secrets are included in this evidence.
