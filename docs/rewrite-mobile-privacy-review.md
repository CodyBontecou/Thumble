# Mobile privacy review draft

This is a source-derived worksheet for the explicit Thumble store profile, not a published policy, completed privacy label or legal/export classification. The website's `Website/privacy.html` covers the launch waitlist and is not a replacement for an app policy. Confirm the eventual published app-policy URL and contact before submission.

## Data flows to review

| Feature | Current implementation | Destination/storage and review boundary |
| --- | --- | --- |
| Pairing QR camera | Explicit native camera permission; AVFoundation metadata / ZXing decode the invitation | No photograph/gallery permission is required. Camera frames stay in the scanner; decoded invitation passes through native enrollment. No invitation secret or credential enters the JS renderer. Review the final native binary and dependencies. |
| Saved host and feedback preference | App-local UserDefaults/shared preferences | Host address, certificate pin, ephemeral authority metadata and local haptic choice remain local. Credentials are separately protected by Keychain/Keystore. These are not an app-service account. |
| Enrollment and reconnect | Pinned TLS to the computer explicitly paired by the user | Native credential authentication; no hosted relay or developer-operated login service in the audited phone flow. Host identity/trust records live on the user's computer. |
| Controller state and saved layouts | Authenticated encrypted native input; bounded saved-catalog/control-map reads | Exchanged with the paired computer. Inputs drive its headless native receiver. The renderer receives public control-map metadata, not native credentials. No cloud analytics or advertising SDK is intentionally configured. |
| Diagnostics/support | Bounded native error/phase logging; private QA captures and operator CLI receipts | Logs do not automatically upload to a developer backend in the audited flow. A user may choose to send diagnostic material to support. Do not include invitations, credentials, private configuration or raw account/game data in support artifacts. |
| User-chosen agents | Local CLI/MCP configuration on the user's computer | A separately configured agent/provider may process data the user authorizes it to read. Do not describe that separate provider as part of a blanket phone-app “all data stays local” promise. |

The app provides no hosted user-account signup. Pairing revocation through the headless host invalidates that phone's credential. Do not claim that uninstalling iOS necessarily deletes Keychain items; Keychain may survive reinstall. Verify the final forget/unpair UX and local-retention instructions before publishing deletion claims. Review `privacy@codybontecou.com`, used by the existing website, as a candidate contact rather than assuming mailbox operation is verified.

## Native declarations

Store-only `ios.privacyManifests` now declares app-private UserDefaults reason `CA92.1` for saved host/feedback preferences and system-boot-time reason `35F9.1` for local elapsed-time/timer calculations in touch, haptic and route timing. No absolute boot time is intentionally sent off-device by those paths. These reasons describe app-owned API use; they do not replace third-party SDK manifests or the final privacy report. [Apple required-reason definitions](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons), [Expo manifest configuration](https://docs.expo.dev/guides/apple-privacy/).

The store profile blocks inherited Android external-storage and overlay permissions. A fresh release manifest merge includes only INTERNET, VIBRATE, CAMERA and the package's nonexported dynamic-receiver permission. Camera hardware is optional, preserving manual invitation entry. Camera and local-network purpose strings remain explicit on iOS. The development profile is unchanged. [Expo permission controls](https://docs.expo.dev/guides/permissions/).

The generated Expo app manifest currently contains an empty collected-data array and tracking=false. Treat this as generated metadata requiring final dependency/artifact review, not proof that store labels are complete. Apple defines collection by off-device access/retention; Google's definitions include off-device transmission and document a conditional end-to-end-encryption exception. Assess the actual final build, paired-recipient/key ownership, diagnostic practices and every included SDK before choosing answers. [Apple privacy details](https://developer.apple.com/app-store/app-privacy-details/), [Play Data safety](https://support.google.com/googleplay/android-developer/answer/10787469).

## Encryption declaration remains explicit review work

The phone uses pinned TLS and standard cryptographic APIs, including CryptoKit for the authenticated input packet protocol. Do not set `ITSAppUsesNonExemptEncryption=false` merely because traffic stays on a LAN or uses system crypto. App Store export questions, distribution regions and any documentation requirement must be resolved for the final app. The store source intentionally does not invent that answer. [Apple export-compliance overview](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/).

## Draft user-facing policy substance

After the above checks, a mobile-specific policy can explain: Thumble connects to the computer you pair, processes QR images locally, stores connection/feedback settings on your phone, protects pairing credentials in native secure storage, and sends encrypted controller state to your paired computer. It should distinguish the separate website waitlist and user-selected agent providers; explain local revocation and Keychain retention; identify the operator/contact; and state the actual effective date, support handling, retention and third-party practices. Publish only after reviewing those concrete claims and the final artifact inventory.
