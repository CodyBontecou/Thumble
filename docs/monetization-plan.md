# Full-featured demo and unlimited Pro

Updated October 23, 2026 to reflect the user's instruction: no feature gates.

## Product contract

The full app is free to try for **30 minutes total of connected controller use**,
accumulated across sessions. **Pro costs $19.99 USD once and only removes the
usage limit.** Store-localized prices are displayed. There is no subscription,
automatic charge, daily allowance or visual editor.

| Capability | Demo | Pro |
| --- | --- | --- |
| Standard controller and calibration | Included | Included |
| Agent-generated custom layouts | Included | Included |
| Saved profiles, MCP save/activate, phone switching | Included | Included |
| Integrated dictation, transcript editing and typed chat | Included | Included |
| Receiver, setup, diagnostics, pairing and local practice | Included | Included |
| Connected gameplay/input and game chat sending | 30 minutes total | Unlimited |

Profile creation, validation, saving and switching do not require purchase,
including after demo expiry. Expiry stops live game input and chat delivery;
it does not delete or replace layouts, hide features, or disable local practice.
Dictation availability still depends on the device, language and permissions.
Custom layouts use the player's own connected agent/MCP client.

## Metering and safe expiry

An explicit Start action arms the demo, and the first valid input to ready HID
starts the meter. Count connected foreground controller-session time, including
idle gaps and chat composition. Setup, menus, local practice, backgrounding,
explicit pause and disconnection do not consume time or emit game input.

The receiver owns the monotonic clock and output cutoff. Persist pre-debited
five-second reservations atomically on a utility queue; return unused time on
clean pause. One-second prefetch means a crash can lose up to six seconds of
unused allowance. Mirror consumed time on the phone. Reconnects, profile changes,
re-pairing known devices and midnight/wall-clock changes do not replenish time.
The local implementation cannot prevent resetting both installations or using
new devices; no mandatory account or fingerprinting service is introduced.

Show remaining time and low-time warnings. At zero, emit neutral HID immediately,
clear touch ownership, cancel pending chat safely, and show the demo-ended state.
Resume after verified purchase only from neutral input and explicit player action.
No game-state/combat detection is claimed; expiry may interrupt play.

## Implementation boundaries

- `AccessSession.swift` meters and persists the allowance and verifies unlimited
  ownership. Its Pro branch bypasses metering only.
- `Receiver.swift` supplies and activates layouts for both tiers, acknowledges
  profile changes normally, and gates only live HID/chat output on available time.
- `connection-core.js` accepts valid incoming custom layouts and permits profile
  listing/selection without Pro. Input/chat sending retain the demo time check.
- MCP/CLI profile storage has no purchase authorization layer. Standard schema,
  revision conflict, atomic storage and safe activation checks remain.
- Integrated recording has no Pro check. The existing native speech permissions
  and error handling apply equally to demo and paid users.
- Purchase and revocation never change the chosen layout or disconnect a phone
  merely because it uses a custom profile. Access transitions release input and
  require explicit resume; existing remaining demo time is preserved.
- Menu, onboarding, upgrade and expiry copy describe the time limit as the sole
  paid difference. No custom-layout or dictation upsell is shown.

## Native purchase implementation

Use StoreKit 2 and Google Play Billing directly, with `thumble_pro_lifetime` as
an Apple non-consumable / Google one-time non-consumable. There is no RevenueCat.
Native flows handle localized prices, cancellation, pending approval, transaction
updates and restoration through the same store account. iOS and Android purchases
are separate. Unknown or pending ownership never removes the cap.

Our first-party verifier checks native purchase proof against Apple/Google,
acknowledges completed Google purchases, and signs a receiver/phone-bound grant.
The receiver verifies that grant; neither a phone boolean nor a custom profile
can bypass the meter. Seven-day cached grants support offline use between checks.
A network error preserves an unexpired verified grant; a confirmed revocation or
cache expiry reinstates the original allowance without resetting it.

Production app identifiers, store products/prices, public verification key, HTTPS
service and legal/support URLs must be configured before payments are enabled.
See [setup and verification](monetization-setup.md). Real sandbox purchase testing
and Apple's review of the metered-use demo remain release requirements.

## Verification

Regression coverage must demonstrate unpaid MCP save/activation, incoming custom
layouts, phone profile selection, metering across those operations, expiry during
held input, continued configuration after expiry, and unchanged layouts after
purchase/revocation. Preserve the existing neutral-report, revision, freshness-
lease, signature, restore and purchase-state checks. Run the Node suite, native
access tests, isolated fake-HID receiver test, mobile lint/typecheck and builds
appropriate to changed native code.
