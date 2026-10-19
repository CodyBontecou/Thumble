# Receiver verification — 2026-10-18

[GitHub Actions run 39176454981](https://github.com/CodyBontecou/Thumble/actions/runs/39176454981)
passed on both `windows-latest` and `ubuntu-latest`, testing commit
`997458a514cbc2900a0bef70a4f34b8d4aee6317` on `codex/receiver-native-ci`.

| Environment | Client | Observed result |
| --- | --- | --- |
| Windows hosted runner | Synthetic iOS v3 protocol client over a real receiver WebSocket | Native foreground-window key/modifier, mouse, wheel, and disconnect-release events passed |
| Linux hosted runner | Same protocol client | Receiver uinput-device key/modifier, mouse, wheel, and disconnect-release events passed |
| Debian 13 ARM64 VM, Xorg/libinput, kernel 6.12.113 | Actual Thumble iOS app in iOS 26.5 Simulator | Manual pairing, profile delivery, A/S typing, pointer movement, and left click reached a desktop Tk window |
| Disposable Windows hosted VM | Actual Thumble iOS app in the same Simulator | Manual pairing, profile delivery, A/S typing, cursor movement, and left click reached a native Windows Forms text field; recorded controls replayed successfully |
| Debian 13 ARM64 VM, Xorg/libinput | Physical iPhone 13 Pro Max, iOS 26.3.1 | LAN pairing, native A/S typing, cursor movement and left click passed; controls replay passed |
| Disposable Windows hosted VM | Same physical iPhone | WSS pairing, native A/S typing, cursor movement and left click passed; controls replay produced `asas` |

Both Actions jobs also passed formatting, Clippy, core/protocol/receiver tests,
and release builds. The run publishes native executable artifacts and
`native-delivery-windows-latest` / `native-delivery-ubuntu-latest` evidence JSON
and logs. The native test cannot pass using receiver counters alone: independent
OS observers must receive the expected events. It also checks that releasing A
does not release Ctrl while S still holds it, and that disconnect releases held
keys and a mouse button.

The Linux app check used a dedicated simulator and a private Lima VM. Simulator
loopback port 18865 forwarded into the guest receiver; it did not test Bonjour
or physical-phone LAN networking. A focused desktop entry changed from empty to
`as`; the witness recorded both key down/up pairs, cursor motion from (550, 220)
to (651, 241), and left-button down/up. The four-step iOS control fragment then
replayed successfully with 4 passed and no skipped steps. This is an interaction
fragment with an explicit pairing/desktop prerequisite, not a self-contained
pairing regression test.

## Actual iOS app to Windows

[Windows acceptance run 39179246842](https://github.com/CodyBontecou/Thumble/actions/runs/39179246842)
tested commit `ce73675ada8329526989afdc5e5761277b155254`. The receiver ran with
native input enabled on a fresh Windows hosted VM. The actual iOS app connected
through a temporary WSS tunnel and completed six-digit pairing. No synthetic
protocol client or OS key injection was used to drive this acceptance check.

Tapping A and S produced `as` in the native Windows text field. Windows recorded
VK_A (65) and VK_S (83) down/up messages. A trackpad drag moved the cursor from
(210, 218) to (305, 238), covering 15 distinct observed positions; tapping the
trackpad delivered left-button down/up. The four-step recorded control fragment
replayed with 4 passed, no failures and no skipped steps. Windows then displayed
`asas` and had recorded 8 key messages and 4 mouse-button messages. The native
witness observes only its own window, rather than a global keyboard hook.

The run publishes `windows-ios-desktop-evidence`, containing the native event
JSON, desktop screenshot, and passing `result.json`. Local before/after images,
receiver status and event captures are under
`build/ReceiverVMs/windows-ios-session/`. The reusable control fragment is
`scripts/receiver-qa/ios-windows-controls.yaml`; it requires an already-paired
Windows session with the acceptance profile and a focused witness text field.
Its trackpad swipe intentionally uses coordinates because the gesture itself is
being tested; its A, S and trackpad taps use stable app identifiers.

The operator explicitly approved the temporary tunnel. A loopback HTTP guard
required a random 256-bit path token, and an invalid token was independently
rejected with HTTP 403. Connection information was encrypted with the local
operator's RSA public key before artifact upload. Neither plaintext connection
tokens nor pairing codes were committed or included in published evidence. The
receiver and tunnel stopped immediately after acceptance; the job also has a
15-minute session timeout and scoped cleanup. This test does not change the
receiver's normal LAN deployment requirements.

The first Windows session started its desktop but lost tunnel connectivity
after background setup returned. It was canceled. The successful harness keeps
the coordinator, tunnel and artifact upload alive inside one JavaScript action,
uses HTTP/2 for the tunnel connector, and waits for a registered tunnel before
publishing its encrypted descriptor. The exploratory pairing recording contains
coordinate fallbacks and cross-tree warnings; it is not presented as a passing
pairing regression. The separate four-step controls fragment passed replay.

Local evidence is under `build/ReceiverVMs/evidence/`: native JSON/logs in
`windows/` and `linux/`, plus `ios-linux-desktop.png`,
`ios-linux-desktop-events.jsonl`, and `ios-linux-app.png`. Build output and runtime
credentials are not committed.

## Physical iPhone acceptance

The connected physical iPhone 13 Pro Max running iOS 26.3.1 was tested through
Argent's hardware XCUITest runner, after the other authorized phone test returned
exclusive access. These results are separate from the Simulator checks above.

Linux used the phone's real LAN connection to the Mac's temporary port 18866,
forwarded into the isolated guest's receiver port 18865. The first request
waited on the actual iOS Local Network permission dialog; allowing Thumble made
the pairing challenge arrive immediately. Six-digit pairing and delivery of
the Linux acceptance profile then succeeded.

The phone typed `as` into the Linux desktop entry. The witness recorded A/S
down/up, pointer movement from (550, 220) to (656, 242), and left-button down/up.
After restarting only the empty desktop witness, the four-step hardware control
fragment replayed with 4 passed and no failures/skips. The new desktop entry
again contained `as`, with both key pairs, cursor movement and the click
independently recorded by Xorg/Tk. The first and replay passes covered 23 and
25 distinct pointer positions respectively.

[Physical iPhone Windows run 39182896955](https://github.com/CodyBontecou/Thumble/actions/runs/39182896955)
used a fresh disposable Windows VM and the already-approved protected WSS
tunnel. The receiver identified its client as `iPhone`, rather than the
Simulator's `Thumble Receiver QA`. Manual pairing and acceptance-profile delivery
succeeded. The physical phone produced `as`, VK_A/VK_S down/up, movement from
(210, 218) to (293, 236), and left-button down/up in the native Windows witness.
The control fragment replay passed all 4 steps, and the desktop then contained
`asas`, with 8 key messages and 4 mouse-button messages.

Local hardware evidence lives in `build/ReceiverVMs/physical-phone/`: Linux
first/replay screenshots and event logs under `linux/`, Windows first/replay
screenshots, native JSON and receiver status under `windows/`, and screenshots
of the connected physical phone for each platform. The Windows run also uploads
its native evidence artifact. Only test-window input was observed; the phone's
other apps, accounts and purchases were preserved.

The saved hardware control fragments are
`scripts/receiver-qa/physical-iphone-linux-controls.yaml` and
`scripts/receiver-qa/physical-iphone-windows-controls.yaml`. Both were polished to
the stable app identifiers observed on the phone and replayed successfully.
The trackpad drag remains a raw gesture because movement itself is under test.
The pairing recordings are exploratory diagnostics, including the initial
permission wait, and are not presented as passing standalone pairing regressions.

Both receivers and the test forwarding connections were stopped afterward.
Thumble retains the Local Network permission needed for its intended LAN use.

## Repeating the Linux app check

Use an isolated desktop with uinput access, then stop the receiver and import
`scripts/receiver-qa/linux-acceptance-configuration.json`. Start the receiver and
pair the current iOS app manually using its current pairing code.

Run `scripts/receiver-qa/linux-desktop-probe.py` on the guest desktop with
`DISPLAY` and `THUMBLE_DESKTOP_EVIDENCE` set. Focus its entry and position the
guest cursor at (550, 220). Replay
`scripts/receiver-qa/ios-linux-controls.yaml` through Argent with its prerequisite
acknowledged. Confirm the guest entry and evidence log after replay; an Argent
tap-success report alone does not establish native delivery.

The first app-check profile draft had an invalid shape string
(`roundedRectangle` instead of the wire value `rounded_rectangle`), causing the
Swift client to discard the accepted message. The saved QA fixture uses the
correct value. The initial Actions attempt also exposed CRLF fixture checkout
and mismatched press identifiers in the test client; the passing commit fixes
both.

## Remaining acceptance coverage

The actual iOS application now controls both Windows and Linux from Simulator
and a physical iPhone. The physical Linux check used LAN forwarding into its VM;
the Windows check traversed an encrypted tunnel. Direct Windows LAN firewall
configuration, Linux Wayland, Bonjour discovery and
permission prompts, suspend/resume, elevated Windows applications, and physical
hardware still need acceptance checks. Virtual gamepad output remains
unsupported; the iOS connection bar correctly shows controller unavailable
while keyboard/mouse control works.

The temporary Windows hosted VM, Linux VM, and dedicated simulator were stopped
after evidence capture. The local Linux VM files remain under ignored build
output for reuse; Windows used a disposable GitHub-hosted VM.
