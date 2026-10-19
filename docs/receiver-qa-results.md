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

A physical-iPhone session on either platform remains unverified. The actual iOS
application now controls both Windows and Linux through Simulator; the Windows
check traversed an encrypted tunnel, and the Linux check used loopback forwarding.
Linux Wayland, real LAN discovery and
permission prompts, suspend/resume, elevated Windows applications, and physical
hardware still need acceptance checks. Virtual gamepad output remains
unsupported; the iOS connection bar correctly shows controller unavailable
while keyboard/mouse control works.

The temporary Windows hosted VM, Linux VM, and dedicated simulator were stopped
after evidence capture. The local Linux VM files remain under ignored build
output for reuse; Windows used a disposable GitHub-hosted VM.
