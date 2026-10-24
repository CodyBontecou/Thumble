# iPhone 13 Mac input and WoW onboarding QA

Tested 2026-10-23 using Argent on the connected iPhone 13 Pro Max (iOS 26.3.1), `com.thumble.ios`, and the signed current `build/Thumble Receiver.app`. User requested automated testing because they were unavailable for physical input.

## Results

| Check | Result |
| --- | --- |
| Physical touch to real Mac HID, two runs | PASS |
| Both sticks, four signed axes | Each reached -32768 and 32767, then returned to 0 |
| LT and RT | Each reached 255, then returned to 0 |
| ABXY, LB/RB, four D-pad directions | Each pressed and released, final value 0 |
| Saved controller flow replay | PASS, 23/23 steps |
| Connected WoW confirmation | Enabled, deliberately not pressed |
| Disconnected WoW and controls confirmations | Disabled; Connect Mac offered |
| Onboarding persistence | Pairing alone remains complete, 1/4; other assertions remain pending |
| Actual WoW gameplay | NOT TESTED |
| Simultaneous movement plus button / both sticks | NOT TESTED: Argent physical iOS supports one finger |

The existing `consoleport-bonteq` profile remained at revision 5, activation 6. No profile or game bindings were changed. The included 30-minute demo was started for live input; approximately four minutes had been consumed at the paused-menu checkpoint. WoW remained closed during automated input.

## Pairing diagnosis

The optical scanner decoded the old receiver invitation, but pairing failed with “Socket is not connected.” The running older `Tapping Receiver.app` lacked the current access-resume protocol. Replacing that process with the current signed `Thumble Receiver.app` resolved pairing using a fresh private invitation link. A second optical QR scan was not performed. No pairing credentials are included here.

After the disconnect gate test, the current receiver was restarted without the temporary QA invitation export. The phone was left at Getting started with its unverified steps pending. This phone’s Argent services and QA observers were stopped.

## Independent input evidence

`hid-first-pass.jsonl` has 610 events; `hid-replay.jsonl` has 624. The observer filters at callback time to the virtual gamepad product and HID usage pages 1/9. The assertion additionally requires every captured row to be `Thumble Wi-Fi Gamepad`, validates all 16 tested channels, and requires final neutral values. These captures establish delivery and release outside the game; they do not establish ConsolePort mappings or in-game behavior.

Run the evidence assertion from any directory:

```sh
python3 docs/evidence/onboarding/iphone13/assert-hid.py
```

The reusable fragment is `.argent/flows/iphone13-controls-automated.yaml`. It assumes the physical phone is already connected, foregrounded on the controller, using this exact profile and geometry, with demo/access active and WoW closed. Coordinate gestures intentionally disambiguate repeated spell labels and exercise stick endpoints. Capture HID separately when replaying; the UI flow alone does not assert HID delivery.

`onboarding-diagnostic.yaml.txt` is an incomplete diagnostic interaction history, not a replayable regression: private pairing, permission handling, receiver replacement and the independent controls fragment happened between recorded steps.

## WoW coverage and remaining work

Local files identify Classic Era 1.15.9, ConsolePort 3.3.11 and ThumbleBridge 0.1.0 in `_classic_era_/Interface/AddOns/`, including Interface 11509 metadata. Loading the addons in-game and gameplay remain unverified.

When a human is available, verify movement, camera, jump, targeting, a trigger-modified action, menu navigation, return to keyboard/mouse, and simultaneous movement plus button release in Classic Era. Only then mark the relevant onboarding assertions complete.

Usability observation: the WoW confirmation card requires two long scroll gestures to reach on this phone. Offline Connect Mac is below that card and partly outside the viewport until further scrolling. Screenshots preserve connected/offline states and the unchanged completion count.
