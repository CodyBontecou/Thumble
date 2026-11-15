# Release acceptance

This is the current checklist. Dated release and store ledgers are historical
evidence, not a live status query. Source checks, simulator checks, installed
packages, real store billing and physical gameplay establish different things.
Never promote one into proof of another.

## Development gates

| Area | Command | Required result |
| --- | --- | --- |
| Shared/backend/website contracts | `npm test` | All source tests pass |
| Mobile and purchase configuration | `npm run mobile:check` | Current plan config, lint, typecheck and regressions pass |
| Studio model | `npm run desktop:test` | Validation, exact revisions and drafts pass |
| Swift protocol | `npm run test:protocol:mac` | Portable phone journey against production receiver sources with captured output |
| Python protocol | `PYTHONPATH=apps/receiver-desktop python -m unittest discover -s apps/receiver-desktop/tests` | Portable phone journey and native-store contracts; report platform skips |
| iOS Release | `npm run mobile:smoke:ios -- --device UDID` | Two clean launches and two full setup/orientation journeys |
| Android Release | `npm run mobile:smoke:android -- --device SERIAL` | Two clean launches and two unpaid setup journeys on an emulator |

Both mobile CI jobs are required. The smoke scripts build from a clean committed
source archive, keep the tested app/APK hash and report hashes, and reject empty,
failed or incomplete reports. `--allow-dirty` and a prebuilt `--sim-app`/`--apk`
are local QA options, not production-release evidence. Both scripts exclusively
lock `build/mobile-smoke-session.json`; run them serially in a local checkout.
They reset only the selected simulator/emulator app, never a physical phone.

The iOS journey proves unpaid Welcome → receiver setup → tour → landscape
controller → menu → portrait calibration → landscape controller. The Android
journey proves unpaid Welcome → receiver setup, with the receiver installation
instructions and pairing entry point available before billing. iOS's measured
`controller-landscape` identifier is the orientation assertion; screenshot file
dimensions are insufficient because simulator captures can retain portrait axes
while the application is landscape. Semantic runner selectors avoid the direct
gesture-capture coordinate issue observed in this environment.

The shared phone journey runs against Swift and Python, using real TLS transport,
throwaway grant signing keys and captured output. It covers exact profile
selection, layout commit/neutral ACK, resume, cloud adoption, phone editing,
remembered reconnect, keyboard/pointer state, plan expiry, restore and revocation.
It does not use a store or a physical touchscreen. Dedicated native access tests
add report-level assertions that expiry/revocation release held output.

## Physical installed-receiver acceptance

Use isolated profiles and each exact downloaded installer. Record its SHA-256,
receiver version, phone build and installation source, OS, game/client version,
ConsolePort/addon versions, network and evidence paths. Do not overwrite personal
profiles or write synthetic keys/chat into unrelated applications.

| Required pass on macOS, Windows and Linux | Evidence |
| --- | --- |
| Install the published bytes on a clean user account; complete driver/permission setup | Installer hash, native readiness and permission result |
| Pair iPhone and Android over Wi-Fi; restore the selected layout | Phone-rendered exact revision and receiver acknowledgement |
| In Studio, save a draft without activation; send its saved revision | Draft stays separate, matching phone ACK, and no held input during switch |
| Confirm the reported usable canvas; edit at least one control | Studio size equals the phone canvas; target validation uses that size |
| Exercise sticks, triggers, buttons and declared keyboard/pointer controls | Native output and observed game behavior, including every release |
| Background/lock phone, interrupt Wi-Fi, sleep/wake computer, restart both processes | Release/neutral state and remembered reconnect; no old held input replays |
| Restore a plan; expire/revoke it while controls are held | Immediate neutral output, pairing/layout preserved, neutral resume |
| Change WoW bindings and reload | Updated labels/layers without losing an unsent Studio draft |

Windows needs its supported virtual-controller driver; Linux needs uinput
permissions. Pure Wayland chat targeting and preview installer signing limitations
remain as documented in the receiver README. CI cannot certify a household
firewall prompt, a supported game, or physical suspend/resume.

## Store-installed billing acceptance

Use identified App Store sandbox/TestFlight and Play license-test accounts. Do not
substitute a sideloaded APK, local-testing receiver, synthetic grant or QA access
bypass. Test offers can differ by account; an ineligible account must not be
promised a new trial. Never record purchase proofs, tokens, QR images or tester
credentials in evidence.

| Scenario on both stores | Required result |
| --- | --- |
| Fresh install without ownership | Setup and local practice available; game input/chat blocked |
| Eligible subscription trial | Store displays its actual terms; verified grant unlocks receiver |
| Trial-ineligible account | Correct localized price and eligibility; no invented offer |
| Cancel purchase sheet / pending purchase | No grant or game input; clear recovery |
| Restore existing lifetime or active subscription after reinstall | Same entitlement, selected controller preserved, no duplicate charge |
| Cancel subscription renewal | Access remains until the store's paid/trial expiry; cancellation alone must not revoke paid time |
| Accelerated expiry, billing issue, refund/revocation | Access reflects store verification; held controls release on expiry/revocation |
| Background during purchase and return | Same remembered receiver, exact layout, neutral recovery |
| Verification service unavailable | No unverified unlock; retry/restore works after recovery |
| iOS Family purchase | Correct supported Family product and sharing entitlement |

Use sandbox acceleration for expiry. A real charged purchase is a separate owner
decision. Store actions and physical-machine tests are not performed by source CI.

## Current implementation evidence

See [November 13 reliability work](evidence/reliability-2026-11-13/README.md).
The published receivers in [the release ledger](evidence/receivers-release-2026-11-13/README.md)
predate this source change. This work does not publish new installers, submit store
builds, or certify the previous release's untested physical-game scenarios.
