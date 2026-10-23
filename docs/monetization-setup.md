# Native purchases and the 30-minute demo

The implementation uses StoreKit 2 on iOS and Google Play Billing 8.3 on Android.
There is no RevenueCat dependency. The full app has a total 1,800-second
connected-use demo. Custom layouts, saved profiles and integrated dictation are
available without purchase. Pro only removes the usage limit. Calibration,
pairing, setup and local practice are free. No visual editor is included.

## What is implemented

- Explicit demo start/resume, foreground controller-session metering, pause on
  menus/background/disconnect, remaining-time display and expiry state.
- Receiver-authoritative neutral cutoff, including a held stick or button, with
  all disk writes on a utility queue rather than the HID queue.
- Five-second prepaid reservations persisted atomically with fsync; clean pauses
  return unused reservation time. One-second prefetch means a crash can lose up
  to six seconds of unused allowance.
- Phone usage mirror in iOS Keychain / Android private app storage (unsigned iOS simulators use sandbox defaults), and a Mac
  ledger shared by phones using that receiver installation. Re-pairing, profiles
  and wall-clock changes do not replenish the allowance. Clearing both sides or
  using new devices is not prevented by an identity server.
- Native purchase, pending/cancel handling, transaction updates and same-store
  restoration. Apple transactions finish after native verification. Google
  purchases are acknowledged by the verifier after server-side store validation.
- A small first-party verifier that checks Apple/Google directly and signs a
  receiver-and-phone-bound grant. The receiver verifies the signature before
  removing the time limit. MCP operations never require a purchase, and neither
  profile changes nor MCP activation replenish demo time.
- Seven-day cached grants permit offline use between successful verification
  checks. A store/network error does not revoke an unexpired verified grant.
  Restoring on a new receiver needs internet. Confirmed refunds revoke access
  at refresh; offline revocation is delayed until refresh/grant expiry.
- Profile data, selected layouts and typed drafts survive expiry or access loss.
  Demo and Pro connections both restore their selected custom layout. Profile
  management remains available after expiry; live game input and chat sending
  require remaining demo time or verified unlimited access.

## Store setup required before purchases can be enabled

1. Finalize production bundle/package identifiers. Current app config contains
   development identifiers; do not register production products against those.
2. Create `tapping_pro_lifetime` as an Apple non-consumable and a Google Play
   non-consumable one-time product. Set the US base price to $19.99 in each store,
   then configure regional prices/availability. The app displays the actual
   localized store price. Enable In-App Purchase for the Apple app and complete
   store agreements, tax/banking and review requirements.
3. Create Apple App Store Server API credentials (issuer ID, key ID, private p8)
   and download Apple root certificates from Apple's PKI site. Create a Google
   service account with access to the app's purchases in Play Console.
4. Generate an Ed25519 signing key on the verifier host with
   `node tools/create-entitlement-keys.mjs /absolute/private/path/grant.pem`. Keep the private key in
   a secret file outside source control. Set its raw 32-byte base64 public key in
   `config/monetization.json` as `entitlementPublicKey`.
5. Deploy `apps/entitlements` behind HTTPS and rate limiting. Set its base URL in
   `config/monetization.json` as `entitlementServiceURL`. The endpoint is
   `POST /v1/grants`; mobile sends native purchase proof and receiver challenge.
   Never log request bodies, purchase tokens, JWS receipts or private keys.
6. Add actual privacy/terms/support URLs to the same config and validate it with
   `node tools/check-monetization-config.mjs`. Rebuild both mobile apps and the
   receiver: its signed resource bundle contains the public verification key.
7. Verify sandbox purchase/restore/cancellation/pending/refund on both stores,
   using distinct sandbox signing keys/services. Production must not accept
   sandbox purchases. Same-store ownership restores across devices; cross-store
   iOS-to-Android ownership is not implemented.

The app deliberately disables purchase initiation while the verification service
and public key are unconfigured. It does not charge someone for an unlock the
receiver cannot verify. Restore remains available.

## Verifier configuration

Start with `npm run start --workspace @tapping/entitlements`. The Node 22+ service
binds loopback port 8788 by default; terminate HTTPS at a reverse proxy. Configure
body/request-rate/concurrency limits at that proxy. The service bounds bodies and
request timeouts too. Deploy secrets through the host's secret manager:

| Variable | Meaning |
| --- | --- |
| `TAPPING_GRANT_PRIVATE_KEY_FILE` | Ed25519 PKCS#8 PEM signing key file |
| `PORT` | Optional loopback port, default 8788 |
| `APPLE_ENVIRONMENT` | `Production` or isolated `Sandbox` deployment |
| `APPLE_BUNDLE_ID` | Exact registered iOS bundle ID |
| `APPLE_APP_ID` | Numeric Apple app ID, required in Production |
| `APPLE_ISSUER_ID` / `APPLE_KEY_ID` | App Store Server API identity |
| `APPLE_PRIVATE_KEY_FILE` | Apple p8 key file |
| `APPLE_ROOT_CERTIFICATES` | Comma-separated paths to Apple root DER certificates |
| `GOOGLE_PACKAGE_NAME` | Exact registered Android package name |
| `GOOGLE_APPLICATION_CREDENTIALS` | Google service-account JSON file |

At least one store must be configured. The verifier uses Apple's official
`@apple/app-store-server-library` to validate JWS chains and fetch transaction
status. Google authorization uses a signed service-account JWT and Play Developer
API purchase-state checks; pending/consumed purchases never grant Pro.

A production availability/security review, real store purchase validation and
hosting are still required. No production products, signing secrets or deployed
service were available in this workspace during implementation.

## Verification commands

```sh
npm test
npm run typecheck --workspace @tapping/mobile
npm run lint --workspace @tapping/mobile
npm run test:access
node tools/test-access-receiver.mjs
node tools/test-profile-catalog.mjs
npm run test:chat
```

The access unit tests use a fake monotonic clock to exercise the full 30 minutes
without waiting in real time. The integration test compiles an isolated TLS
receiver linked to a reporting stub, never a real HID device. Its short residual
allowance verifies expiry during held input and a signed Pro grant after expiry.
`--preview` runs that fake-HID receiver for manual simulator inspection; stop with
Ctrl-C and do not share its private invitation file.

## Remaining release policy checks

Apple's documented non-subscription trial mechanism describes a free IAP named
“XX-day Trial,” rather than this 30-minute usage demo. Obtain App Review guidance
before public submission. Do not replace the product with an auto-renewing trial.

Thumble Bridge, agent-created layouts and saved-profile tools have no purchase
gates. The only paid benefit is unlimited controller time. The addon remains free
and does not display purchase prompts. Review the final app presentation against
Blizzard's policy before public launch.

References: [StoreKit](https://developer.apple.com/documentation/storekit),
[Google Billing](https://developer.android.com/google/play/billing/integrate),
[Apple server library](https://github.com/apple/app-store-server-library-node),
[Apple review rules](https://developer.apple.com/app-store/review/guidelines/#in-app-purchase),
[Blizzard addon policy](https://eu.forums.blizzard.com/en/wow/t/wow-user-interface-add-on-development-policy/1642).
