# Native purchases and plans

The implementation uses StoreKit 2 on iOS and Google Play Billing 8.3 on Android.
There is no RevenueCat dependency.

## Hard paywall (November 2026)

The phone gates the controller behind a plan, right after Welcome. Plans match
Health.md's catalog:

| Plan | iOS product | Google Play product | US list price | Trial |
| --- | --- | --- | --- | --- |
| Weekly | `thumble_weekly` | `thumble_weekly` | $0.99 | 7 days |
| Yearly | `thumble_yearly` | `thumble_yearly` | $29.99 | 7 days |
| Lifetime | `thumble_pro_lifetime` | `thumble_pro_lifetime` | $49.99 | none |
| Family weekly | `thumble_family_weekly` | — | $1.99 | 7 days |
| Family yearly | `thumble_family_yearly` | — | $49.99 | 7 days |
| Family Lifetime | `thumble_family_lifetime` | — | $89.99 | none |

Lifetime keeps the existing product ID so earlier Pro purchases remain valid.

### App Store Connect (created November 3, 2026)

Subscription group **Thumble Plans** (`22541028`), all 175 territories plus new
territories, US base price with Apple's equalized matrix, one-week free-trial
introductory offer in every territory, App Review screenshot attached:

| Product | Apple ID | Level | Family Sharing | US price |
| --- | --- | --- | --- | --- |
| `thumble_family_yearly` | 6830168329 | 1 | yes | $49.99 |
| `thumble_family_weekly` | 6830168176 | 1 | yes | $1.99 |
| `thumble_yearly` | 6830167151 | 2 | no | $29.99 |
| `thumble_weekly` | 6830168168 | 2 | no | $0.99 |

Family ranks above Individual so switching to Family is an upgrade, matching
Health.md. `thumble_pro_lifetime` (6826421543) moved from $19.99 to **$49.99**
(US base, automatic equalization). `thumble_family_lifetime` (6830171148) is a
Family-sharable non-consumable at **$89.99** in all territories. All new
products are Ready to Submit with Release-build captures of the Plans slide
(Individual and Family views) as review screenshots; submit them with the next
app version. Lifetime is already waiting for review, so its earlier screenshot
is locked. A Release simulator build loads all six products from StoreKit at
these prices, each subscription with its 7-day trial.

### Google Play (created November 3, 2026)

The `thumble-play-verifier` service account was granted **Manage store presence**
for com.thumble.android (it already had View financial data). Prices use Google's
regional conversion of the US price, regions version 2026/01, 174 regions:

| Product | Type | US price | Trial | State |
| --- | --- | --- | --- | --- |
| `thumble_weekly` | Subscription, base plan `weekly` (P1W) | $0.99 | `free-trial` offer, 1 week, new subscribers | Active |
| `thumble_yearly` | Subscription, base plan `yearly` (P1Y) | $29.99 | `free-trial` offer, 1 week, new subscribers | Active |
| `thumble_pro_lifetime` | One-time, option `lifetime` | $49.99 (was $19.99) | none | Active |

The Lifetime listing copy now describes unlimited play rather than removing a
time limit. Google Play has no Family plans. Billing only answers Play-installed
builds, so test purchases need an internal-testing install.

`TappingPurchases.catalog(ids)` returns localized prices and trial eligibility
from the store; `purchase(id)` buys a plan; `status()` reports `active`,
`expired`, `billing`, `pending` or `free` with the current plan's proof,
expiry and trial flag. Google Play only reports current subscriptions, so a
previously entitled Android account without one is shown as `expired`.

The entitlement worker accepts any plan product, checks that a subscription is
current (Apple `expiresDate`; Google `subscriptionsv2` state), acknowledges
Google subscriptions and signs the existing receiver grant. The grant keeps the
`thumble_pro_lifetime` entitlement name and caps `expiresAt` at the plan's
expiry, so the macOS and desktop receivers need no grant changes. Receivers
no longer give a free 30-minute demo: controller output and chat require a valid,
unexpired grant. `demo.json` stays as the receiver record because grants are
bound to its receiver ID.

The sections below record the original one-time Pro setup.

## App Store Connect record (October 23, 2026)

- New listing: **Thumble: Phone Controller** — app ID `6826421489`,
  bundle ID `com.thumble.ios`, SKU `THUMBLE_IOS_001`, primary locale `en-US`.
