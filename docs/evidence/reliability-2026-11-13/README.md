# Reliability and first-session work — November 13, 2026

Local implementation QA on the working checkout. No production service, store
submission or published installer was changed. Source revisions remain uncommitted.

## Implemented

- Receiver setup, layout delivery and phone practice before purchase. Native
  receivers still require a signed plan for gameplay/chat. Pairing now returns to
  the requested Connect screen rather than an unrelated onboarding screen.
- iOS scene geometry reassertion after navigation/foreground changes, serialized
  requests and bounded retries while the visible controller is measured portrait.
  Portrait input is paused; refused/resizable windows have an explicit recovery UI.
- Negotiated `viewport:1` capability; authenticated usable landscape canvas updates;
  current-session sizes exposed in Studio and preferred by native save/send validation.
  Older receivers retain manual sizing. Canvas messages never refresh input leases.
- Shared portable-phone TLS journey for Swift and Python. It exposed and fixed
  a Swift difference: replacing a plan grant could retain a prior play request.
  Grant replacement now pauses output and requires neutral recovery/resume.
- Android Release launch/setup CI alongside iOS; both jobs required. iOS release
  checks also run the setup/calibration/orientation regression twice.
- Phone-side demo metering calls and unused timer formatting removed. Native legacy
  storage namespaces/APIs and receiver records remain for compatibility. The local
  purchase-config checker now validates the six plan products and store-derived
  pricing configuration instead of rejecting the current catalog for lacking $19.99.
- README, protocol v3/reconnect, receiver identity, cloud migrations, onboarding,
  Studio canvas and monetization documentation reconciled. Dated ledgers retained.
- Studio distinguishes a selected revision awaiting delivery from a revision the
  phone acknowledged. Its inspector and library no longer imply an offline phone
  has received the current selection.

## Final local verification

- Source contracts: 320 passed; mobile lint/typecheck and 166 regressions passed;
  Studio model: 17 passed. [Check summary](reports/source-checks.txt).
- Final iOS Release: two clean launches and two 26-step setup/calibration/orientation
  journeys passed. [Artifact and report hashes](reports/ios/smoke.json).
- Final Android Release: two clean launches and two seven-step unpaid setup
  journeys passed. [APK and report hashes](reports/android/smoke.json).
  These are local prebuilt artifacts (`dirty: true`), not store or CI releases.
- Python 3.14: 100 tests run, 96 passed and four platform-specific skips.
  [Suite output](reports/python.txt).
- [Swift shared TLS protocol](reports/swift-protocol.txt) and
  [native access expiry/revocation](reports/native-access.txt) passed with captured
  output and throwaway stores/keys.
- [Qt workspace smoke](reports/qt-workspace.txt) passed save, exact revision
  selection and native rendering. [Inspected screenshot](studio-selected.png)
  uses the software-rendered QA launch (`--disable-gpu`), not a Windows/Linux
  installer or physical game. The placeholder initial GPU capture was discarded.

## QA contracts

| Start state | Actions | Hard evidence | Side effects |
| --- | --- | --- | --- |
| Unpaid Android Release clean install | Welcome → Check my setup | Pairing entry point visible before billing | Emulator app reset only |
| Unpaid iOS Release clean install | Setup → skip tour customization → finish tour → menu → calibration → Done | Tour hidden, measured landscape root before/after calibration | Simulator app reset only |
| Isolated Swift/Python receiver | Pair, select/edit/adopt, reconnect, restore/expire/revoke plan | Real portable Connection protocol and native receiver responses | Temporary private stores, throwaway keys, captured output only |
| Studio native-store fixture | Save/select stale/current revisions; fresh/stale/disconnected phone canvas | Swift fixture assertions and shared desktop model tests | Temporary store only |

Recorded tests contain semantic targets. The iOS recorder initially captured
coordinates against an unrelated AXTextField; native runner probes established
the real IDs and the final YAML uses only IDs/text. Direct Android landscape taps
also failed to reach the intended tour target; the Android acceptance test is
limited to the portrait unpaid setup journey and makes no landscape-touch claim.

Two unchanged final iOS navigation passes succeeded. Their initial Welcome idle
step reported a small changing region; Welcome has no loading spinner and the
button's arrival, subsequent setup destination and return orientation are
independently hard-checked. An earlier calibration idle also warned. A controller
foreground check was also observed manually after waiting for the Home transition;
it is not claimed as a saved foreground regression.

## External checks still required

Current Play-installed/TestFlight or App Store billing with named tester accounts;
physical Windows/Linux installations and gameplay; published signed Mac gameplay;
full permission/firewall/sleep matrix; physical iPhone confirmation of this
orientation fix. See [release acceptance](../../release-acceptance.md). No synthetic
grant, simulator pass or Qt smoke is evidence that these external passes succeeded.
