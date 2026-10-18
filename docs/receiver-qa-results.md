# Receiver verification — 2026-10-18

[GitHub Actions run 39176454981](https://github.com/CodyBontecou/Thumble/actions/runs/39176454981)
passed on both `windows-latest` and `ubuntu-latest`, testing commit
`997458a514cbc2900a0bef70a4f34b8d4aee6317` on `codex/receiver-native-ci`.

| Environment | Client | Observed result |
| --- | --- | --- |
| Windows hosted runner | Synthetic iOS v3 protocol client over a real receiver WebSocket | Native foreground-window key/modifier, mouse, wheel, and disconnect-release events passed |
| Linux hosted runner | Same protocol client | Receiver uinput-device key/modifier, mouse, wheel, and disconnect-release events passed |
| Debian 13 ARM64 VM, Xorg/libinput, kernel 6.12.113 | Actual Thumble iOS app in iOS 26.5 Simulator | Manual pairing, profile delivery, A/S typing, pointer movement, and left click reached a desktop Tk window |

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

A direct iOS-to-Windows session and physical-iPhone control on either platform
remain unverified. Windows CI establishes native delivery using a synthetic
protocol client, not the iOS application. Linux Wayland, real LAN discovery and
permission prompts, suspend/resume, elevated Windows applications, and physical
hardware still need acceptance checks. Virtual gamepad output remains
unsupported; the iOS connection bar correctly shows controller unavailable
while keyboard/mouse control works.

No Windows VM was needed after the hosted Windows native-input test passed.
The temporary Linux VM and dedicated simulator were stopped after evidence
capture; the VM files remain under ignored build output for reuse.
