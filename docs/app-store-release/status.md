# App Store review preparation — October 23, 2026

App: 6826421489 / com.thumble.ios / Thumble: Phone Controller.
Version: 1.0.0, manual release. Pro: thumble_pro_lifetime / 6826421543, $19.99 USD non-consumable.

Prepared/saved:
- App Review contact: Cody Bontecou, codybontecou@gmail.com, +1 808-384-1335.
- Subtitle: Your phone. Your controller.
- Privacy URL https://thumble.io/privacy; support URL https://thumble.io/support.
- Standard Apple EULA configured in the app; purchase/privacy/support links now present in production and sandbox source configuration.
- Age-rating questionnaire completed: no ads, gambling, violence or mature material in the app; messaging declared. Private controller profiles do not constitute broad distribution of user content under Apple’s questionnaire definition, so user-generated content is false.
- User approved v1 text/built-in symbols. Remote spell/ConsolePort artwork imports removed from the mobile renderer. Content rights set to no third-party content for that text-only release.
- Receiver 1.0.0 is signed, notarized and published on thumble.io.
- Review notes drafted in review-notes.txt; placeholders are explicit and not uploaded as final instructions.
- Two native 6.5-inch iPhone screenshots uploaded and processed successfully. Pro review image shows the real StoreKit $19.99 product; the non-consumable is READY_TO_SUBMIT.
- Paid/Free Apps agreements, banking, tax and DSA compliance checked in the authenticated account; all currently active/complete. See account-readiness.md for dates.
- Current text-only mobile renderer compiled in a standalone Release simulator build; mobile lint/typecheck, purchase/config checks and screenshot validation passed.

In progress:
- New production-configured iOS archive, upload and attachment after cloud code/signing is stable.

Remaining external/dependent checks:
- The user confirmed another chat owns Cloud Controllers. Coordination authorized; message sent to Improve agentic onboarding (2), thread 01a16aef-48e6-7d40-9263-5646e615775b. It is implementing Better Auth plus Apple/Google sign-in. Do not undo its files or remove cloud unilaterally.
- Cloud sign-in, in-app account deletion, real phone delivery/render and provider production availability must pass before submission if included.
- App Privacy publication must match the final cloud implementation, including collected account/profile/session/delivery data. The in-app browser is authenticated; the declaration remains unsaved/unpublished. Automatic approval review rejected saving a broader draft containing unverified Photos/Videos and other data categories. The modal was cancelled. Reconcile the final cloud inventory and obtain approval for exact verified disclosures before retrying; do not bypass the rejection through another interface.
- Cloud owner currently reports a Google test-user-only pilot. Public provider availability, account deletion with Apple revocation and live authenticated phone delivery still require completion/evidence. Existing source does not yet enable Better Auth account deletion.
- Real TestFlight purchase, restore and receiver unlimited-access verification. Local StoreKit fixture tests cannot prove this.
- Physical-device demonstration showing the iPhone pairing and controlling the Mac. A simulator screen recording does not establish hardware interaction.
- Apple's day-based trial language differs from a 30-minute connected-use demo. Preserve the user's approved model; explain it transparently and obtain App Review guidance if necessary. Do not silently change to subscription/trial products.
- User did not authorize final submission to review in this task; prepare but do not submit.

Current App Store Connect validation has one blocking error: no release build selected. Existing TestFlight 1.0.0 (2) is an older sandbox-configured build and must not be selected merely to clear that error. App Privacy is a separate browser-only blocker not covered by the API validator.