- Listing: https://appstoreconnect.apple.com/apps/6826421489/distribution
- Registered Apple bundle resource: `48LYFB3K3A`, team `67KC823C9A`;
  In-App Purchase capability enabled.
- App download price: Free. Initial iOS version: `1.0.0`, manual release.
- Pro: `thumble_pro_lifetime`, non-consumable, reference name
  **Thumble Pro Lifetime**, Apple product resource `6826421543`.
  US base price verified at **$19.99 USD**.
- Product display name: **Thumble Pro**. Description:
  “Unlimited controller time with a one-time purchase.”
- App and Pro availability configured for all 175 current App Store territories,
  with availability in new territories enabled, as approved by the owner.
- Set verifier `APPLE_APP_ID=6826421489` and `APPLE_BUNDLE_ID=com.thumble.ios`.
- The old ThumbConsole/PocketPad listing (`6788494990`) was left unchanged;
  this is a separate replacement app, as requested by the owner.
- The mobile icon is copied byte-for-byte from the older Thumble project’s
  `Resources/iOS/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` into
  `apps/mobile/assets/icon.png`. Expo regenerates the iOS and Android assets;
  App Store Connect receives the new app icon with the uploaded build.

The app and Pro product have not been submitted for review. A signed production
build, real purchase tests, final review screenshots, privacy/support URLs,
App Privacy/age-rating declarations and reviewer instructions still need to be
completed. Production purchase verification and Google store credentials remain
unconfigured; the isolated Apple sandbox verifier is configured below. Do not use the current “Purchases coming soon” screenshot as the
final IAP review screenshot.

## TestFlight purchase test setup (October 23, 2026)

The sandbox verifier is deployed at
`https://thumble-purchases-sandbox.costream.workers.dev` in the owner's Cloudflare
account. `apps/entitlements/wrangler.jsonc` defines the deployment. Its encrypted
secrets hold the Apple account's existing IAP key (reused with explicit owner
approval), Apple trust roots and a separate Ed25519 grant key. Secrets are never
embedded in the phone or receiver. The ignored local backup is under
`.secrets/purchases/`; keep this owner-only, git-ignored backup secure.

`GET /health` initializes Apple's official verifier and validates the signing-key
type. `POST /v1/grants` bounds requests and rate-limits attempts, verifies the Apple
certificate chain and current transaction through Apple's sandbox API, then signs
the receiver/phone/nonce-bound grant. Production and Android purchases are rejected
by this sandbox deployment. Apple accepted the credentials in an authenticated
sandbox API check; a real Thumble sandbox transaction still requires the tester's
purchase. The endpoint rejects forged proofs.

TestFlight build 2 and the TestFlight receiver share the sandbox public key.
They are for **TestFlight only**. Production source configuration now points to
the separate production verifier/key; rebuild the phone before an App Store
release. Do not submit the sandbox-only build for public release.

For this test, use `build/Thumble TestFlight Receiver.app`. Both test and
production receivers retain `com.codybontecou.PocketPadMac` (`CX585YS32T`) to reuse
its existing **production HID Virtual Device** approval, verified in the Developer
portal. The visible name remains Thumble Receiver. The unused `com.thumble.macos`
registration is not needed for this release. Public downloads additionally need a
matching Developer ID profile and a usable Developer ID Application private key.
Build the test companion with:

```sh
bash tools/build-macos-receiver.sh /path/to/existing-approved.provisionprofile \
  'Apple Development identity' --testflight
```

Quit the previous receiver before opening the TestFlight receiver, then pair again.
Do not run both receivers simultaneously. The build process does not restart the
running receiver or alter existing profiles/demo usage.

### Production verifier and Mac distribution

The production Worker is deployed at
`https://thumble-purchases.costream.workers.dev`, configured by
`apps/entitlements/wrangler.production.jsonc`. It has a separate Ed25519 grant key
from sandbox. `config/monetization.json` contains the production URL/public key;
`config/monetization.sandbox.json` preserves the TestFlight configuration. Existing
TestFlight build 2 still uses the sandbox configuration embedded at build time.

