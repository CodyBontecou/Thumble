# Onboarding reconnect and reachable actions — 2026-10-23

Implemented and installed a development-signed Release build of `com.thumble.ios` on the connected iPhone 17 Pro, iOS 27.0.1. The app update preserved onboarding data.

## Changes

- Pair-link handling now follows the focused pairing screen and waits for the app to become active. Foreground events during asynchronous preparation are retained. Leaving pairing removes the listener and cancels pending connection preparation; a completed connection is preserved. Expired/invalid links surface errors. Pairing credentials remain short-lived and single-use: reconnect uses the receiver's current link, not a stored credential.
- Pairing keeps Scan and, when opening a link, Retry in a bottom action bar.
- Agent setup keeps Share and Check (or Connect Mac while offline) in the action bar. Successful verification offers Create my first layout there. Requests and setup instructions expand on demand.
- First-layout setup keeps Prepare, Share, Check delivery, or Continue in the action bar as the state changes. The generated prompt starts collapsed. Status stays beside the actions while the content scrolls. Preferences and requests still persist.

## Verification

| Check | Result |
| --- | --- |
| Reproduce original failure on old phone build with a fresh link after backgrounding | Failed as expected: Connect Mac stalled; [before screenshot](reconnect-stalled-before.png) |
| Background → current receiver link → connected | Three consecutive passes with no Done/dismiss rescue; the final build also passed subsequent fresh-link pairing and queued delivery |
| Agent check through real stdio MCP server | PASS; [verified action bar](agent-verified-action.png) |
| Offline Connect Mac action → pairing | PASS; [offline action](agent-offline-action.png), [reachable Scan](pair-scan-action.png) |
| Prepare layout from fixed action bar | PASS; [Prepare](prepare-action.png), [waiting delivery](delivery-action-waiting.png) |
| Footer stays visible after scrolling and expanding long request | PASS by physical screenshots; [scrolled](layout-actions-scrolled.png), [expanded](expanded-request-actions.png) |
| Save layout, background phone, activate while disconnected, reconnect, acknowledge matching layout | PASS; [receipt](delivery-receipt.json), [rendered](delivery-action-rendered.png) |
| Check delivery without scrolling | PASS; [confirmed](delivery-confirmed.png) |
| Saved navigation/disclosure smoke on final phone build | 30/30 steps; two uninterrupted full passes of the same final YAML |
| JavaScript suite | 130/130 passing, including six pairing lifecycle regressions |
| Mobile lint and typecheck | PASS |
| Signed iPhone Release build and data-preserving install | PASS; development signing overrides applied only to the local build command |
| Whitespace check | PASS |

The exact delivery target was `first-layout-48a2f5de`, profile revision 1 / activation revision 1. The [test layout](generated-layout.json) reuses the prior QA design with right-thumb movement and larger actions. The real profile-tools MCP server validated and saved it to an isolated temporary store. `controller_status` reported queued/disconnected, then acknowledged/ready after reconnect. No production profiles, bindings, demo time, or gameplay inputs were changed.

## Saved smoke flow

[iphone17-onboarding-actions-fixed.yaml](../../../../.argent/flows/iphone17-onboarding-actions-fixed.yaml) restarts the app, opens Getting started, checks reachable layout actions and Continue, opens agent setup, expands the request, and confirms Share stays visible. Required saved QA state: onboarding dismissed, pairing and personalization complete. Launch preserves data. It does not provision a receiver or automate the network-delivery test. It uses semantic selectors throughout; no coordinate or raw gesture exceptions remain.

```sh
argent flow run iphone17-onboarding-actions-fixed --device 00008150-001405DA2188401C --platform ios
```

The `*.yaml.txt` files are diagnostic transcripts only, not replayable flows. Backend changes and private pairing links were deliberately omitted. Simulator exploration also encountered rotated tree/capture limitations; physical screenshots are the acceptance evidence. No physical screen recording or 60fps motion/performance result is claimed. The app has a deliberately dark configured appearance. Other device sizes, large accessibility text, camera permission changes and actual Mac/WoW gameplay were not revalidated in this focused run.

The isolated receiver and this phone's automation runner were stopped after evidence capture. The installed update remains on the phone, offline with pairing and layout complete (2/4); Mac input and WoW remain unconfirmed.
