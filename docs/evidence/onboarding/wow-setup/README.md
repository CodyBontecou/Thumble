# WoW / ConsolePort onboarding

Implemented October 23, 2026. Uses the app's existing two-column landscape layout, native navigation and native switches. Appllama research tools were unavailable; existing shipping pairing/cloud screens supplied the visual and navigation patterns.

## Journey

1. Choose the exact WoW installation used in Battle.net. Do not silently assume Retail. An Other option covers installations whose names change over time.
2. Connect the Mac receiver. Reconnection takes priority over old saved milestones.
3. Explicitly select the complete Xbox-style controller from the receiver's live catalog, then test the controls. This avoids starting ConsolePort with a six-button cloud preview that lacks modifiers. A missing standard profile reports an error instead of substituting another profile.
4. Install the matching ConsolePort version on the Mac. Shareable setup instructions carry the chosen installation; the player confirms the addon is enabled and its controller setup is finished.
5. Confirm movement/release, camera directions, an action, a modifier combination and menu navigation. All five user confirmations and a current Mac connection are required before finishing. Players can keep their controls and finish without AI.

Pairing and control-test confirmations return directly to the WoW flow. Installation choice, addon preparation and individual game checks persist in the existing version-2 onboarding store. Concurrent checkbox writes merge against current state. Changing installations clears only WoW addon/game confirmations; previous generic setup data remains compatible.

Optional cloud personalization carries the selected client, comfort preferences and exact registered phone into the AI request. It asks for a complete standard gamepad with reachable modifiers. Unverified character/class text cannot establish learned spells or actual bindings. The local-agent branch uses the existing Thumble Bridge export, Review/Apply and verified-result process.

## Evidence and limits

- 165 project tests passed, including persisted WoW checkpoints, disconnect gating, invalid/legacy data, concurrent check writes and cloud request context.
- Mobile lint and typecheck passed.
- A Release simulator build passed on Tapping React Native QA (87952CD2-B760-40A1-AF11-5CE40995960B).
- Observed the new installation picker, chose World of Warcraft, reached the disconnected Connect Mac stage, restarted the app and reopened WoW setup: installation choice persisted and the flow resumed at Connect Mac. The screenshots use Argent's orientation override because this simulator's capture remained portrait while its app UI was landscape.
- Connected addon/game/ready screens are guarded by the live Mac connection and were not walked against a live receiver or WoW in this pass. Their progression/gating is covered by state tests; this is not a new gameplay compatibility result.
- This change has not been deployed to the physical phone or submitted to an app store.

The hosted service saves and delivers declarative controllers. Cloud-to-Mac adoption is now implemented and exercised on the physical phone and receiver; see [the adoption evidence](../../cloud/mac-adoption.md). Character export/import through hosted MCP remains follow-up work. Do not describe a phone render receipt as verified WoW input. The earlier live Google/ChatGPT-to-phone result remains recorded in the cloud pilot evidence.

ConsolePort's maintainer documentation confirms native gamepad input and links to its distributions: https://github.com/seblindfors/ConsolePort . No game binding writes, addon installation or gameplay actions were executed by this QA run.