Production verifies signed Apple transactions and fetches their current status
from Apple. An explicit App Review setting permits sandbox transactions only after
Apple's verifier reports a verified environment mismatch; invalid signatures,
certificates and bundle identifiers are rejected. Google Play requires separate
service-account credentials and is not yet configured on the hosted Worker.

At setup, production `/health` returned 200, and sandbox API authentication
succeeded. Apple's production API returned 401 for the unreleased app. Apple's
[server-library maintainer explains](https://github.com/apple/app-store-server-library-node/issues/209)
that production API access requires a production release. Production purchases
remain unverified end to end until a real transaction is tested after release;
the health check confirms local configuration, not Apple production access.

The existing Mac identifier has production HID enabled. The owner authorized a new
Developer ID Application signing certificate, issued as `FQP4WCVJLB` (expires
2027-11-22), with distribution profile `PTQ96A4K5H`. The profile authorizes virtual
HID for all Macs. Existing certificates were preserved. The signing identity is in
an owner-only dedicated keychain at `.secrets/mac-signing/thumble-signing.keychain-db`;
the CSR, private key, certificate, encrypted PKCS12 and keychain password are backed
up in the same ignored directory. Keep this directory private and back it up securely.
Set `THUMBLE_SIGNING_KEYCHAIN` to the absolute keychain path when building locally.
The SHA-1 signing identity is `F99E7E4531AE49E2E5DEF117EFBE0D1CA2CC5FB4`.

Build and package:

```sh
bash tools/build-macos-receiver.sh /path/to/developer-id.provisionprofile \
  'Developer ID Application identity'
bash tools/package-macos-receiver.sh 'Developer ID Application identity'
```

The release script notarizes and staples the app, creates a DMG containing the app
and an Applications shortcut, then signs, notarizes and staples the DMG. Gatekeeper
assessment must pass before uploading `build/distribution/Thumble-Receiver-1.0.0.dmg`
to thumble.io.

Release **1.0.0** is published at
[thumble.io/downloads/receiver-latest.dmg](https://thumble.io/downloads/receiver-latest.dmg),
redirecting to the immutable `Thumble-Receiver-1.0.0.dmg`. The checksum is at the
same versioned URL with `.sha256` appended. The download Worker is in
`apps/downloads/`, serving only the explicit release allowlist from the existing
R2 bucket. The website's older release manifest is unchanged.

Apple accepted app submission `6eac35d2-4f28-42bc-9632-5c2f8b78d299` and DMG
submission `2fc6ed68-1634-4ce8-87bc-13cfc17bc2b3`. Both have stapled tickets and
passed Gatekeeper assessment. The DMG contains the validated universal app and an
Applications shortcut. SHA-256:
`edfa5e11224d3de34f92a9cea94f6c5c021b88a26aef10a8982c8bdefebd710a`.
The receiver was not launched as part of release verification.

Internal TestFlight group: **Thumble Internal**
(`76d1f1c6-9e57-4588-afe8-b72f30e87b8e`). Test with the owner's enrolled Apple
account. Install the new app from TestFlight, pair the test receiver, open Pro,
and purchase `thumble_pro_lifetime`. Apple TestFlight transactions are sandbox
transactions and are not charged. Confirm unlimited time, restart/restore, and
restoration after reconnecting. Cancellation should leave the demo unchanged.

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

1. Use `com.thumble.ios` (Apple iOS), `com.thumble.android` (Google Play),
   and the existing `com.codybontecou.PocketPadMac` (Mac receiver). The Mac identifier
   preserves the existing production HID approval; its visible name is **Thumble
   Receiver**. iOS is registered and its App Store name is **Thumble: Phone Controller**.
   Mac distribution needs a matching Developer ID profile authorizing
   `com.apple.developer.hid.virtual.device`, signed with a certificate in that profile.
2. Create `thumble_pro_lifetime` as an Apple non-consumable and a Google Play
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
| `APPLE_BUNDLE_ID` | `com.thumble.ios` |
| `APPLE_APP_ID` | Numeric Apple app ID, required in Production |
| `APPLE_ISSUER_ID` / `APPLE_KEY_ID` | App Store Server API identity |
| `APPLE_PRIVATE_KEY_FILE` | Apple p8 key file |
| `APPLE_ROOT_CERTIFICATES` | Comma-separated paths to Apple root DER certificates |
| `GOOGLE_PACKAGE_NAME` | `com.thumble.android` |
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

The access unit tests use a fake wall clock and a throwaway signing key to check
that a phone without a grant cannot start, that a valid grant can, that expiry
stops output, and that demo-era records keep their receiver ID. The integration
test compiles an isolated TLS receiver linked to a reporting stub, never a real
HID device, and signs its own short-lived grant to verify expiry during held input.
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

## Branding compatibility

New pairing links use `thumble://pair`; existing `tapping://pair` links are still
accepted. Internal npm workspace names, native module names, environment variables,
and persisted storage keys/directories retain their legacy names to preserve
profiles, pairing state and demo ledgers. The repository path is unchanged.
Historical validation reports describe the older development artifacts, not the
new production identifiers. Changing mobile app identifiers creates separate app identities and can separate
local app data from the installed development apps. This rename does not migrate
data between those installations.

### Local TestFlight build notes

Apple rejected build 1 with ITMS-90683 because a bundled framework references
photo-library APIs. Build 2 adds the required NSPhotoLibraryUsageDescription
without requesting photo access or adding a photo feature. The app already
includes camera, local-network, microphone and speech purpose strings.

Distribution profile: **Thumble App Store**, Apple resource `PXUHN5M5A9`,
UUID `30f69404-c8c5-4e04-98b3-becf02b65d82`, existing certificate `7LBA9GBNXH`.
The local generated Xcode application target uses manual signing with this profile
and iPhone Distribution identity; CocoaPods targets keep their existing settings.
When regenerating iOS native files, reapply those application-target signing
settings before archiving. Set MARKETING_VERSION=1.0.0 and use the build number
from app.json. Archive/export with asc xcode, then upload using asc publish
testflight targeting app 6826421489 and group Thumble Internal. Do not distribute
a sandbox build through an App Store public release.

### Verified TestFlight delivery

Build **1.0.0 (2)** was accepted by Apple with processing state **VALID**.
Build resource: `a38cc790-4365-4173-81c0-8e19f88885ce`. It is assigned to
**Thumble Internal** with all-builds access; the owner's tester is **INVITED**.
What to Test notes include the required companion receiver and sandbox purchase
instructions. Artifacts: `build/Thumble-TestFlight-2.xcarchive`,
`build/Thumble-TestFlight-2.ipa`, and `build/Thumble TestFlight Receiver.app`.

Validation: 93 Node tests, mobile lint/type checks, signed iOS archive/export,
strict receiver signature verification, matching phone/receiver verification keys,
Apple sandbox API authentication, live Worker signing health, and forged-proof
rejection. A genuine purchase and restore on the tester's TestFlight installation
have not yet been performed. Upload/processing receipt: `build/testflight-upload-2.log`.

### Local unlimited controller testing

For owner-device gameplay QA, build the separately named **Thumble Local Test Receiver**:

```sh
THUMBLE_SIGNING_KEYCHAIN="$PWD/.secrets/mac-signing/thumble-signing.keychain-db" \
  bash tools/build-macos-receiver.sh .secrets/mac-signing/Thumble-DeveloperID.provisionprofile \
  F99E7E4531AE49E2E5DEF117EFBE0D1CA2CC5FB4 --local-testing
```

Quit the normal receiver, open `build/Thumble Local Test Receiver.app`, and pair the test phone. This build includes `THUMBLE_LOCAL_TESTING`, grants unlimited controller access over the existing access protocol, and labels its menu **Local testing · unlimited controller time**. The phone displays its existing unlimited/Pro badge; this does not create a store purchase or signed ownership grant. Returning to the normal receiver restores ordinary access enforcement. Demo usage and saved layouts are preserved. The normal receiver and release packaging paths do not include the testing flag; this local app is not a public release or a purchase-validation test.

`node tools/test-local-test-access.mjs` compiles both variants and checks resume for a phone with no plan, 24-hour use, reconnect, unchanged ledger, absence of fabricated grants, and normal-build enforcement. The existing `npm run test:access` grant and receiver-record tests also pass.

On October 24 the cabled iPhone 13 Pro Max was paired to this local build for ConsolePort auto-sync/layer-switching QA. Argent observed **Thumble Pro, unlimited controller time**, and the receiver reported an acknowledged ConsolePort layout at activation 16 with unlimited access. The app's existing purchase/free-time settings were not changed.
