# App Privacy declaration preparation

Do not publish 'Data Not Collected' if optional Cloud Controllers is included.

The release's core local path keeps control input, chat/transcripts, pairing,
calibration, profiles and demo usage on the paired devices. Camera scans are local.
The purchase verifier processes signed store proofs and generated device IDs in
real time, does not persist a customer database, and does not log proof contents.
Apple excludes real-time, discarded request data from its collection definition.

Optional cloud changes the declaration. The current Better Auth/D1 migration
stores name, email, provider account/user IDs, sessions (IP/user-agent), cloud
profiles/revisions, devices and delivery status. Review the final implementation
and its retention/deletion code before publishing. Expected purposes are App
Functionality and security, linked to the signed-in user, with no tracking,
advertising, sale of data or analytics SDK use.

Candidate disclosures to reconcile with final code:

| Apple data type | Evidence/purpose |
| --- | --- |
| Name and Email Address | Apple/Google account profile, sign-in and account contact |
| User ID | Provider/account ID, authorizing agent access and account isolation |
| Device ID | Registered phone ID/name, targeting controller delivery |
| Other User Content | Private controller profiles/layout text and revisions |
| Product Interaction | Delivery/receipt activity retained to complete and diagnose requested transfers |
| Other Diagnostic Data / Other Data | Retained security/session metadata, only as the final implementation warrants |

Do not declare camera images, payment card details, or game-chat text as collected
by Thumble's cloud based only on local processing. Reconcile OS online speech
processing with Apple's current disclosure guidance and the final on-device /
user-enabled online recognition behavior. Profile data shared with a user-chosen
AI agent is also subject to that provider's practices.

The website launch list and direct support email are separate user-initiated
website/support channels; their collection is disclosed in the website policy.
Do not describe optional cloud collection as being required for local controller use.

Sources:
- https://developer.apple.com/app-store/app-privacy-details/
- https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy
- https://thumble.io/privacy
